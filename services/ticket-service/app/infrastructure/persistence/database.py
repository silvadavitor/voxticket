"""Pool do Postgres (credenciais do Secrets Manager) e migrations."""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import asyncpg
import boto3

from app.infrastructure.config.settings import Settings

logger = logging.getLogger(__name__)


class SecretsManagerCredentials:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    async def load(self) -> dict[str, Any]:
        if not self._settings.db_secret_id:
            return {}
        return await asyncio.to_thread(self._fetch)

    def _fetch(self) -> dict[str, Any]:
        client = boto3.client(
            "secretsmanager",
            region_name=self._settings.aws_region,
            endpoint_url=self._settings.aws_endpoint_url,
        )
        response = client.get_secret_value(SecretId=self._settings.db_secret_id)
        return json.loads(response["SecretString"])


class Database:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._pool: asyncpg.Pool | None = None

    @property
    def pool(self) -> asyncpg.Pool:
        if self._pool is None:
            raise RuntimeError("Database not connected")
        return self._pool

    async def connect(self) -> None:
        credentials = await SecretsManagerCredentials(self._settings).load()
        s = self._settings
        self._pool = await asyncpg.create_pool(
            host=s.db_host,
            port=s.db_port,
            database=s.db_name or credentials.get("dbname", "ticket"),
            user=s.db_username or credentials.get("username", "ticket_user"),
            password=s.db_password or credentials.get("password", ""),
            min_size=1,
            max_size=10,
            command_timeout=30,
        )

    async def migrate(self) -> None:
        files = sorted(self._settings.migrations_dir.glob("*.sql"))
        async with self.pool.acquire() as connection:
            for file in files:
                logger.info("applying migration %s", file.name)
                await connection.execute(file.read_text(encoding="utf-8"))

    async def is_healthy(self) -> bool:
        if self._pool is None:
            return False
        try:
            await asyncio.wait_for(self._pool.fetchval("SELECT 1"), timeout=2)
            return True
        except Exception:
            return False

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()
