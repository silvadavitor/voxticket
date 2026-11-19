"""Validação dos envelopes contra os JSON Schemas de ``contracts/``."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker, ValidationError
from referencing import Registry, Resource


class InvalidEnvelope(ValueError):
    """Mensagem malformada: não adianta reprocessar."""


class ContractValidator:
    def __init__(self, schema_dir: Path, accepted_types: frozenset[str]) -> None:
        documents = [json.loads(p.read_text(encoding="utf-8")) for p in schema_dir.glob("*.schema.json")]
        registry = Registry()
        for document in documents:
            registry = registry.with_resource(document["$id"], Resource.from_contents(document))
        self._accepted_types = accepted_types
        self._validators = {
            document["$id"].removesuffix(".v1.schema.json"): Draft202012Validator(
                document, registry=registry, format_checker=FormatChecker()
            )
            for document in documents
            if document["$id"] != "envelope.schema.json"
        }
        missing = accepted_types - self._validators.keys()
        if missing:
            raise RuntimeError(f"Missing contract schemas in {schema_dir}: {sorted(missing)}")

    def validate(self, raw: bytes | str) -> dict[str, Any]:
        try:
            envelope = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError, TypeError) as error:
            raise InvalidEnvelope(f"invalid JSON: {error}") from error
        if not isinstance(envelope, dict):
            raise InvalidEnvelope("envelope must be a JSON object")

        event_type = envelope.get("type")
        if event_type not in self._accepted_types:
            raise InvalidEnvelope(f"unexpected event type: {event_type}")
        try:
            self._validators[event_type].validate(envelope)
        except ValidationError as error:
            path = ".".join(str(p) for p in error.absolute_path)
            raise InvalidEnvelope(f"invalid {event_type}{' at ' + path if path else ''}: {error.message}") from error
        return envelope
