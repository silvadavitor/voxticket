"""Consumidor idempotente (R1).

Para cada mensagem, numa transação só:
    INSERT processed_messages ON CONFLICT DO NOTHING  → 0 linhas = repetida: só ACK
    efeito (handler) + INSERT outbox
    COMMIT → só então ACK no broker

Payload fora do contrato → nack(requeue) → fila quorum manda para a DLQ após x-delivery-limit=3 (F4).
Erro de infraestrutura (banco, S3) → retry com backoff SEGURANDO a mensagem (não vai para a DLQ).
"""

import asyncio
import logging
import uuid
from collections.abc import Awaitable, Callable

import asyncpg
import botocore.exceptions
from aio_pika.abc import AbstractIncomingMessage

from ..db import Database
from ..settings import settings
from .broker import Broker
from .envelope import Envelope, InvalidMessage

log = logging.getLogger(__name__)

Handler = Callable[[asyncpg.Connection, Envelope], Awaitable[None]]

INFRA_ERRORS = (
    OSError,
    asyncio.TimeoutError,
    asyncpg.PostgresConnectionError,
    asyncpg.CannotConnectNowError,
    asyncpg.InterfaceError,
    botocore.exceptions.BotoCoreError,
    botocore.exceptions.ClientError,
)


async def process(db: Database, handlers: dict[str, Handler], message: AbstractIncomingMessage) -> None:
    try:
        envelope = Envelope.parse(message.body)
    except InvalidMessage as exc:
        log.error("mensagem fora do contrato, nack: %s", exc, extra={"messageId": message.message_id})
        await message.nack(requeue=True)
        return

    ctx = {"messageId": envelope.message_id, "correlationId": envelope.correlation_id, "type": envelope.type}
    handler = handlers.get(envelope.type)
    if handler is None:
        log.info("tipo sem handler neste serviço, ignorado", extra=ctx)
        await message.ack()
        return

    delay = 1.0
    while True:
        try:
            async with db.pool.acquire() as conn, conn.transaction():
                status = await conn.execute(
                    "INSERT INTO processed_messages (message_id) VALUES ($1) ON CONFLICT DO NOTHING",
                    uuid.UUID(envelope.message_id),
                )
                if status.endswith(" 0"):
                    log.info("duplicate, skipped", extra=ctx)
                else:
                    await handler(conn, envelope)
            break
        except InvalidMessage as exc:  # regra de negócio detectou payload inválido
            log.error("payload inválido no handler, nack: %s", exc, extra=ctx)
            await message.nack(requeue=True)
            return
        except INFRA_ERRORS as exc:
            log.warning("infraestrutura indisponível, tentando de novo em %.0fs: %s", delay, exc, extra=ctx)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 30)

    await message.ack()  # só depois do COMMIT
    log.info("mensagem processada", extra=ctx)


async def consume_forever(db: Database, broker: Broker, handlers: dict[str, Handler]) -> None:
    await db.ready.wait()
    await broker.ready.wait()
    while True:
        try:
            channel = await broker.connection.channel()
            await channel.set_qos(prefetch_count=settings.broker_prefetch)
            # a fila é criada pelo rabbitmq-init (topologia em rabbitmq/definitions.json): só conferimos que existe
            queue = await channel.get_queue(settings.broker_queue, ensure=True)
            log.info("consumindo %s", settings.broker_queue)
            async with queue.iterator() as messages:
                async for message in messages:
                    await process(db, handlers, message)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 — fila ainda não existe ou canal caiu
            log.warning("consumidor reiniciando em 5s: %s", exc)
            await asyncio.sleep(5)
