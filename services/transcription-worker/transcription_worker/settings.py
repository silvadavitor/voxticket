"""Configuração do worker (só variáveis de ambiente)."""

from __future__ import annotations

from dataclasses import dataclass

from .infra.config import ConfigError, env_float, env_int, env_req, env_str


@dataclass(frozen=True)
class Settings:
    s3_bucket: str
    whisper_model: str
    whisper_language: str | None
    models_dir: str
    latency_ms_min: int
    latency_ms_max: int
    failure_rate: float
    max_attempts: int
    migrations_dir: str

    @classmethod
    def from_env(cls) -> "Settings":
        lo = env_int("TRANSCRIBE_LATENCY_MS_MIN", 0)
        hi = env_int("TRANSCRIBE_LATENCY_MS_MAX", 0)
        rate = env_float("TRANSCRIBE_FAILURE_RATE", 0.0)
        attempts = env_int("TRANSCRIBE_MAX_ATTEMPTS", 3)
        lang = env_str("WHISPER_LANGUAGE", "pt")  # "auto" = o Whisper detecta
        if not 0.0 <= rate <= 1.0:
            raise ConfigError("TRANSCRIBE_FAILURE_RATE deve estar entre 0.0 e 1.0")
        if attempts < 1 or lo < 0 or hi < 0:
            raise ConfigError("TRANSCRIBE_MAX_ATTEMPTS >= 1 e latências >= 0")
        return cls(
            s3_bucket=env_req("S3_BUCKET"),
            whisper_model=env_str("WHISPER_MODEL", "base") or "base",
            whisper_language=None if lang == "auto" else lang,
            models_dir=env_str("WHISPER_MODELS_DIR", "/models") or "/models",
            latency_ms_min=min(lo, hi),
            latency_ms_max=max(lo, hi),
            failure_rate=rate,
            max_attempts=attempts,
            migrations_dir=env_str("MIGRATIONS_DIR", "/app/migrations") or "/app/migrations",
        )
