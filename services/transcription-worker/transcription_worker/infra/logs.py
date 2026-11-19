"""Logs estruturados (uma linha JSON por evento).

Todo log emitido durante o processamento de uma mensagem carrega automaticamente
correlationId, messageId e type (via contextvars), além de service, hostname,
trace_id e span_id. É assim que a demo prova o comportamento (grep pelo correlationId).
"""

from __future__ import annotations

import contextlib
import contextvars
import json
import logging
import socket
import sys
from datetime import datetime, timezone
from typing import Any, Iterator

_ctx: contextvars.ContextVar[dict[str, Any]] = contextvars.ContextVar("log_ctx", default={})

_STD_ATTRS = set(vars(logging.makeLogRecord({})).keys()) | {"message", "asctime", "taskName", "color_message"}

HOSTNAME = socket.gethostname()


@contextlib.contextmanager
def log_context(**fields: Any) -> Iterator[None]:
    """Acrescenta campos a todos os logs dentro do bloco (inclusive em tasks filhas)."""
    merged = {**_ctx.get(), **{k: v for k, v in fields.items() if v is not None}}
    token = _ctx.set(merged)
    try:
        yield
    finally:
        _ctx.reset(token)


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str) -> None:
        super().__init__()
        self.service = service

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "service": self.service,
            "hostname": HOSTNAME,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        entry.update(_ctx.get())
        for key, value in vars(record).items():
            if key not in _STD_ATTRS and not key.startswith("_"):
                entry[key] = value
        trace_id, span_id = _current_trace_ids()
        if trace_id:
            entry["trace_id"] = trace_id
            entry["span_id"] = span_id
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False, default=str)


def _current_trace_ids() -> tuple[str | None, str | None]:
    try:
        from opentelemetry import trace

        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            return format(ctx.trace_id, "032x"), format(ctx.span_id, "016x")
    except Exception:  # pragma: no cover - OTel ausente não pode quebrar log
        pass
    return None, None


def setup_logging(service: str, level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())
    # bibliotecas barulhentas
    for noisy in ("aiormq", "aio_pika", "botocore", "boto3", "urllib3", "uvicorn.access", "psycopg.pool"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
