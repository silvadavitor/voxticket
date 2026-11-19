"""Logs estruturados em JSON com correlationId/messageId/type/service."""
from __future__ import annotations

import contextvars
import json
import logging
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Iterator

from opentelemetry import trace

_log_context: contextvars.ContextVar[dict[str, str]] = contextvars.ContextVar("log_context", default={})


@contextmanager
def message_log_context(correlation_id: str, message_id: str, event_type: str) -> Iterator[None]:
    token = _log_context.set({"correlationId": correlation_id, "messageId": message_id, "type": event_type})
    try:
        yield
    finally:
        _log_context.reset(token)


class JsonFormatter(logging.Formatter):
    def __init__(self, service_name: str) -> None:
        super().__init__()
        self._service_name = service_name

    def format(self, record: logging.LogRecord) -> str:
        span_context = trace.get_current_span().get_span_context()
        context = _log_context.get()
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "service": self._service_name,
            "correlationId": context.get("correlationId"),
            "messageId": context.get("messageId"),
            "type": context.get("type"),
            "trace_id": f"{span_context.trace_id:032x}" if span_context.is_valid else None,
            "span_id": f"{span_context.span_id:016x}" if span_context.is_valid else None,
        }
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False)


def configure_logging(service_name: str) -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter(service_name))
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.INFO)
    logging.getLogger("aio_pika").setLevel(logging.WARNING)
    logging.getLogger("aiormq").setLevel(logging.WARNING)
