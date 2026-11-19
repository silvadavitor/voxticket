from __future__ import annotations

import asyncio
import logging
import socket
from typing import Awaitable, Callable
from urllib.parse import quote, urlsplit, urlunsplit

import aio_pika
from aio_pika.abc import AbstractIncomingMessage, AbstractRobustChannel, AbstractRobustConnection, AbstractExchange

from .retry import Backoff

log = logging.getLogger("transcription_worker.infra.broker")


def build_broker_url(url: str, username: str | None, password: str | None) -> str:
    if not username:
        return url
    parts = urlsplit(url)
    host = parts.hostname or ""
    if parts.port:
        host = f"{host}:{parts.port}"
    userinfo = quote(username, safe="")
    if password:
        userinfo += ":" + quote(password, safe="")
    return urlunsplit((parts.scheme, f"{userinfo}@{host}", parts.path or "/", parts.query, parts.fragment))


def redact(url: str) -> str:
    parts = urlsplit(url)
    host = parts.hostname or ""
    if parts.port:
        host = f"{host}:{parts.port}"
    return urlunsplit((parts.scheme, host, parts.path, "", ""))


class Broker:
    def __init__(self, url: str, exchange: str, service: str) -> None:
        self.url = url
        self.exchange_name = exchange
        self.service = service
        self.connection: AbstractRobustConnection | None = None
        self.publish_channel: AbstractRobustChannel | None = None
        self.exchange: AbstractExchange | None = None
        self._ready = asyncio.Event()

    @property
    def up(self) -> bool:
        conn = self.connection
        if conn is None or conn.is_closed:
            return False
        connected = getattr(conn, "connected", None)
        if isinstance(connected, asyncio.Event):
            return connected.is_set()
        return True

    async def wait_ready(self) -> None:
        await self._ready.wait()

    async def connect_forever(self, stop: asyncio.Event) -> None:
        """Conecta e prepara o canal de publicação com publisher confirms."""
        backoff = Backoff(base=1.0, cap=30.0)
        while not stop.is_set():
            try:
                conn = await aio_pika.connect_robust(
                    self.url,
                    timeout=10,
                    client_properties={"connection_name": f"{self.service}@{socket.gethostname()}"},
                )
                conn.close_callbacks.add(lambda *_: log.warning("broker connection lost; reconnecting"))
                conn.reconnect_callbacks.add(lambda *_: log.info("broker reconnected"))
                channel = await conn.channel(publisher_confirms=True)
                exchange = await channel.get_exchange(self.exchange_name, ensure=True)
                self.connection, self.publish_channel, self.exchange = conn, channel, exchange
                self._ready.set()
                log.info("broker connected", extra={"broker": redact(self.url)})
                return
            except Exception as exc:
                delay = backoff.next_delay()
                log.warning("broker unavailable (%s), retrying in %.1fs", f"{type(exc).__name__}: {exc}", delay)
                try:
                    await asyncio.wait_for(stop.wait(), timeout=delay)
                except asyncio.TimeoutError:
                    pass

    async def consume(
        self,
        queue_name: str,
        callback: Callable[[AbstractIncomingMessage], Awaitable[None]],
        prefetch: int = 1,
    ) -> None:
        """Canal próprio de consumo com prefetch (R4). O canal robusto restaura o consumer após reconexão."""
        assert self.connection is not None
        backoff = Backoff(base=1.0, cap=30.0)
        while True:
            try:
                channel = await self.connection.channel()
                await channel.set_qos(prefetch_count=prefetch)
                queue = await channel.get_queue(queue_name, ensure=True)
                await queue.consume(callback, no_ack=False)
                log.info("consuming", extra={"queue": queue_name, "prefetch": prefetch})
                return
            except Exception as exc:
                delay = backoff.next_delay()
                log.warning("cannot consume %s (%s), retrying in %.1fs", queue_name, exc, delay)
                await asyncio.sleep(delay)

    async def publish(
        self,
        body: bytes,
        routing_key: str,
        *,
        message_id: str,
        correlation_id: str,
        type_: str,
        headers: dict | None = None,
    ) -> None:
        """Publica persistente e espera o publisher confirm (levanta se o broker recusar/cair)."""
        if self.exchange is None or not self.up:
            raise ConnectionError("broker down")
        message = aio_pika.Message(
            body=body,
            content_type="application/json",
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
            message_id=message_id,
            correlation_id=correlation_id,
            type=type_,
            app_id=self.service,
            headers=headers or {},
        )
        await self.exchange.publish(message, routing_key=routing_key, timeout=10)

    async def close(self) -> None:
        if self.connection is not None:
            try:
                await self.connection.close()
            except Exception:
                pass
