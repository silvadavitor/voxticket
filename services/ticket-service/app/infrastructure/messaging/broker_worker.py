"""Base para workers que mantêm conexão com o RabbitMQ e reconectam com backoff (R6)."""
from __future__ import annotations

import asyncio
import logging
from abc import ABC, abstractmethod

import aio_pika
from aio_pika.abc import AbstractRobustConnection

logger = logging.getLogger(__name__)

MAX_BACKOFF_SECONDS = 30


class Stoppable:
    def __init__(self) -> None:
        self._stop_event = asyncio.Event()

    @property
    def stopping(self) -> bool:
        return self._stop_event.is_set()

    def request_stop(self) -> None:
        self._stop_event.set()

    async def sleep(self, seconds: float) -> None:
        """Dorme, mas acorda imediatamente se o serviço estiver parando."""
        try:
            await asyncio.wait_for(self._stop_event.wait(), timeout=seconds)
        except TimeoutError:
            pass

    async def wait_stop(self) -> None:
        await self._stop_event.wait()


class BrokerWorker(Stoppable, ABC):
    name = "broker-worker"

    def __init__(self, broker_url: str) -> None:
        super().__init__()
        self._broker_url = broker_url
        self._connection: AbstractRobustConnection | None = None

    @property
    def connected(self) -> bool:
        # is_closed só muda num close() explícito: numa queda a conexão robusta segue "aberta" tentando
        # reconectar. O evento `connected` é limpo na queda e marcado de novo ao reconectar (R6).
        connection = self._connection
        return connection is not None and not connection.is_closed and connection.connected.is_set()

    async def run(self) -> None:
        delay = 1
        while not self.stopping:
            try:
                self._connection = await aio_pika.connect_robust(self._broker_url, timeout=5)
                logger.info("%s connected to broker", self.name)
                delay = 1
                await self.on_connected(self._connection)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("%s broker failure; reconnecting in %ss", self.name, delay)
                await self.sleep(delay)
                delay = min(delay * 2, MAX_BACKOFF_SECONDS)
            finally:
                await self._close()

    async def _close(self) -> None:
        connection, self._connection = self._connection, None
        if connection is not None and not connection.is_closed:
            try:
                await connection.close()
            except Exception:
                logger.debug("error closing broker connection", exc_info=True)

    @abstractmethod
    async def on_connected(self, connection: AbstractRobustConnection) -> None:
        """Executa enquanto a conexão estiver de pé; retorna/lança para reconectar."""
