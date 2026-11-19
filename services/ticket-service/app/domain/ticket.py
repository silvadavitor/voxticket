"""Entidade de domínio Ticket (chamado)."""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum


class TicketStatus(str, Enum):
    OPEN = "OPEN"


@dataclass(frozen=True)
class Ticket:
    """Chamado aberto. Único por ``request_id``."""

    ticket_id: str
    request_id: str
    tenant_id: str
    category: str
    priority: str | None = None
    transcript_key: str | None = None
    status: TicketStatus = TicketStatus.OPEN
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    @classmethod
    def open(
        cls,
        request_id: str,
        tenant_id: str,
        category: str,
        priority: str | None = None,
        transcript_key: str | None = None,
    ) -> "Ticket":
        return cls(
            ticket_id=str(uuid.uuid4()),
            request_id=request_id,
            tenant_id=tenant_id,
            category=category.strip(),
            priority=priority,
            transcript_key=transcript_key,
        )
