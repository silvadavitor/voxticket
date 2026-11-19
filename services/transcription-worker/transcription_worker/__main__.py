"""Ponto de entrada: python -m transcription_worker"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import asdict

from .infra.service import ServiceRuntime

from .handlers import TranscriptionHandlers
from .settings import Settings
from .storage import Storage
from .transcriber import Transcriber, load_model

log = logging.getLogger("transcription_worker")


async def main() -> None:
    runtime = ServiceRuntime()
    s = Settings.from_env()
    model = await asyncio.to_thread(load_model, s.whisper_model, s.models_dir)
    log.info("whisper model loaded", extra={"model": s.whisper_model, "language": s.whisper_language})
    transcriber = Transcriber(
        model, s.whisper_language, s.latency_ms_min, s.latency_ms_max, s.failure_rate, s.max_attempts
    )
    storage = Storage(s.s3_bucket)
    runtime.health_extra = lambda: {"settings": asdict(s)}

    def handlers(rt: ServiceRuntime) -> dict:
        assert rt.db is not None
        return TranscriptionHandlers(rt.db, storage, transcriber, rt.validator, rt.hostname).as_dict()

    await runtime.run(s.migrations_dir, handlers)


if __name__ == "__main__":
    asyncio.run(main())
