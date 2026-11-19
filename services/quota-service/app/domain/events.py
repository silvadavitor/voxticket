"""Eventos de integração publicados pelo quota-service (envelope dos contratos)."""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from app.domain.reservation import Reservation


@dataclass(frozen=True)
class IntegrationEvent:
    type: str
    correlation_id: str
    payload: dict[str, Any]
    version: int = 1
    message_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    occurred_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def to_envelope(self) -> dict[str, Any]:
        return {
            "messageId": self.message_id,
            "correlationId": self.correlation_id,
            "type": self.type,
            "version": self.version,
            "occurredAt": self.occurred_at.isoformat().replace("+00:00", "Z"),
            "payload": self.payload,
        }


class QuotaEvents:
    """Fábrica dos eventos publicados."""

    @staticmethod
    def reserved(reservation: Reservation) -> IntegrationEvent:
        return IntegrationEvent(
            "CreditReserved",
            reservation.request_id,
            {
                "requestId": reservation.request_id,
                "tenantId": reservation.tenant_id,
                "reservationId": reservation.reservation_id,
            },
        )

    @staticmethod
    def rejected(request_id: str, tenant_id: str, reason: str) -> IntegrationEvent:
        return IntegrationEvent(
            "CreditRejected",
            request_id,
            {"requestId": request_id, "tenantId": tenant_id, "reason": reason},
        )
