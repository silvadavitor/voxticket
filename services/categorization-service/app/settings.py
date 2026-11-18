"""Configuração só por variável de ambiente (nada fixo no código)."""

import os
from dataclasses import dataclass
from urllib.parse import quote, urlsplit, urlunsplit


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None:
        raise RuntimeError(f"variável de ambiente obrigatória ausente: {name}")
    return value


@dataclass(frozen=True)
class Settings:
    service_name: str
    environment: str
    # broker
    broker_url: str
    broker_exchange: str
    broker_queue: str
    broker_prefetch: int
    # banco
    db_host: str
    db_port: int
    db_secret_id: str
    # alternativa para rodar fora do compose, sem Secrets Manager
    db_user: str
    db_password: str
    db_name: str
    # AWS (MiniStack local: AWS_ENDPOINT_URL=http://ministack:4566; AWS real: vazio)
    aws_region: str
    aws_endpoint_url: str | None
    s3_bucket: str

    @property
    def broker_url_with_credentials(self) -> str:
        """BROKER_USERNAME/BROKER_PASSWORD (AWS, vindos do Secrets Manager) têm precedência sobre a URL."""
        user = os.environ.get("BROKER_USERNAME")
        password = os.environ.get("BROKER_PASSWORD")
        if not user:
            return self.broker_url
        parts = urlsplit(self.broker_url)
        host = parts.hostname or ""
        if parts.port:
            host = f"{host}:{parts.port}"
        netloc = f"{quote(user, safe='')}:{quote(password or '', safe='')}@{host}"
        return urlunsplit((parts.scheme, netloc, parts.path or "/", parts.query, parts.fragment))


def load() -> Settings:
    return Settings(
        service_name=_env("SERVICE_NAME", "categorization-service"),
        environment=_env("ENVIRONMENT", "local"),
        broker_url=_env("BROKER_URL", "amqp://guest:guest@localhost:5672/"),
        broker_exchange=_env("BROKER_EXCHANGE", "events"),
        broker_queue=_env("BROKER_QUEUE", "categorization-service.q"),
        broker_prefetch=int(_env("BROKER_PREFETCH", "10")),
        db_host=_env("DB_HOST", "localhost"),
        db_port=int(_env("DB_PORT", "5432")),
        db_secret_id=_env("DB_SECRET_ID", ""),
        db_user=_env("DB_USER", ""),
        db_password=_env("DB_PASSWORD", ""),
        db_name=_env("DB_NAME", ""),
        aws_region=_env("AWS_REGION", "us-east-1"),
        aws_endpoint_url=os.environ.get("AWS_ENDPOINT_URL") or None,
        s3_bucket=_env("S3_BUCKET", "voxticket-local-audios"),
    )


settings = load()
