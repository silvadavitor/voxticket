"""Envelope comum a todas as mensagens + validação contra os JSON Schemas de contracts/."""

import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

CONTRACTS = Path(__file__).resolve().parent.parent / "contracts"


class InvalidMessage(Exception):
    """Payload fora do contrato: vai para a DLQ depois de x-delivery-limit tentativas."""


@lru_cache
def _registry() -> Registry:
    resources = []
    for f in CONTRACTS.glob("*.json"):
        schema = json.loads(f.read_text(encoding="utf-8"))
        resources.append((schema["$id"], Resource.from_contents(schema)))
    return Registry().with_resources(resources)


@lru_cache
def _validator(name: str) -> Draft202012Validator:
    schema = json.loads((CONTRACTS / name).read_text(encoding="utf-8"))
    # format_checker: sem ele o jsonschema ignora "format": "uuid" / "date-time"
    return Draft202012Validator(schema, registry=_registry(), format_checker=Draft202012Validator.FORMAT_CHECKER)


@dataclass(frozen=True)
class Envelope:
    message_id: str
    correlation_id: str
    type: str
    version: int
    occurred_at: str
    payload: dict[str, Any]

    @classmethod
    def parse(cls, body: bytes) -> "Envelope":
        try:
            data = json.loads(body)
        except (ValueError, UnicodeDecodeError) as exc:
            raise InvalidMessage(f"JSON inválido: {exc}") from exc
        if not isinstance(data, dict):
            raise InvalidMessage("envelope não é um objeto")

        schema_file = f"{data.get('type')}.v{data.get('version')}.schema.json"
        validator = _validator(schema_file if (CONTRACTS / schema_file).exists() else "envelope.schema.json")
        errors = sorted(validator.iter_errors(data), key=lambda e: e.path)
        if errors:
            raise InvalidMessage("; ".join(f"{'/'.join(map(str, e.path)) or '<raiz>'}: {e.message}" for e in errors[:3]))

        return cls(
            message_id=data["messageId"],
            correlation_id=data["correlationId"],
            type=data["type"],
            version=data["version"],
            occurred_at=data["occurredAt"],
            payload=data["payload"],
        )


def new_envelope(type_: str, correlation_id: str, payload: dict[str, Any], version: int = 1) -> dict[str, Any]:
    """Cria um envelope novo (para o outbox) e garante que ele respeita o contrato."""
    envelope = {
        "messageId": str(uuid.uuid4()),
        "correlationId": correlation_id,
        "type": type_,
        "version": version,
        "occurredAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "payload": payload,
    }
    schema_file = f"{type_}.v{version}.schema.json"
    if (CONTRACTS / schema_file).exists():
        _validator(schema_file).validate(envelope)
    return envelope
