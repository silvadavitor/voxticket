"""Entidade de domínio Reservation (reserva de crédito)."""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum


class ReservationStatus(str, Enum):
    RESERVED = "RESERVED"
    CONSUMED = "CONSUMED"
    RELEASED = "RELEASED"


@dataclass(frozen=True)
class Reservation:
    """Reserva de crédito. Única por ``request_id``."""

    request_id: str
    tenant_id: str
    reservation_id: str
    status: ReservationStatus = ReservationStatus.RESERVED
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    @classmethod
    def reserve(cls, request_id: str, tenant_id: str) -> "Reservation":
        return cls(
            request_id=request_id,
            tenant_id=tenant_id,
            reservation_id=str(uuid.uuid4()),
        )
