"""Cadastro de clientes e limite de créditos (contrato em contracts/openapi.yaml)."""
from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from typing import TypeVar

from fastapi import APIRouter, HTTPException, Path
from pydantic import BaseModel, Field

from app.application.ports import TenantAdmin
from app.domain.tenant import Tenant

logger = logging.getLogger(__name__)
T = TypeVar("T")

TENANT_ID = Path(..., min_length=1, max_length=255, pattern=r"^[A-Za-z0-9._-]+$")


class TenantLimit(BaseModel):
    quotaLimit: int = Field(..., ge=0, le=1_000_000)


def to_dto(tenant: Tenant) -> dict[str, str | int]:
    return {
        "tenantId": tenant.tenant_id,
        "quotaLimit": tenant.quota_limit,
        "used": tenant.used,
        "available": tenant.available,
    }


def build_tenants_router(admin: Callable[[], TenantAdmin]) -> APIRouter:
    router = APIRouter()

    async def _run(call: Callable[[TenantAdmin], Awaitable[T]]) -> T:
        try:
            return await call(admin())
        except Exception as exc:  # banco conectando ou fora: o processo segue vivo
            logger.warning("falha no cadastro de clientes: %s", exc)
            raise HTTPException(status_code=503, detail="banco indisponível") from exc

    @router.get("/tenants")
    async def list_tenants() -> list[dict[str, str | int]]:
        return [to_dto(t) for t in await _run(lambda a: a.list())]

    @router.get("/tenants/{tenant_id}")
    async def get_tenant(tenant_id: str = TENANT_ID) -> dict[str, str | int]:
        tenant = await _run(lambda a: a.get(tenant_id))
        if tenant is None:
            raise HTTPException(status_code=404, detail="cliente não cadastrado")
        return to_dto(tenant)

    @router.put("/tenants/{tenant_id}")
    async def set_limit(body: TenantLimit, tenant_id: str = TENANT_ID) -> dict[str, str | int]:
        tenant = await _run(lambda a: a.set_limit(tenant_id, body.quotaLimit))
        if tenant is None:
            raise HTTPException(status_code=409, detail="limite menor que os créditos já usados")
        logger.info("limite do cliente %s = %s", tenant_id, body.quotaLimit)
        return to_dto(tenant)

    return router
