from __future__ import annotations

import asyncio
import io
import logging
import random
import time
from dataclasses import dataclass
from typing import Any

log = logging.getLogger("transcription_worker.transcriber")


@dataclass(frozen=True)
class Result:
    text: str | None
    language: str | None
    attempts: int
    duration_ms: int
    reason: str | None = None


def load_model(name: str, models_dir: str) -> Any:
    from faster_whisper import WhisperModel

    return WhisperModel(name, device="cpu", compute_type="int8", download_root=models_dir)


class Transcriber:
    def __init__(
        self,
        model: Any,
        language: str | None,
        latency_ms_min: int = 0,
        latency_ms_max: int = 0,
        failure_rate: float = 0.0,
        max_attempts: int = 3,
        rng: random.Random | None = None,
        retry_delay_s: float = 0.5,
    ) -> None:
        self.model = model
        self.language = language
        self.lo, self.hi = latency_ms_min, latency_ms_max
        self.failure_rate = failure_rate
        self.max_attempts = max_attempts
        self.rng = rng or random.Random()
        self.retry_delay_s = retry_delay_s

    def _whisper(self, audio: bytes) -> tuple[str, str]:
        segments, info = self.model.transcribe(io.BytesIO(audio), language=self.language, vad_filter=True)
        return " ".join(s.text.strip() for s in segments).strip(), info.language

    async def transcribe(self, audio: bytes) -> Result:
        start = time.monotonic()
        error = "unknown"
        for attempt in range(1, self.max_attempts + 1):
            try:
                if self.hi > 0:
                    await asyncio.sleep(self.rng.uniform(self.lo, self.hi) / 1000)
                if self.rng.random() < self.failure_rate:
                    raise RuntimeError("falha injetada (TRANSCRIBE_FAILURE_RATE)")
                text, language = await asyncio.to_thread(self._whisper, audio)
                log.info("attempt %d/%d ok", attempt, self.max_attempts, extra={"language": language})
                return Result(text, language, attempt, _ms_since(start))
            except Exception as exc:  # áudio corrompido, falha do modelo ou falha injetada
                error = f"{type(exc).__name__}: {exc}"
                log.warning("attempt %d/%d failed: %s", attempt, self.max_attempts, error)
                if attempt < self.max_attempts:
                    await asyncio.sleep(self.retry_delay_s * attempt)
        return Result(None, None, self.max_attempts, _ms_since(start), reason=f"TRANSCRIPTION_FAILED: {error}"[:500])


def _ms_since(start: float) -> int:
    return int((time.monotonic() - start) * 1000)
