"""Postgres: pool assíncrono, migrations no start e tabela processed_messages (R1)."""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

import psycopg
from psycopg_pool import AsyncConnectionPool

from .retry import retry_infra
from .secrets import DbCredentials

log = logging.getLogger("transcription_worker.infra.db")

# Tabelas comuns a todo serviço. As de negócio ficam nos .sql do serviço.
BASE_SCHEMA = """
CREATE TABLE IF NOT EXISTS processed_messages (
    message_id   uuid        PRIMARY KEY,
    processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox (
    id          bigserial   PRIMARY KEY,
    message_id  uuid        NOT NULL UNIQUE,
    type        text        NOT NULL,
    routing_key text        NOT NULL,
    body        jsonb       NOT NULL,
    traceparent text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    sent_at     timestamptz
);
CREATE INDEX IF NOT EXISTS outbox_pending_idx ON outbox (id) WHERE sent_at IS NULL;
"""

_MIGRATION_LOCK_KEY = 7_201_126  # qualquer constante; serializa migrations entre réplicas


class Database:
    def __init__(self, host: str, port: int, creds: DbCredentials, max_size: int = 5) -> None:
        conninfo = psycopg.conninfo.make_conninfo(
            host=host,
            port=port,
            dbname=creds.dbname,
            user=creds.username,
            password=creds.password,
            connect_timeout=5,
            application_name="voxticket",
        )
        self.pool = AsyncConnectionPool(
            conninfo,
            min_size=1,
            max_size=max_size,
            open=False,
            timeout=10,
            kwargs={"autocommit": True},
            check=AsyncConnectionPool.check_connection,  # descarta conexões mortas (banco reiniciou)
        )
        self._up = False

    async def open(self) -> None:
        await self.pool.open(wait=False)

    async def close(self) -> None:
        await self.pool.close()

    @property
    def up(self) -> bool:
        return self._up

    async def ping(self) -> bool:
        try:
            async with asyncio.timeout(3):
                async with self.pool.connection(timeout=2) as conn:
                    await conn.execute("SELECT 1")
            self._up = True
        except Exception:
            self._up = False
        return self._up

    async def migrate(self, migrations_dir: str | Path) -> None:
        """Aplica BASE_SCHEMA + <migrations_dir>/*.sql em ordem, uma vez, sob advisory lock."""
        files = sorted(Path(migrations_dir).glob("*.sql"))

        async def _run() -> None:
            async with self.pool.connection() as conn:
                await conn.execute("SELECT pg_advisory_lock(%s)", (_MIGRATION_LOCK_KEY,))
                try:
                    await conn.execute(
                        "CREATE TABLE IF NOT EXISTS schema_migrations ("
                        " version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
                    )
                    steps = [("000_base", BASE_SCHEMA)] + [(f.stem, f.read_text(encoding="utf-8")) for f in files]
                    for version, sql in steps:
                        cur = await conn.execute("SELECT 1 FROM schema_migrations WHERE version = %s", (version,))
                        if await cur.fetchone():
                            continue
                        async with conn.transaction():
                            await conn.execute(sql)
                            await conn.execute("INSERT INTO schema_migrations(version) VALUES (%s)", (version,))
                        log.info("migration applied", extra={"version": version})
                finally:
                    await conn.execute("SELECT pg_advisory_unlock(%s)", (_MIGRATION_LOCK_KEY,))

        await retry_infra(_run, "migrations", cap=10.0)
        self._up = True


# ---------- consumidor idempotente (R1) ----------


async def already_processed(conn: psycopg.AsyncConnection, message_id: str) -> bool:
    """Checagem barata ANTES do trabalho caro. A garantia real é mark_processed dentro da transação."""
    cur = await conn.execute("SELECT 1 FROM processed_messages WHERE message_id = %s", (message_id,))
    return await cur.fetchone() is not None


async def mark_processed(conn: psycopg.AsyncConnection, message_id: str) -> bool:
    """INSERT ... ON CONFLICT DO NOTHING. False ⇒ mensagem duplicada (já processada por alguém)."""
    cur = await conn.execute(
        "INSERT INTO processed_messages(message_id) VALUES (%s) ON CONFLICT DO NOTHING",
        (message_id,),
    )
    return cur.rowcount == 1
