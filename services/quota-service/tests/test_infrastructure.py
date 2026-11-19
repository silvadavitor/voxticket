import asyncio
import json
import logging
import uuid
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest
from aio_pika import DeliveryMode

from app.application.process_quota import ProcessQuotaResult, QuotaOutcome
from app.infrastructure.config.settings import Settings
from app.infrastructure.messaging.contract_validator import ContractValidator, InvalidEnvelope
from app.infrastructure.messaging.consumer import QuotaConsumer
from app.infrastructure.messaging.outbox_relay import OutboxRelay
from app.infrastructure.observability.logging import JsonFormatter, message_log_context
from app.infrastructure.observability.telemetry import QuotaTelemetry
from app.presentation.health import build_health_router

SCHEMAS = Path(__file__).resolve().parents[1] / "contracts" / "schemas"


def run(coro):
    return asyncio.run(coro)


def test_settings_from_env_and_broker_credentials_precedence(monkeypatch):
    monkeypatch.setenv("SERVICE_NAME", "quota-custom")
    monkeypatch.setenv("BROKER_URL", "amqp://old:old@rabbitmq:5672/")
    monkeypatch.setenv("BROKER_USERNAME", "awsuser")
    monkeypatch.setenv("BROKER_PASSWORD", "awspass")
    monkeypatch.setenv("DB_PORT", "5433")

    settings = Settings.from_env()
    assert settings.service_name == "quota-custom"
    assert settings.db_port == 5433
    assert settings.resolved_broker_url() == "amqp://awsuser:awspass@rabbitmq:5672/"


@pytest.mark.parametrize(
    "broker_up, db_up, expected_broker, expected_db",
    [
        (False, False, "down", "down"),
        (False, True, "down", "up"),
        (True, True, "up", "up"),
    ],
)
def test_health_endpoint_always_returns_200(broker_up, db_up, expected_broker, expected_db):
    container = MagicMock()
    container.broker_up = broker_up
    container.database = MagicMock()
    container.database.is_healthy = AsyncMock(return_value=db_up)

    router = build_health_router(container)
    route = next(r for r in router.routes if r.path == "/health")
    assert "GET" in route.methods
    assert run(route.endpoint()) == {"status": "ok", "broker": expected_broker, "db": expected_db}


def test_json_formatter_includes_required_fields():
    formatter = JsonFormatter("quota-service")
    record = logging.LogRecord(
        name="app.test",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="hello %s",
        args=("world",),
        exc_info=None,
    )
    corr_id = str(uuid.uuid4())
    msg_id = str(uuid.uuid4())
    with message_log_context(corr_id, msg_id, "AudioReceived"):
        payload = json.loads(formatter.format(record))

    assert payload["level"] == "INFO"
    assert payload["message"] == "hello world"
    assert payload["service"] == "quota-service"
    assert payload["correlationId"] == corr_id
    assert payload["messageId"] == msg_id
    assert payload["type"] == "AudioReceived"
    assert "timestamp" in payload
    assert "trace_id" in payload
    assert "span_id" in payload


def test_consumer_nacks_invalid_payload_without_ack():
    validator = ContractValidator(SCHEMAS, frozenset({"AudioReceived", "CreditReleaseRequested", "TicketOpened"}))
    use_case = MagicMock()
    use_case.execute = AsyncMock()
    telemetry = QuotaTelemetry()
    consumer = QuotaConsumer("amqp://localhost/", "quota-service.q", validator, use_case, telemetry)

    message = MagicMock()
    message.body = b"not-json"
    message.headers = {}
    message.nack = AsyncMock()
    message.ack = AsyncMock()

    run(consumer.handle(message))
    message.nack.assert_awaited_once_with(requeue=True)
    message.ack.assert_not_awaited()
    use_case.execute.assert_not_awaited()


def test_consumer_retries_infra_error_and_acks_after_success(monkeypatch):
    validator = ContractValidator(SCHEMAS, frozenset({"AudioReceived", "CreditReleaseRequested", "TicketOpened"}))
    use_case = MagicMock()
    use_case.execute = AsyncMock(
        side_effect=[RuntimeError("db down"), ProcessQuotaResult(QuotaOutcome.RESERVED, reservation_id=str(uuid.uuid4()))]
    )
    telemetry = QuotaTelemetry()
    consumer = QuotaConsumer("amqp://localhost/", "quota-service.q", validator, use_case, telemetry)
    monkeypatch.setattr(consumer, "sleep", AsyncMock())

    envelope = {
        "messageId": str(uuid.uuid4()),
        "correlationId": str(uuid.uuid4()),
        "type": "AudioReceived",
        "version": 1,
        "occurredAt": "2026-11-18T00:00:00Z",
        "payload": {"requestId": str(uuid.uuid4()), "tenantId": "acme", "audioKey": "audios/a.ogg"},
    }
    message = MagicMock()
    message.body = json.dumps(envelope).encode()
    message.headers = {}
    message.nack = AsyncMock()
    message.ack = AsyncMock()

    run(consumer.handle(message))
    assert use_case.execute.await_count == 2
    message.ack.assert_awaited_once()
    message.nack.assert_not_awaited()


def test_outbox_relay_publishes_persistent_mandatory_message():
    relay = OutboxRelay("amqp://localhost/", "events", MagicMock())
    exchange = MagicMock()
    exchange.publish = AsyncMock()

    envelope = {
        "messageId": str(uuid.uuid4()),
        "correlationId": str(uuid.uuid4()),
        "type": "CreditReserved",
        "version": 1,
        "occurredAt": "2026-11-18T00:00:00Z",
        "payload": {"requestId": str(uuid.uuid4()), "tenantId": "acme", "reservationId": str(uuid.uuid4())},
    }
    row = {
        "type": "CreditReserved",
        "envelope": json.dumps(envelope),
        "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    }

    run(relay._publish(exchange, row))
    exchange.publish.assert_awaited_once()
    published_msg = exchange.publish.call_args.args[0]
    kwargs = exchange.publish.call_args.kwargs
    assert published_msg.delivery_mode == DeliveryMode.PERSISTENT
    assert published_msg.content_type == "application/json"
    assert published_msg.message_id == envelope["messageId"]
    assert published_msg.correlation_id == envelope["correlationId"]
    assert published_msg.type == "CreditReserved"
    assert kwargs["routing_key"] == "CreditReserved"
    assert kwargs["mandatory"] is True


def test_validator_accepts_all_incoming_event_types():
    validator = ContractValidator(SCHEMAS, frozenset({"AudioReceived", "CreditReleaseRequested", "TicketOpened"}))
    req_id = str(uuid.uuid4())
    for event_type, payload in [
        ("AudioReceived", {"requestId": req_id, "tenantId": "acme", "audioKey": "audios/a.ogg"}),
        ("CreditReleaseRequested", {"requestId": req_id, "tenantId": "acme", "reason": "failed"}),
        ("TicketOpened", {"requestId": req_id, "tenantId": "acme", "ticketId": "t-1"}),
    ]:
        env = {
            "messageId": str(uuid.uuid4()),
            "correlationId": req_id,
            "type": event_type,
            "version": 1,
            "occurredAt": "2026-11-18T00:00:00Z",
            "payload": payload,
        }
        assert validator.validate(json.dumps(env))["type"] == event_type

    with pytest.raises(InvalidEnvelope):
        validator.validate(json.dumps({
            "messageId": str(uuid.uuid4()),
            "correlationId": req_id,
            "type": "UnknownEvent",
            "version": 1,
            "occurredAt": "2026-11-18T00:00:00Z",
            "payload": {},
        }))


def test_telemetry_records_and_observes_pending_outbox():
    telemetry = QuotaTelemetry()
    telemetry.record(QuotaOutcome.RESERVED, "acme")
    telemetry.record(QuotaOutcome.REJECTED, "acme")
    telemetry.record(QuotaOutcome.RELEASED, "acme")

    pool = MagicMock()
    pool.fetchval = AsyncMock(return_value=7)
    run(telemetry.refresh_outbox_pending(pool))
    observations = telemetry._observe_pending(None)
    assert observations[0].value == 7
