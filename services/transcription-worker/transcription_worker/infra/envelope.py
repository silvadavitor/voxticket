"""Envelope obrigatório de toda mensagem e validação contra contracts/schemas.

Arquivos esperados em SCHEMAS_DIR: envelope.schema.json e <Type>.v<version>.schema.json.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import ValidationError, best_match
from referencing import Registry, Resource

from .errors import InvalidMessage


@dataclass(frozen=True)
class Envelope:
    message_id: str
    correlation_id: str
    type: str
    version: int
    occurred_at: str
    payload: dict[str, Any]

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Envelope":
        return cls(
            message_id=data["messageId"],
            correlation_id=data["correlationId"],
            type=data["type"],
            version=data["version"],
            occurred_at=data["occurredAt"],
            payload=data["payload"],
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "messageId": self.message_id,
            "correlationId": self.correlation_id,
            "type": self.type,
            "version": self.version,
            "occurredAt": self.occurred_at,
            "payload": self.payload,
        }


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def new_envelope(type_: str, correlation_id: str, payload: dict[str, Any], version: int = 1) -> Envelope:
    return Envelope(
        message_id=str(uuid.uuid4()),
        correlation_id=correlation_id,
        type=type_,
        version=version,
        occurred_at=utc_now_iso(),
        payload=payload,
    )


class SchemaValidator:
    """Valida envelopes pelo par (type, version) usando os JSON Schemas versionados do repositório."""

    def __init__(self, schemas_dir: str | Path) -> None:
        self.dir = Path(schemas_dir)
        files = sorted(self.dir.glob("*.schema.json"))
        if not files:
            raise FileNotFoundError(f"nenhum schema em {self.dir}")
        resources = []
        self._by_name: dict[str, dict[str, Any]] = {}
        for f in files:
            schema = json.loads(f.read_text(encoding="utf-8"))
            self._by_name[f.name] = schema
            resources.append((schema.get("$id", f.name), Resource.from_contents(schema)))
        self._registry = Registry().with_resources(resources)
        self._format_checker = FormatChecker()
        self._cache: dict[str, Draft202012Validator] = {}

    def _validator(self, name: str) -> Draft202012Validator:
        if name not in self._cache:
            schema = self._by_name.get(name)
            if schema is None:
                raise InvalidMessage(f"schema desconhecido: {name}")
            self._cache[name] = Draft202012Validator(
                schema, registry=self._registry, format_checker=self._format_checker
            )
        return self._cache[name]

    def validate(self, data: Any) -> Envelope:
        """Retorna o Envelope ou levanta InvalidMessage com uma descrição curta do problema."""
        if not isinstance(data, dict):
            raise InvalidMessage("mensagem não é um objeto JSON")
        self._check(self._validator("envelope.schema.json"), data)
        name = f"{data['type']}.v{data['version']}.schema.json"
        self._check(self._validator(name), data)
        return Envelope.from_dict(data)

    def parse(self, body: bytes) -> Envelope:
        try:
            data = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise InvalidMessage(f"JSON inválido: {exc}") from exc
        return self.validate(data)

    @staticmethod
    def _check(validator: Draft202012Validator, data: dict[str, Any]) -> None:
        error = best_match(validator.iter_errors(data))
        if error is not None:
            raise InvalidMessage(_describe(error))


def _describe(error: ValidationError) -> str:
    path = "/".join(str(p) for p in error.absolute_path) or "<raiz>"
    return f"schema: {path}: {error.message}"
