"""Configuração lida exclusivamente de variáveis de ambiente."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from yarl import URL

_SERVICE_ROOT = Path(__file__).resolve().parents[3]


@dataclass(frozen=True)
class Settings:
    service_name: str
    broker_url: str
    broker_username: str
    broker_password: str
    broker_exchange: str
    broker_queue: str
    db_host: str
    db_port: int
    db_name: str | None
    db_username: str | None
    db_password: str
    db_secret_id: str | None
    aws_region: str
    aws_endpoint_url: str | None
    contracts_dir: Path
    migrations_dir: Path

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            service_name=os.getenv("SERVICE_NAME", "quota-service"),
            broker_url=os.getenv("BROKER_URL", "amqp://guest:guest@localhost:5672/"),
            broker_username=os.getenv("BROKER_USERNAME", ""),
            broker_password=os.getenv("BROKER_PASSWORD", ""),
            broker_exchange=os.getenv("BROKER_EXCHANGE", "events"),
            broker_queue=os.getenv("BROKER_QUEUE", "quota-service.q"),
            db_host=os.getenv("DB_HOST", "localhost"),
            db_port=int(os.getenv("DB_PORT", "5432")),
            db_name=os.getenv("DB_NAME") or None,
            db_username=os.getenv("DB_USERNAME") or None,
            db_password=os.getenv("DB_PASSWORD", ""),
            db_secret_id=os.getenv("DB_SECRET_ID") or None,
            aws_region=os.getenv("AWS_REGION", "us-east-1"),
            aws_endpoint_url=os.getenv("AWS_ENDPOINT_URL") or None,
            contracts_dir=Path(os.getenv("CONTRACTS_DIR", _SERVICE_ROOT / "contracts" / "schemas")),
            migrations_dir=Path(os.getenv("MIGRATIONS_DIR", _SERVICE_ROOT / "migrations")),
        )

    def resolved_broker_url(self) -> str:
        """Credenciais explícitas têm precedência sobre as da URL."""
        url = URL(self.broker_url)
        if self.broker_username or self.broker_password:
            url = url.with_user(self.broker_username).with_password(self.broker_password)
        return str(url)
