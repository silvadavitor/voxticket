import asyncio
import json
import uuid
from dataclasses import replace
from pathlib import Path

import pytest

from app.application.ports import (
    Outbox,
    ProcessedMessageRepository,
    QuotaRepository,
    ReservationRepository,
    UnitOfWork,
    UnitOfWorkFactory,
)
from app.application.process_quota import ProcessQuotaCommand, ProcessQuotaUseCase, QuotaOutcome
from app.domain.reservation import ReservationStatus
from app.infrastructure.messaging.contract_validator import ContractValidator, InvalidEnvelope

SCHEMAS = Path(__file__).resolve().parents[1] / "contracts" / "schemas"


class InMemoryStore:
    def __init__(self, initial_quotas: dict[str, tuple[int, int]] | None = None):
        # tenant_id -> [quota_limit, used]
        self.quotas = {k: list(v) for k, v in (initial_quotas or {}).items()}
        self.reservations, self.processed, self.outbox = {}, set(), []


class FakeQuotas(QuotaRepository):
    def __init__(self, store): self.s = store

    async def try_reserve(self, tenant_id):
        quota = self.s.quotas.get(tenant_id)
        if quota is None or quota[1] >= quota[0]:
            return False
        quota[1] += 1
        return True

    async def ensure_tenant_exists(self, tenant_id):
        self.s.quotas.setdefault(tenant_id, [0, 0])

    async def release(self, tenant_id):
        quota = self.s.quotas.get(tenant_id)
        if quota is not None and quota[1] > 0:
            quota[1] -= 1


class FakeReservations(ReservationRepository):
    def __init__(self, store): self.s = store
    async def find_by_request_id(self, request_id): return self.s.reservations.get(request_id)
    async def add(self, reservation): return self.s.reservations.setdefault(reservation.request_id, reservation)

    async def mark_released(self, request_id, tenant_id):
        res = self.s.reservations.get(request_id)
        if res is None or res.tenant_id != tenant_id or res.status is not ReservationStatus.RESERVED:
            return False
        self.s.reservations[request_id] = replace(res, status=ReservationStatus.RELEASED)
        return True

    async def mark_consumed(self, request_id, tenant_id):
        res = self.s.reservations.get(request_id)
        if res is None or res.tenant_id != tenant_id or res.status is not ReservationStatus.RESERVED:
            return False
        self.s.reservations[request_id] = replace(res, status=ReservationStatus.CONSUMED)
        return True


class FakeProcessed(ProcessedMessageRepository):
    def __init__(self, store): self.s = store

    async def register(self, message_id):
        if message_id in self.s.processed:
            return False
        self.s.processed.add(message_id)
        return True


class FakeOutbox(Outbox):
    def __init__(self, store): self.s = store
    async def add(self, event, traceparent): self.s.outbox.append(event)


class FakeUoW(UnitOfWork):
    def __init__(self, store):
        self.quotas = FakeQuotas(store)
        self.reservations = FakeReservations(store)
        self.processed_messages = FakeProcessed(store)
        self.outbox = FakeOutbox(store)

    async def __aenter__(self): return self
    async def __aexit__(self, *args): return None


class FakeFactory(UnitOfWorkFactory):
    def __init__(self, initial_quotas=None): self.store = InMemoryStore(initial_quotas)
    def create(self): return FakeUoW(self.store)


def command(event_type="AudioReceived", request_id=None, tenant_id="acme", message_id=None):
    return ProcessQuotaCommand(
        message_id=message_id or str(uuid.uuid4()),
        event_type=event_type,
        request_id=request_id or str(uuid.uuid4()),
        tenant_id=tenant_id,
    )


def run(coro):
    return asyncio.run(coro)


def test_reserves_credit_and_writes_credit_reserved():
    factory = FakeFactory({"acme": (2, 0)})
    result = run(ProcessQuotaUseCase(factory).execute(command()))
    assert result.outcome is QuotaOutcome.RESERVED
    assert factory.store.quotas["acme"] == [2, 1]
    assert factory.store.outbox[0].type == "CreditReserved"
    assert factory.store.outbox[0].payload["reservationId"] == result.reservation_id


def test_rejects_when_quota_unavailable():
    factory = FakeFactory({"acme": (1, 1)})
    result = run(ProcessQuotaUseCase(factory).execute(command()))
    assert result.outcome is QuotaOutcome.REJECTED
    assert factory.store.outbox[0].type == "CreditRejected"
    assert not factory.store.reservations


def test_same_message_is_ignored():
    factory = FakeFactory({"acme": (2, 0)})
    use_case = ProcessQuotaUseCase(factory)
    cmd = command()
    run(use_case.execute(cmd))
    assert run(use_case.execute(cmd)).outcome is QuotaOutcome.DUPLICATE_MESSAGE
    assert factory.store.quotas["acme"] == [2, 1]
    assert len(factory.store.outbox) == 1


def test_same_request_id_keeps_single_reservation():
    factory = FakeFactory({"acme": (2, 0)})
    use_case = ProcessQuotaUseCase(factory)
    request_id = str(uuid.uuid4())
    first = run(use_case.execute(command(request_id=request_id)))
    second = run(use_case.execute(command(request_id=request_id)))
    assert second.outcome is QuotaOutcome.ALREADY_RESERVED
    assert first.reservation_id == second.reservation_id
    assert factory.store.quotas["acme"] == [2, 1]


def test_release_returns_credit_only_once():
    factory = FakeFactory({"acme": (1, 0)})
    use_case = ProcessQuotaUseCase(factory)
    request_id = str(uuid.uuid4())
    run(use_case.execute(command("AudioReceived", request_id=request_id)))
    first_release = run(use_case.execute(command("CreditReleaseRequested", request_id=request_id)))
    second_release = run(use_case.execute(command("CreditReleaseRequested", request_id=request_id)))
    assert first_release.outcome is QuotaOutcome.RELEASED
    assert second_release.outcome is QuotaOutcome.RELEASE_IGNORED
    assert factory.store.quotas["acme"] == [1, 0]


def test_ticket_opened_consumes_reservation_and_blocks_release():
    factory = FakeFactory({"acme": (1, 0)})
    use_case = ProcessQuotaUseCase(factory)
    request_id = str(uuid.uuid4())
    run(use_case.execute(command("AudioReceived", request_id=request_id)))
    consumed = run(use_case.execute(command("TicketOpened", request_id=request_id)))
    release_after = run(use_case.execute(command("CreditReleaseRequested", request_id=request_id)))
    assert consumed.outcome is QuotaOutcome.CONSUMED
    assert release_after.outcome is QuotaOutcome.RELEASE_IGNORED
    assert factory.store.quotas["acme"] == [1, 1]


def test_outgoing_envelopes_match_contracts():
    validator = ContractValidator(SCHEMAS, frozenset({"CreditReserved", "CreditRejected"}))
    factory = FakeFactory({"acme": (1, 0)})
    use_case = ProcessQuotaUseCase(factory)
    run(use_case.execute(command()))
    run(use_case.execute(command()))
    for event in factory.store.outbox:
        validator.validate(json.dumps(event.to_envelope()))


def test_validator_accepts_and_rejects_incoming_contracts():
    validator = ContractValidator(SCHEMAS, frozenset({"AudioReceived", "CreditReleaseRequested", "TicketOpened"}))
    valid = {
        "messageId": str(uuid.uuid4()),
        "correlationId": str(uuid.uuid4()),
        "type": "AudioReceived",
        "version": 1,
        "occurredAt": "2026-11-18T00:00:00Z",
        "payload": {"requestId": str(uuid.uuid4()), "tenantId": "acme", "audioKey": "audios/a.ogg"},
    }
    assert validator.validate(json.dumps(valid))["type"] == "AudioReceived"
    with pytest.raises(InvalidEnvelope):
        validator.validate(b'{"type":"AudioReceived"}')
    with pytest.raises(InvalidEnvelope):
        validator.validate(b"not json")
