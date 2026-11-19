from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.container import QuotaServiceContainer
from app.infrastructure.config.settings import Settings
from app.infrastructure.observability.logging import configure_logging
from app.presentation.health import build_health_router
from app.presentation.tenants import build_tenants_router

settings = Settings.from_env()
configure_logging(settings.service_name)
container = QuotaServiceContainer(settings)


@asynccontextmanager
async def lifespan(_: FastAPI):
    await container.start()
    try:
        yield
    finally:
        await container.stop()


app = FastAPI(title="quota-service", lifespan=lifespan)
app.include_router(build_health_router(container))
app.include_router(build_tenants_router(container.tenant_admin))
