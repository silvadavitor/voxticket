import asyncio
import json
import uuid
from pathlib import Path

import pytest

from app.application.open_ticket import OpenTicketCommand, OpenTicketOutcome, OpenTicketUseCase
from app.application.ports import Outbox, ProcessedMessageRepository, TicketRepository, UnitOfWork, UnitOfWorkFactory
from app.domain.policy import TicketOpeningPolicy
from app.infrastructure.messaging.contract_validator import ContractValidator, InvalidEnvelope

SCHEMAS = Path(__file__).resolve().parents[1] / "contracts" / "schemas"


class InMemoryStore:
    def __init__(self):
        self.tickets, self.processed, self.outbox = {}, set(), []


class FakeTickets(TicketRepository):
    def __init__(self, store): self.s = store
    async def find_by_request_id(self, request_id): return self.s.tickets.get(request_id)
    async def add(self, ticket): return self.s.tickets.setdefault(ticket.request_id, ticket)


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
        self.tickets, self.processed_messages, self.outbox = FakeTickets(store), FakeProcessed(store), FakeOutbox(store)
    async def __aenter__(self): return self
    async def __aexit__(self, *args): return None


class FakeFactory(UnitOfWorkFactory):
    def __init__(self): self.store = InMemoryStore()
    def create(self): return FakeUoW(self.store)


def command(request_id=None, category="suporte", message_id=None):
    return OpenTicketCommand(
        message_id=message_id or str(uuid.uuid4()),
        request_id=request_id or str(uuid.uuid4()),
        tenant_id="acme",
        category=category,
    )


def run(coro):
    return asyncio.run(coro)


def test_opens_ticket_and_writes_ticket_opened():
    factory = FakeFactory()
    result = run(OpenTicketUseCase(factory, TicketOpeningPolicy()).execute(command()))
    assert result.outcome is OpenTicketOutcome.OPENED
    assert factory.store.outbox[0].type == "TicketOpened"
    assert factory.store.outbox[0].payload["ticketId"] == result.ticket_id


def test_same_message_is_ignored():
    factory = FakeFactory()
    use_case = OpenTicketUseCase(factory, TicketOpeningPolicy())
    cmd = command()
    run(use_case.execute(cmd))
    assert run(use_case.execute(cmd)).outcome is OpenTicketOutcome.DUPLICATE_MESSAGE
    assert len(factory.store.outbox) == 1


def test_same_request_id_keeps_single_ticket():
    factory = FakeFactory()
    use_case = OpenTicketUseCase(factory, TicketOpeningPolicy())
    request_id = str(uuid.uuid4())
    first = run(use_case.execute(command(request_id)))
    second = run(use_case.execute(command(request_id)))
    assert second.outcome is OpenTicketOutcome.ALREADY_OPEN
    assert first.ticket_id == second.ticket_id
    assert len(factory.store.tickets) == 1


@pytest.mark.parametrize("category, allowed", [("  ", frozenset()), ("vendas", frozenset({"suporte"}))])
def test_rejects_invalid_category(category, allowed):
    factory = FakeFactory()
    result = run(OpenTicketUseCase(factory, TicketOpeningPolicy(allowed)).execute(command(category=category)))
    assert result.outcome is OpenTicketOutcome.REJECTED
    assert factory.store.outbox[0].type == "TicketRejected"
    assert not factory.store.tickets


def test_outgoing_envelopes_match_contracts():
    validator = ContractValidator(SCHEMAS, frozenset({"TicketOpened", "TicketRejected"}))
    factory = FakeFactory()
    use_case = OpenTicketUseCase(factory, TicketOpeningPolicy())
    run(use_case.execute(command()))
    run(use_case.execute(command(category="")))
    for event in factory.store.outbox:
        validator.validate(json.dumps(event.to_envelope()))


def test_validator_rejects_bad_payload():
    validator = ContractValidator(SCHEMAS, frozenset({"TicketRequested"}))
    with pytest.raises(InvalidEnvelope):
        validator.validate(b'{"type":"TicketRequested"}')
    with pytest.raises(InvalidEnvelope):
        validator.validate(b"not json")
