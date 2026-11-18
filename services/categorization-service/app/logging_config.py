"""Logs em JSON no stdout, com service e os campos de correlação passados em `extra`."""

import json
import logging
import sys
from datetime import datetime, timezone

from .settings import settings

_EXTRA_FIELDS = ("messageId", "correlationId", "type", "db", "otelTraceID", "otelSpanID")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": datetime.fromtimestamp(record.created, timezone.utc).isoformat(),
            "level": record.levelname,
            "service": settings.service_name,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for field in _EXTRA_FIELDS:
            value = getattr(record, field, None)
            if value and value != "0":
                entry[field] = value
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False)


def setup() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    # mantém handlers da instrumentação OTel (exportam para o Loki); só troca a saída de console
    root.handlers = [h for h in root.handlers if not isinstance(h, logging.StreamHandler)] + [handler]
    root.setLevel(logging.INFO)
    logging.getLogger("aio_pika").setLevel(logging.WARNING)
    logging.getLogger("aiormq").setLevel(logging.WARNING)
