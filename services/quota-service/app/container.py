"""Composition root: monta dependências e controla o ciclo de vida."""
from __future__ import annotations

import asyncio
import logging

from app.application.process_quota import ProcessQuotaUseCase
from app.infrastructure.config.settings import Settings
from app.infrastructure.messaging.broker_worker import MAX_BACKOFF_SECONDS, BrokerWorker, Stoppable
from app.infrastructure.messaging.consumer import QuotaConsumer
from app.infrastructure.messaging.contract_validator import ContractValidator
from app.infrastructure.messaging.outbox_relay import OutboxRelay
from app.infrastructure.observability.telemetry import QuotaTelemetry, run_outbox_gauge_loop
from app.infrastructure.persistence.database import Database
from app.infrastructure.persistence.postgres import PostgresUnitOfWorkFactory

logger = logging.getLogger(__name__)

INCOMING_EVENTS = frozenset({"AudioReceived", "CreditReleaseRequested", "TicketOpened"})


class QuotaServiceContainer(Stoppable):
    """Sobe banco e workers em background; nunca derruba o processo se broker/DB caírem."""

    def __init__(self, settings: Settings) -> None:
        super().__init__()
        self.settings = settings
        self.database = Database(settings)
        self.validator = ContractValidator(settings.contracts_dir, INCOMING_EVENTS)
        self.telemetry = QuotaTelemetry()
        self._workers: list[BrokerWorker] = []
        self._tasks: list[asyncio.Task] = []

    @property
    def broker_up(self) -> bool:
        return bool(self._workers) and all(worker.connected for worker in self._workers)

    async def start(self) -> None:
        self._tasks.append(asyncio.create_task(self._bootstrap(), name="bootstrap"))

    async def stop(self) -> None:
        self.request_stop()
        for worker in self._workers:
            worker.request_stop()
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        await self.database.close()

    async def _bootstrap(self) -> None:
        await self._connect_database()
        if self.stopping:
            return
        use_case = ProcessQuotaUseCase(PostgresUnitOfWorkFactory(self.database.pool))
        broker_url = self.settings.resolved_broker_url()
        self._workers = [
            QuotaConsumer(broker_url, self.settings.broker_queue, self.validator, use_case, self.telemetry),
            OutboxRelay(broker_url, self.settings.broker_exchange, self.database.pool),
        ]
        self._tasks.extend(asyncio.create_task(w.run(), name=w.name) for w in self._workers)
        self._tasks.append(
            asyncio.create_task(
                run_outbox_gauge_loop(self.telemetry, self.database.pool, self),
                name="outbox-gauge",
            )
        )

    async def _connect_database(self) -> None:
        delay = 1
        while not self.stopping:
            try:
                await self.database.connect()
                await self.database.migrate()
                logger.info("database ready")
                return
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("database unavailable; retrying in %ss", delay)
                await self.database.close()
                await self.sleep(delay)
                delay = min(delay * 2, MAX_BACKOFF_SECONDS)
