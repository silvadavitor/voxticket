from __future__ import annotations

import os


class ConfigError(RuntimeError):
    """Variável obrigatória ausente ou inválida. Derruba o processo na inicialização (de propósito)."""


def env_str(name: str, default: str | None = None, *, required: bool = False) -> str | None:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        if required and default is None:
            raise ConfigError(f"variável de ambiente obrigatória ausente: {name}")
        return default
    return value.strip()


def env_req(name: str) -> str:
    value = env_str(name, required=True)
    assert value is not None
    return value


def env_int(name: str, default: int) -> int:
    raw = env_str(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} deve ser inteiro, recebido {raw!r}") from exc


def env_float(name: str, default: float) -> float:
    raw = env_str(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} deve ser número, recebido {raw!r}") from exc


def normalize_aws_env() -> None:
    if os.environ.get("AWS_ENDPOINT_URL", "").strip() == "":
        os.environ.pop("AWS_ENDPOINT_URL", None)
