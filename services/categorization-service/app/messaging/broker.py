"""Conexão com o RabbitMQ que se recupera sozinha (R6).

connect_robust reconecta e restaura canais e consumidores depois de uma queda do broker.
A primeira conexão também é tentada em loop: o serviço sobe mesmo com o broker fora.
"""

import asyncio
import logging

import aio_pika
from aio_pika.abc import AbstractRobustConnection

from ..settings import settings

log = logging.getLogger(__name__)


class Broker:
    def __init__(self) -> None:
        self.connection: AbstractRobustConnection | None = None
        self.ready = asyncio.Event()

    async def connect_forever(self) -> None:
        delay = 1.0
        while self.connection is None:
            try:
                self.connection = await aio_pika.connect_robust(
                    settings.broker_url_with_credentials,
                    client_properties={"connection_name": settings.service_name},
                )
                self.connection.reconnect_callbacks.add(lambda *_: log.info("broker reconectado"))
                self.connection.close_callbacks.add(lambda *_: log.warning("conexão com o broker caiu; reconectando"))
                self.ready.set()
                log.info("broker conectado")
            except Exception as exc:  # noqa: BLE001
                log.warning("broker indisponível, tentando de novo em %.0fs: %s", delay, exc)
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)

    @property
    def is_up(self) -> bool:
        return self.connection is not None and not self.connection.is_closed

    async def close(self) -> None:
        if self.connection is not None:
            await self.connection.close()
