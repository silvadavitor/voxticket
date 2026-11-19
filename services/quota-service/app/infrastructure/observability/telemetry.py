"""Métricas customizadas OpenTelemetry do quota-service."""
from __future__ import annotations

import asyncio
import logging

import asyncpg
from opentelemetry import metrics
from opentelemetry.metrics import Observation

from app.application.process_quota import QuotaOutcome

logger = logging.getLogger(__name__)

GAUGE_INTERVAL_SECONDS = 10


class QuotaTelemetry:
    def __init__(self) -> None:
        meter = metrics.get_meter("voxticket.quota")
        self._reserved = meter.create_counter("voxticket.credit.reserved")
        self._rejected = meter.create_counter("voxticket.credit.rejected")
        self._released = meter.create_counter("voxticket.credit.released")
        self._pending_outbox = 0
        meter.create_observable_gauge(
            "voxticket.outbox.pending",
            callbacks=[self._observe_pending],
        )

    def _observe_pending(self, _options: object) -> list[Observation]:
        return [Observation(self._pending_outbox)]

    def record(self, outcome: QuotaOutcome, tenant_id: str) -> None:
        counter = {
            QuotaOutcome.RESERVED: self._reserved,
            QuotaOutcome.REJECTED: self._rejected,
            QuotaOutcome.RELEASED: self._released,
        }.get(outcome)
        if counter is not None:
            counter.add(1, {"tenant_id": tenant_id})

    async def refresh_outbox_pending(self, pool: asyncpg.Pool) -> None:
        self._pending_outbox = await pool.fetchval(
            "SELECT count(*) FROM outbox WHERE sent_at IS NULL"
        )


async def run_outbox_gauge_loop(telemetry: QuotaTelemetry, pool: asyncpg.Pool, stoppable) -> None:
    while not stoppable.stopping:
        try:
            await telemetry.refresh_outbox_pending(pool)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("could not refresh pending outbox metric")
        await stoppable.sleep(GAUGE_INTERVAL_SECONDS)
