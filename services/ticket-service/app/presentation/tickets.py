"""API de leitura dos chamados (contrato em contracts/openapi.yaml)."""
from __future__ import annotations

import logging
from collections.abc import Callable

from fastapi import APIRouter, HTTPException, Query

from app.application.ports import TicketQueries
from app.domain.ticket import Ticket

logger = logging.getLogger(__name__)


def to_dto(ticket: Ticket) -> dict[str, str | None]:
    return {
        "ticketId": ticket.ticket_id,
        "requestId": ticket.request_id,
        "tenantId": ticket.tenant_id,
        "category": ticket.category,
        "priority": ticket.priority,
        "createdAt": ticket.created_at.isoformat(),
    }


def build_tickets_router(queries: Callable[[], TicketQueries]) -> APIRouter:
    router = APIRouter()

    def _queries() -> TicketQueries:
        try:
            return queries()
        except RuntimeError as exc:  # banco ainda conectando
            raise HTTPException(status_code=503, detail="banco indisponível") from exc

    @router.get("/tickets")
    async def list_tickets(
        tenant_id: str | None = Query(None, alias="tenantId"),
        limit: int = Query(50, ge=1, le=200),
    ) -> list[dict[str, str | None]]:
        try:
            tickets = await _queries().list(tenant_id, limit)
        except HTTPException:
            raise
        except Exception as exc:
            logger.warning("falha ao listar chamados: %s", exc)
            raise HTTPException(status_code=503, detail="banco indisponível") from exc
        return [to_dto(t) for t in tickets]

    @router.get("/tickets/{ticket_id}")
    async def get_ticket(ticket_id: str) -> dict[str, str | None]:
        ticket = await _queries().get(ticket_id)
        if ticket is None:
            raise HTTPException(status_code=404, detail="chamado não encontrado")
        return to_dto(ticket)

    return router
