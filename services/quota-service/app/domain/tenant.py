"""Cliente (tenant) com a cota de créditos."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Tenant:
    tenant_id: str
    quota_limit: int
    used: int

    @property
    def available(self) -> int:
        return max(self.quota_limit - self.used, 0)
