from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import dataclass

import boto3

from .config import ConfigError, env_str
from .retry import Backoff

log = logging.getLogger("transcription_worker.infra.secrets")


@dataclass(frozen=True)
class DbCredentials:
    username: str
    password: str
    dbname: str


def _fetch_secret(secret_id: str) -> dict:
    client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION"))
    raw = client.get_secret_value(SecretId=secret_id)["SecretString"]
    return json.loads(raw)


async def load_db_credentials(stop: asyncio.Event | None = None) -> DbCredentials:
    secret_id = env_str("DB_SECRET_ID")
    if secret_id is None:
        user, password, name = env_str("DB_USER"), env_str("DB_PASSWORD"), env_str("DB_NAME")
        if not (user and password and name):
            raise ConfigError("defina DB_SECRET_ID (ou DB_USER/DB_PASSWORD/DB_NAME fora do compose)")
        log.warning("DB_SECRET_ID ausente: usando DB_USER/DB_PASSWORD/DB_NAME do ambiente")
        return DbCredentials(user, password, name)

    backoff = Backoff(base=1.0, cap=15.0)
    while True:
        try:
            data = await asyncio.to_thread(_fetch_secret, secret_id)
            log.info("db credentials loaded from secrets manager", extra={"secret_id": secret_id})
            return DbCredentials(data["username"], data["password"], data["dbname"])
        except Exception as exc:  # Secrets Manager / MiniStack ainda subindo: tenta de novo
            if stop is not None and stop.is_set():
                raise
            delay = backoff.next_delay()
            log.warning("could not read secret %s, retrying in %.1fs: %s", secret_id, delay, exc)
            await asyncio.sleep(delay)
