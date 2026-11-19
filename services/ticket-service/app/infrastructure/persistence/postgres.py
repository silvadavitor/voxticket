"""Implementações Postgres das portas (repositórios + Unit of Work)."""
from __future__ import annotations

import json
import uuid
from types import TracebackType

import asyncpg

from app.application.ports import (
    Outbox,
    ProcessedMessageRepository,
    TicketQueries,
    TicketRepository,
    UnitOfWork,
    UnitOfWorkFactory,
)
from app.domain.events import IntegrationEvent
from app.domain.ticket import Ticket, TicketStatus


class PostgresTicketRepository(TicketRepository):
    _COLUMNS = "ticket_id, request_id::text, tenant_id, category, priority, transcript_key, status, created_at"

    def __init__(self, connection: asyncpg.Connection) -> None:
        self._connection = connection

    async def find_by_request_id(self, request_id: str) -> Ticket | None:
        row = await self._connection.fetchrow(
            f"SELECT {self._COLUMNS} FROM tickets WHERE request_id = $1", uuid.UUID(request_id)
        )
        return self._to_entity(row) if row else None

    async def add(self, ticket: Ticket) -> Ticket:
        row = await self._connection.fetchrow(
            f"""
            INSERT INTO tickets (ticket_id, request_id, tenant_id, category, priority, transcript_key, status, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (request_id) DO NOTHING
            RETURNING {self._COLUMNS}
            """,
            ticket.ticket_id,
            uuid.UUID(ticket.request_id),
            ticket.tenant_id,
            ticket.category,
            ticket.priority,
            ticket.transcript_key,
            ticket.status.value,
            ticket.created_at,
        )
        if row is not None:
            return self._to_entity(row)
        existing = await self.find_by_request_id(ticket.request_id)
        if existing is None:  # pragma: no cover - inconsistência impossível
            raise RuntimeError("ticket conflict without existing row")
        return existing

    @staticmethod
    def _to_entity(row: asyncpg.Record) -> Ticket:
        return Ticket(
            ticket_id=row["ticket_id"],
            request_id=row["request_id"],
            tenant_id=row["tenant_id"],
            category=row["category"],
            priority=row["priority"],
            transcript_key=row["transcript_key"],
            status=TicketStatus(row["status"]),
            created_at=row["created_at"],
        )


class PostgresTicketQueries(TicketQueries):
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def list(self, tenant_id: str | None, limit: int) -> list[Ticket]:
        columns = PostgresTicketRepository._COLUMNS
        if tenant_id:
            rows = await self._pool.fetch(
                f"SELECT {columns} FROM tickets WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT $2", tenant_id, limit
            )
        else:
            rows = await self._pool.fetch(f"SELECT {columns} FROM tickets ORDER BY created_at DESC LIMIT $1", limit)
        return [PostgresTicketRepository._to_entity(row) for row in rows]

    async def get(self, ticket_id: str) -> Ticket | None:
        row = await self._pool.fetchrow(
            f"SELECT {PostgresTicketRepository._COLUMNS} FROM tickets WHERE ticket_id = $1", ticket_id
        )
        return PostgresTicketRepository._to_entity(row) if row else None


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
        self.tickets = PostgresTicketRepository(self._connection)
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
