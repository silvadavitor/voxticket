"""Portas (interfaces) que a camada de aplicação exige da infraestrutura."""
from __future__ import annotations

from abc import ABC, abstractmethod
from types import TracebackType

from app.domain.events import IntegrationEvent
from app.domain.ticket import Ticket


class TicketRepository(ABC):
    @abstractmethod
    async def find_by_request_id(self, request_id: str) -> Ticket | None: ...

    @abstractmethod
    async def add(self, ticket: Ticket) -> Ticket:
        """Persiste o ticket; se já existir um para o ``request_id``, devolve o existente."""


class TicketQueries(ABC):
    """Leitura dos chamados para a API (GET /tickets). Não participa da transação de escrita."""

    @abstractmethod
    async def list(self, tenant_id: str | None, limit: int) -> list[Ticket]:
        """Chamados mais novos primeiro, opcionalmente só de um cliente."""

    @abstractmethod
    async def get(self, ticket_id: str) -> Ticket | None: ...


class ProcessedMessageRepository(ABC):
    @abstractmethod
    async def register(self, message_id: str) -> bool:
        """Registra a mensagem. Retorna ``False`` se ela já foi processada."""


class Outbox(ABC):
    @abstractmethod
    async def add(self, event: IntegrationEvent, traceparent: str | None) -> None: ...


class UnitOfWork(ABC):
    """Tudo dentro de um ``async with`` ocorre numa única transação."""

    tickets: TicketRepository
    processed_messages: ProcessedMessageRepository
    outbox: Outbox

    @abstractmethod
    async def __aenter__(self) -> "UnitOfWork": ...

    @abstractmethod
    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        """Commit se não houve exceção, senão rollback."""


class UnitOfWorkFactory(ABC):
    @abstractmethod
    def create(self) -> UnitOfWork: ...
