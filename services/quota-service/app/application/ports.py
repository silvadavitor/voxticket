"""Portas (interfaces) que a camada de aplicação exige da infraestrutura."""
from __future__ import annotations

from abc import ABC, abstractmethod
from types import TracebackType

from app.domain.events import IntegrationEvent
from app.domain.reservation import Reservation
from app.domain.tenant import Tenant


class TenantAdmin(ABC):
    """Cadastro dos clientes e do limite de créditos (API /tenants). Fora da saga."""

    @abstractmethod
    async def list(self) -> list[Tenant]: ...

    @abstractmethod
    async def get(self, tenant_id: str) -> Tenant | None: ...

    @abstractmethod
    async def set_limit(self, tenant_id: str, quota_limit: int) -> Tenant | None:
        """Cria o cliente ou muda o limite. ``None`` se o limite ficaria abaixo do já usado."""


class QuotaRepository(ABC):
    @abstractmethod
    async def try_reserve(self, tenant_id: str) -> bool:
        """Reserva 1 crédito atomicamente (``used < quota_limit``). Retorna ``False`` se indisponível."""

    @abstractmethod
    async def ensure_tenant_exists(self, tenant_id: str) -> None:
        """Garante o registro do tenant com limite zero quando ainda não cadastrado."""

    @abstractmethod
    async def release(self, tenant_id: str) -> None:
        """Devolve 1 crédito reservado (``used > 0``)."""


class ReservationRepository(ABC):
    @abstractmethod
    async def find_by_request_id(self, request_id: str) -> Reservation | None: ...

    @abstractmethod
    async def add(self, reservation: Reservation) -> Reservation:
        """Persiste a reserva; se já existir uma para o ``request_id``, devolve a existente."""

    @abstractmethod
    async def mark_released(self, request_id: str, tenant_id: str) -> bool:
        """Marca como ``RELEASED`` apenas se estiver ``RESERVED``. Retorna ``False`` caso contrário."""

    @abstractmethod
    async def mark_consumed(self, request_id: str, tenant_id: str) -> bool:
        """Marca como ``CONSUMED`` apenas se estiver ``RESERVED``. Retorna ``False`` caso contrário."""


class ProcessedMessageRepository(ABC):
    @abstractmethod
    async def register(self, message_id: str) -> bool:
        """Registra a mensagem. Retorna ``False`` se ela já foi processada."""


class Outbox(ABC):
    @abstractmethod
    async def add(self, event: IntegrationEvent, traceparent: str | None) -> None: ...


class UnitOfWork(ABC):
    """Tudo dentro de um ``async with`` ocorre numa única transação."""

    quotas: QuotaRepository
    reservations: ReservationRepository
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
