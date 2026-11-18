"""Relay do outbox: publica eventos pendentes com publisher confirms e delivery_mode=2."""
from __future__ import annotations

import json
import logging

import asyncpg
from aio_pika import DeliveryMode, Message
from aio_pika.abc import AbstractExchange, AbstractRobustConnection
from opentelemetry import propagate, trace
from opentelemetry.trace import SpanKind

from app.infrastructure.messaging.broker_worker import BrokerWorker

logger = logging.getLogger(__name__)
tracer = trace.get_tracer(__name__)

POLL_INTERVAL_SECONDS = 1
BATCH_SIZE = 50


class OutboxRelay(BrokerWorker):
    name = "outbox-relay"

    def __init__(self, broker_url: str, exchange_name: str, pool: asyncpg.Pool) -> None:
        super().__init__(broker_url)
        self._exchange_name = exchange_name
        self._pool = pool

    async def on_connected(self, connection: AbstractRobustConnection) -> None:
        channel = await connection.channel(publisher_confirms=True, on_return_raises=True)
        exchange = await channel.get_exchange(self._exchange_name, ensure=True)
        while not self.stopping:
            published = await self._publish_batch(exchange)
            if published < BATCH_SIZE:
                await self.sleep(POLL_INTERVAL_SECONDS)

    async def _publish_batch(self, exchange: AbstractExchange) -> int:
        async with self._pool.acquire() as connection, connection.transaction():
            rows = await connection.fetch(
                "SELECT id, type, envelope::text AS envelope, traceparent FROM outbox "
                "WHERE sent_at IS NULL ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT $1",
                BATCH_SIZE,
            )
            for row in rows:
                await self._publish(exchange, row)
                await connection.execute("UPDATE outbox SET sent_at = now() WHERE id = $1", row["id"])
            return len(rows)

    async def _publish(self, exchange: AbstractExchange, row: asyncpg.Record) -> None:
        envelope = json.loads(row["envelope"])
        parent = propagate.extract({"traceparent": row["traceparent"]}) if row["traceparent"] else None
        with tracer.start_as_current_span("ticket.publish", context=parent, kind=SpanKind.PRODUCER) as span:
            span.set_attribute("messaging.message.id", envelope["messageId"])
            span.set_attribute("messaging.message.conversation_id", envelope["correlationId"])
            span.set_attribute("app.event_type", envelope["type"])
            headers: dict[str, str] = {}
            propagate.inject(headers)
            await exchange.publish(
                Message(
                    body=json.dumps(envelope, separators=(",", ":"), ensure_ascii=False).encode(),
                    content_type="application/json",
                    delivery_mode=DeliveryMode.PERSISTENT,
                    headers=headers,
                    message_id=envelope["messageId"],
                    correlation_id=envelope["correlationId"],
                    type=envelope["type"],
                ),
                routing_key=row["type"],
                mandatory=True,
            )
        logger.info("published %s %s", envelope["type"], envelope["messageId"])
