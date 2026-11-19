"""Transactional outbox (ver docs/architecture.md, padrões comuns).

- `enqueue` grava o evento na tabela outbox NA MESMA transação do efeito de negócio.
- `OutboxRelay` publica os pendentes em ordem de id, com publisher confirm, e só então marca sent_at.
  Várias réplicas podem rodar o relay: `FOR UPDATE SKIP LOCKED` evita que duas publiquem a mesma linha.
  Broker fora ⇒ backoff; o processo nunca cai.
"""

from __future__ import annotations

import asyncio
import json
import logging

import psycopg
from opentelemetry import trace
from psycopg.types.json import Jsonb

from . import telemetry
from .broker import Broker
from .db import Database
from .envelope import Envelope, SchemaValidator
from .logs import log_context
from .retry import Backoff

log = logging.getLogger("transcription_worker.infra.outbox")


async def enqueue(conn: psycopg.AsyncConnection, envelope: Envelope, validator: SchemaValidator | None = None) -> None:
    """INSERT no outbox. Chame dentro de `conn.transaction()` junto com o efeito de negócio."""
    body = envelope.to_dict()
    if validator is not None:
        validator.validate(body)  # contrato quebrado é bug nosso: falha antes de gravar
    await conn.execute(
        "INSERT INTO outbox(message_id, type, routing_key, body, traceparent) VALUES (%s, %s, %s, %s, %s)",
        (envelope.message_id, envelope.type, envelope.type, Jsonb(body), telemetry.current_traceparent()),
    )


class OutboxRelay:
    def __init__(self, db: Database, broker: Broker, poll_ms: int = 500, batch_size: int = 50) -> None:
        self.db = db
        self.broker = broker
        self.poll = poll_ms / 1000
        self.batch_size = batch_size
        self.pending: int | None = None  # lido pelo gauge voxticket.outbox.pending

    async def run(self, stop: asyncio.Event) -> None:
        backoff = Backoff(base=1.0, cap=30.0)
        was_failing = False
        while not stop.is_set():
            try:
                if not self.broker.up:
                    await _sleep_or_stop(stop, self.poll)
                    continue
                sent = await self._relay_batch()
                if was_failing:
                    log.info("outbox relay recovered")
                    was_failing = False
                backoff.reset()
                if sent == 0:
                    await _sleep_or_stop(stop, self.poll)
            except Exception as exc:
                was_failing = True
                delay = backoff.next_delay()
                log.warning("outbox relay error, retrying in %.1fs: %s", delay, f"{type(exc).__name__}: {exc}")
                await _sleep_or_stop(stop, delay)

    async def run_pending_gauge(self, stop: asyncio.Event, every_s: float = 10.0) -> None:
        while not stop.is_set():
            try:
                async with self.db.pool.connection(timeout=5) as conn:
                    cur = await conn.execute("SELECT count(*) FROM outbox WHERE sent_at IS NULL")
                    row = await cur.fetchone()
                    self.pending = int(row[0]) if row else 0
                    if self.pending:
                        log.info("outbox pending", extra={"outbox_pending": self.pending})
            except Exception:
                pass
            await _sleep_or_stop(stop, every_s)

    async def _relay_batch(self) -> int:
        sent_ids: list[int] = []
        async with self.db.pool.connection() as conn:
            async with conn.transaction():
                cur = await conn.execute(
                    "SELECT id, message_id, type, routing_key, body, traceparent FROM outbox"
                    " WHERE sent_at IS NULL ORDER BY id LIMIT %s FOR UPDATE SKIP LOCKED",
                    (self.batch_size,),
                )
                rows = await cur.fetchall()
                error: Exception | None = None
                for row_id, message_id, type_, routing_key, body, traceparent in rows:
                    try:
                        await self._publish(str(message_id), type_, routing_key, body, traceparent)
                        sent_ids.append(row_id)
                    except Exception as exc:  # para no primeiro erro, preservando a ordem
                        error = exc
                        break
                if sent_ids:
                    await conn.execute("UPDATE outbox SET sent_at = now() WHERE id = ANY(%s)", (sent_ids,))
        if error is not None:
            raise error
        return len(sent_ids)

    async def _publish(self, message_id: str, type_: str, routing_key: str, body: dict, traceparent: str | None) -> None:
        correlation_id = body.get("correlationId", "")
        parent = telemetry.context_from_headers({"traceparent": traceparent} if traceparent else {})
        with log_context(correlationId=correlation_id, messageId=message_id, type=type_):
            with telemetry.tracer().start_as_current_span(
                f"{routing_key} publish",
                context=parent,
                kind=trace.SpanKind.PRODUCER,
                attributes=telemetry.message_attributes(message_id, correlation_id, type_),
            ):
                headers = telemetry.inject_headers({})
                await self.broker.publish(
                    json.dumps(body, ensure_ascii=False).encode(),
                    routing_key,
                    message_id=message_id,
                    correlation_id=correlation_id,
                    type_=type_,
                    headers=headers,
                )
            log.info("published %s", type_)


async def _sleep_or_stop(stop: asyncio.Event, seconds: float) -> None:
    try:
        await asyncio.wait_for(stop.wait(), timeout=seconds)
    except asyncio.TimeoutError:
        pass
