"""Outbox: grava o evento na mesma transação do efeito; o relay publica depois (com confirmação).

Se o broker cair, os eventos ficam no outbox (sent_at IS NULL) e saem quando ele voltar (F6).
"""

import asyncio
import json
import logging
import uuid
from typing import Any

import aio_pika
import asyncpg
from opentelemetry import metrics, propagate

from ..db import Database
from ..settings import settings
from .broker import Broker
from .envelope import new_envelope

log = logging.getLogger(__name__)

_pending = 0
metrics.get_meter("VoxTicket").create_observable_gauge(
    "voxticket.outbox.pending",
    callbacks=[lambda _options: [metrics.Observation(_pending)]],
    description="Eventos no outbox ainda não publicados",
)


def _current_traceparent() -> str | None:
    carrier: dict[str, str] = {}
    propagate.inject(carrier)
    return carrier.get("traceparent")


async def enqueue(conn: asyncpg.Connection, type_: str, correlation_id: str, payload: dict[str, Any]) -> None:
    """Chame DENTRO da transação do efeito (padrão R1)."""
    envelope = new_envelope(type_, correlation_id, payload)
    await conn.execute(
        "INSERT INTO outbox (id, type, correlation_id, envelope, traceparent) VALUES ($1, $2, $3, $4::jsonb, $5)",
        uuid.UUID(envelope["messageId"]),
        type_,
        uuid.UUID(correlation_id),
        json.dumps(envelope),
        _current_traceparent(),
    )


async def relay_forever(db: Database, broker: Broker, interval: float = 1.0, batch: int = 50) -> None:
    global _pending
    await db.ready.wait()
    await broker.ready.wait()
    channel = None
    while True:
        try:
            if channel is None or channel.is_closed:
                channel = await broker.connection.channel(publisher_confirms=True)
                exchange = await channel.get_exchange(settings.broker_exchange, ensure=False)

            async with db.pool.acquire() as conn, conn.transaction():
                rows = await conn.fetch(
                    """SELECT id, type, correlation_id, envelope, traceparent FROM outbox
                       WHERE sent_at IS NULL ORDER BY created_at LIMIT $1 FOR UPDATE SKIP LOCKED""",
                    batch,
                )
                for row in rows:
                    headers = {"traceparent": row["traceparent"]} if row["traceparent"] else {}
                    message = aio_pika.Message(
                        body=row["envelope"].encode() if isinstance(row["envelope"], str) else json.dumps(row["envelope"]).encode(),
                        content_type="application/json",
                        delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
                        message_id=str(row["id"]),
                        correlation_id=str(row["correlation_id"]),
                        type=row["type"],
                        headers=headers,
                    )
                    # com publisher_confirms o await só volta depois do ack do broker
                    await exchange.publish(message, routing_key=row["type"])
                    await conn.execute("UPDATE outbox SET sent_at = now() WHERE id = $1", row["id"])
                    log.info("evento publicado", extra={"type": row["type"], "correlationId": str(row["correlation_id"])})

                _pending = await conn.fetchval("SELECT count(*) FROM outbox WHERE sent_at IS NULL")
        except Exception as exc:  # noqa: BLE001 — broker/banco fora: tenta de novo, nada se perde
            log.warning("relay do outbox aguardando infraestrutura: %s", exc)
            channel = None
            await asyncio.sleep(5)
            continue
        await asyncio.sleep(interval)
