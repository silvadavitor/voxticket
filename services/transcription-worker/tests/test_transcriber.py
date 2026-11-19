import random
from types import SimpleNamespace

import pytest

from transcription_worker.settings import Settings
from transcription_worker.storage import transcript_key
from transcription_worker.transcriber import Transcriber
from transcription_worker.infra.config import ConfigError


class FakeModel:
    """Imita faster_whisper.WhisperModel.transcribe."""

    def __init__(self, fail_times: int = 0) -> None:
        self.fail_times = fail_times
        self.calls = 0

    def transcribe(self, audio, language=None, vad_filter=False):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise ValueError("invalid data found when processing input")
        segments = [SimpleNamespace(text=" Olá, "), SimpleNamespace(text="o sistema caiu. ")]
        return iter(segments), SimpleNamespace(language=language or "pt")


def make(model, rate: float = 0.0, attempts: int = 3) -> Transcriber:
    return Transcriber(model, "pt", 0, 0, rate, attempts, rng=random.Random(42), retry_delay_s=0)


async def test_joins_whisper_segments():
    r = await make(FakeModel()).transcribe(b"audio")
    assert (r.text, r.language, r.attempts) == ("Olá, o sistema caiu.", "pt", 1)


async def test_model_error_is_retried():
    r = await make(FakeModel(fail_times=2)).transcribe(b"audio")
    assert r.text and r.attempts == 3


async def test_gives_up_after_max_attempts():
    r = await make(FakeModel(fail_times=99), attempts=3).transcribe(b"audio")
    assert r.text is None and r.attempts == 3
    assert r.reason.startswith("TRANSCRIPTION_FAILED: ValueError")


async def test_injected_failure_rate_one_always_fails():
    model = FakeModel()
    r = await make(model, rate=1.0).transcribe(b"audio")
    assert r.text is None and model.calls == 0  # falha injetada antes de chamar o Whisper


def test_transcript_key_is_deterministic():
    assert transcript_key("abc") == "transcripts/abc.json"


def test_settings(monkeypatch):
    monkeypatch.setenv("S3_BUCKET", "b")
    s = Settings.from_env()
    assert (s.whisper_model, s.whisper_language, s.failure_rate, s.latency_ms_max) == ("base", "pt", 0.0, 0)
    monkeypatch.setenv("WHISPER_LANGUAGE", "auto")
    assert Settings.from_env().whisper_language is None
    monkeypatch.setenv("TRANSCRIBE_FAILURE_RATE", "1.5")
    with pytest.raises(ConfigError):
        Settings.from_env()
