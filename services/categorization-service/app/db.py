"""Banco próprio do serviço: credenciais do Secrets Manager, pool asyncpg e migração no start.

Nunca derruba o processo se o banco estiver fora: tenta de novo com backoff e o /health mostra db=down.
"""

import asyncio
import logging
from pathlib import Path

import asyncpg

from . import aws
from .settings import settings

log = logging.getLogger(__name__)
SCHEMA = (Path(__file__).parent / "schema.sql").read_text(encoding="utf-8")


class Database:
    def __init__(self) -> None:
        self.pool: asyncpg.Pool | None = None
        self.ready = asyncio.Event()

    async def _credentials(self) -> dict:
        if settings.db_secret_id:
            return await asyncio.to_thread(aws.read_secret, settings.db_secret_id)
        # modo dev (fora do compose): credenciais direto do ambiente
        return {"username": settings.db_user, "password": settings.db_password, "dbname": settings.db_name}

    async def connect_forever(self) -> None:
        delay = 1.0
        while self.pool is None:
            try:
                creds = await self._credentials()
                pool = await asyncpg.create_pool(
                    host=settings.db_host,
                    port=settings.db_port,
                    user=creds["username"],
                    password=creds["password"],
                    database=creds["dbname"],
                    min_size=1,
                    max_size=5,
                )
                async with pool.acquire() as conn, conn.transaction():
                    # várias réplicas subindo juntas não brigam pela migração
                    await conn.execute("SELECT pg_advisory_xact_lock(hashtext('categorization-schema'))")
                    await conn.execute(SCHEMA)
                self.pool = pool
                self.ready.set()
                log.info("banco pronto", extra={"db": creds["dbname"]})
            except Exception as exc:  # noqa: BLE001 — qualquer falha de infra vira retry
                log.warning("banco indisponível, tentando de novo em %.0fs: %s", delay, exc)
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)

    async def is_up(self) -> bool:
        if self.pool is None:
            return False
        try:
            async with self.pool.acquire(timeout=2) as conn:
                await conn.fetchval("SELECT 1")
            return True
        except Exception:  # noqa: BLE001
            return False

    async def close(self) -> None:
        if self.pool is not None:
            await self.pool.close()
