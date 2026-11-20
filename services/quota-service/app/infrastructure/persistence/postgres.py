"""Implementações Postgres das portas (repositórios + Unit of Work)."""
from __future__ import annotations

import json
import uuid
from types import TracebackType

import asyncpg

from app.application.ports import (
    Outbox,
    ProcessedMessageRepository,
    QuotaRepository,
    ReservationRepository,
    TenantAdmin,
    UnitOfWork,
    UnitOfWorkFactory,
)
from app.domain.events import IntegrationEvent
from app.domain.reservation import Reservation, ReservationStatus
from app.domain.tenant import Tenant


class PostgresQuotaRepository(QuotaRepository):
    def __init__(self, connection: asyncpg.Connection) -> None:
        self._connection = connection

    async def try_reserve(self, tenant_id: str) -> bool:
        row = await self._connection.fetchrow(
            "UPDATE tenant_quota SET used = used + 1 "
            "WHERE tenant_id = $1 AND used < quota_limit RETURNING tenant_id",
            tenant_id,
        )
        return row is not None

    async def ensure_tenant_exists(self, tenant_id: str) -> None:
        await self._connection.execute(
            "INSERT INTO tenant_quota (tenant_id, quota_limit, used) VALUES ($1, 0, 0) "
            "ON CONFLICT (tenant_id) DO NOTHING",
            tenant_id,
        )

    async def release(self, tenant_id: str) -> None:
        await self._connection.execute(
            "UPDATE tenant_quota SET used = used - 1 WHERE tenant_id = $1 AND used > 0",
            tenant_id,
        )


class PostgresTenantAdmin(TenantAdmin):
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def list(self) -> list[Tenant]:
        rows = await self._pool.fetch("SELECT tenant_id, quota_limit, used FROM tenant_quota ORDER BY tenant_id")
        return [Tenant(**dict(row)) for row in rows]

    async def get(self, tenant_id: str) -> Tenant | None:
        row = await self._pool.fetchrow(
            "SELECT tenant_id, quota_limit, used FROM tenant_quota WHERE tenant_id = $1", tenant_id
        )
        return Tenant(**dict(row)) if row else None

    async def set_limit(self, tenant_id: str, quota_limit: int) -> Tenant | None:
        # o WHERE impede baixar o limite abaixo do que já foi reservado
        row = await self._pool.fetchrow(
            """
            INSERT INTO tenant_quota (tenant_id, quota_limit, used) VALUES ($1, $2, 0)
            ON CONFLICT (tenant_id) DO UPDATE SET quota_limit = EXCLUDED.quota_limit
            WHERE tenant_quota.used <= EXCLUDED.quota_limit
            RETURNING tenant_id, quota_limit, used
            """,
            tenant_id,
            quota_limit,
        )
        return Tenant(**dict(row)) if row else None


class PostgresReservationRepository(ReservationRepository):
    _COLUMNS = "request_id::text, tenant_id, reservation_id::text, status, created_at, updated_at"

    def __init__(self, connection: asyncpg.Connection) -> None:
        self._connection = connection

    async def find_by_request_id(self, request_id: str) -> Reservation | None:
        row = await self._connection.fetchrow(
            f"SELECT {self._COLUMNS} FROM reservations WHERE request_id = $1",
            uuid.UUID(request_id),
        )
        return self._to_entity(row) if row else None

    async def add(self, reservation: Reservation) -> Reservation:
        row = await self._connection.fetchrow(
            f"""
            INSERT INTO reservations (request_id, tenant_id, reservation_id, status, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (request_id) DO NOTHING
            RETURNING {self._COLUMNS}
            """,
            uuid.UUID(reservation.request_id),
            reservation.tenant_id,
            uuid.UUID(reservation.reservation_id),
            reservation.status.value,
            reservation.created_at,
            reservation.updated_at,
        )
        if row is not None:
            return self._to_entity(row)
        existing = await self.find_by_request_id(reservation.request_id)
        if existing is None:  # pragma: no cover - inconsistência impossível
            raise RuntimeError("reservation conflict without existing row")
        return existing

    async def mark_released(self, request_id: str, tenant_id: str) -> bool:
        row = await self._connection.fetchrow(
            "UPDATE reservations SET status = 'RELEASED', updated_at = now() "
            "WHERE request_id = $1 AND tenant_id = $2 AND status = 'RESERVED' "
            "RETURNING request_id",
            uuid.UUID(request_id),
            tenant_id,
        )
        return row is not None

    async def mark_consumed(self, request_id: str, tenant_id: str) -> bool:
        row = await self._connection.fetchrow(
            "UPDATE reservations SET status = 'CONSUMED', updated_at = now() "
            "WHERE request_id = $1 AND tenant_id = $2 AND status = 'RESERVED' "
            "RETURNING request_id",
            uuid.UUID(request_id),
            tenant_id,
        )
        return row is not None

    @staticmethod
    def _to_entity(row: asyncpg.Record) -> Reservation:
        return Reservation(
            request_id=row["request_id"],
            tenant_id=row["tenant_id"],
            reservation_id=row["reservation_id"],
            status=ReservationStatus(row["status"]),
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )


class PostgresProcessedMessageRepository(ProcessedMessageRepository):
    def __init__(self, connection: asyncpg.Connection) -> None:
        self._connection = connection

    async def register(self, message_id: str) -> bool:
        inserted = await self._connection.fetchval(
            "INSERT INTO processed_messages (message_id) VALUES ($1) ON CONFLICT DO NOTHING RETURNING message_id",
            uuid.UUID(message_id),
        )
        return inserted is not None


class PostgresOutbox(Outbox):
    def __init__(self, connection: asyncpg.Connection) -> None:
        self._connection = connection

    async def add(self, event: IntegrationEvent, traceparent: str | None) -> None:
        await self._connection.execute(
            "INSERT INTO outbox (id, type, correlation_id, envelope, traceparent) VALUES ($1, $2, $3, $4::jsonb, $5)",
            uuid.UUID(event.message_id),
            event.type,
            uuid.UUID(event.correlation_id),
            json.dumps(event.to_envelope(), ensure_ascii=False),
            traceparent,
        )


class PostgresUnitOfWork(UnitOfWork):
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool
        self._connection: asyncpg.Connection | None = None
        self._transaction = None

    async def __aenter__(self) -> "PostgresUnitOfWork":
        self._connection = await self._pool.acquire()
        self._transaction = self._connection.transaction()
        await self._transaction.start()
        self.quotas = PostgresQuotaRepository(self._connection)
        self.reservations = PostgresReservationRepository(self._connection)
        self.processed_messages = PostgresProcessedMessageRepository(self._connection)
        self.outbox = PostgresOutbox(self._connection)
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        try:
            if exc_type is None:
                await self._transaction.commit()
            else:
                await self._transaction.rollback()
        finally:
            await self._pool.release(self._connection)
            self._connection = None


class PostgresUnitOfWorkFactory(UnitOfWorkFactory):
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    def create(self) -> UnitOfWork:
        return PostgresUnitOfWork(self._pool)
