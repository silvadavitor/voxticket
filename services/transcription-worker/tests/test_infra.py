import json
import uuid
from pathlib import Path

import pytest

from transcription_worker.infra.broker import build_broker_url, redact
from transcription_worker.infra.envelope import SchemaValidator, new_envelope
from transcription_worker.infra.errors import InfraUnavailable, InvalidMessage, is_infra_error
from transcription_worker.infra.retry import retry_infra

SCHEMAS = Path(__file__).resolve().parents[1] / "contracts"  # cópia local (scripts/sync-contracts.sh)
REPO_SCHEMAS = Path(__file__).resolve().parents[3] / "contracts" / "schemas"  # fonte da verdade


def test_contracts_in_sync():
    """A cópia em contracts/ tem que ser idêntica a contracts/schemas do repo."""
    for local in SCHEMAS.glob("*.schema.json"):
        source = REPO_SCHEMAS / local.name
        assert source.read_bytes().replace(b"\r\n", b"\n") == local.read_bytes().replace(b"\r\n", b"\n"), (
            f"{local.name} divergiu de contracts/schemas: rode scripts/sync-contracts.sh"
        )


@pytest.fixture(scope="module")
def validator() -> SchemaValidator:
    return SchemaValidator(SCHEMAS)


def _transcription_requested(**payload_overrides):
    rid = str(uuid.uuid4())
    payload = {"requestId": rid, "tenantId": "tenant-demo", "audioKey": f"audios/tenant-demo/{rid}.ogg"}
    payload.update(payload_overrides)
    return new_envelope("TranscriptionRequested", rid, payload).to_dict()


def test_valid_message_passes(validator):
    env = validator.parse(json.dumps(_transcription_requested()).encode())
    assert env.type == "TranscriptionRequested"
    assert env.payload["tenantId"] == "tenant-demo"


def test_missing_required_payload_field(validator):
    data = _transcription_requested()
    del data["payload"]["audioKey"]
    with pytest.raises(InvalidMessage, match="audioKey"):
        validator.validate(data)


def test_bad_uuid_is_rejected(validator):
    data = _transcription_requested()
    data["messageId"] = "not-a-uuid"
    with pytest.raises(InvalidMessage):
        validator.validate(data)


def test_bad_datetime_is_rejected(validator):
    data = _transcription_requested()
    data["occurredAt"] = "ontem"
    with pytest.raises(InvalidMessage):
        validator.validate(data)


def test_extra_envelope_field_is_rejected(validator):
    data = _transcription_requested()
    data["oops"] = 1
    with pytest.raises(InvalidMessage):
        validator.validate(data)


def test_invalid_json(validator):
    with pytest.raises(InvalidMessage, match="JSON"):
        validator.parse(b"{not json")


def test_unknown_version(validator):
    data = _transcription_requested()
    data["version"] = 99
    with pytest.raises(InvalidMessage, match="schema desconhecido"):
        validator.validate(data)


def test_outgoing_events_match_contract(validator):
    rid = str(uuid.uuid4())
    ok = new_envelope(
        "AudioTranscribed",
        rid,
        {"requestId": rid, "transcriptKey": f"transcripts/{rid}.json", "processedBy": "w1", "durationMs": 10},
    )
    validator.validate(ok.to_dict())
    failed = new_envelope("TranscriptionFailed", rid, {"requestId": rid, "attempts": 3, "reason": "x"})
    validator.validate(failed.to_dict())


def test_broker_credentials_take_precedence():
    url = build_broker_url("amqps://b-123.mq.us-east-1.amazonaws.com:5671", "svc", "p@ss/word")
    assert url == "amqps://svc:p%40ss%2Fword@b-123.mq.us-east-1.amazonaws.com:5671/"
    assert build_broker_url("amqp://guest:guest@rabbitmq:5672/", None, None) == "amqp://guest:guest@rabbitmq:5672/"
    assert "guest" not in redact("amqp://guest:guest@rabbitmq:5672/")


def test_error_classification():
    import psycopg
    from botocore.exceptions import ClientError, EndpointConnectionError

    assert is_infra_error(psycopg.OperationalError("down"))
    assert is_infra_error(EndpointConnectionError(endpoint_url="http://ministack:4566"))
    assert is_infra_error(ClientError({"Error": {"Code": "InternalError"}, "ResponseMetadata": {"HTTPStatusCode": 500}}, "Put"))
    assert not is_infra_error(ClientError({"Error": {"Code": "NoSuchKey"}, "ResponseMetadata": {"HTTPStatusCode": 404}}, "Get"))
    assert not is_infra_error(InvalidMessage("x"))
    assert not is_infra_error(KeyError("x"))


async def test_retry_infra_holds_until_success(monkeypatch):
    import transcription_worker.infra.retry as r

    async def no_sleep(_):
        return None

    monkeypatch.setattr(r.asyncio, "sleep", no_sleep)
    calls = {"n": 0}

    async def flaky():
        calls["n"] += 1
        if calls["n"] < 4:
            raise InfraUnavailable("db down")
        return "ok"

    assert await retry_infra(flaky, "test") == "ok"
    assert calls["n"] == 4


async def test_retry_infra_does_not_retry_bugs():
    async def bug():
        raise ValueError("bug")

    with pytest.raises(ValueError):
        await retry_infra(bug, "test")
