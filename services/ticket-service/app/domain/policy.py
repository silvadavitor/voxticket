"""Regras que decidem se um chamado pode ser aberto."""
from __future__ import annotations

from dataclasses import dataclass

from app.domain.exceptions import TicketRejectedError


@dataclass(frozen=True)
class TicketOpeningPolicy:
    """Valida a solicitação antes de abrir o chamado.

    ``allowed_categories`` vazio significa "qualquer categoria não vazia".
    """

    allowed_categories: frozenset[str] = frozenset()

    def ensure_can_open(self, tenant_id: str, category: str) -> None:
        if not tenant_id.strip():
            raise TicketRejectedError("tenantId vazio")
        normalized = category.strip()
        if not normalized:
            raise TicketRejectedError("categoria vazia")
        if self.allowed_categories and normalized.lower() not in self.allowed_categories:
            raise TicketRejectedError(f"categoria nao suportada: {normalized}")
