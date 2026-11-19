from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.container import TicketServiceContainer
from app.infrastructure.config.settings import Settings
from app.infrastructure.observability.logging import configure_logging
from app.presentation.health import build_health_router
from app.presentation.tickets import build_tickets_router

settings = Settings.from_env()
configure_logging(settings.service_name)
container = TicketServiceContainer(settings)


@asynccontextmanager
async def lifespan(_: FastAPI):
    await container.start()
    try:
        yield
    finally:
        await container.stop()


app = FastAPI(title="ticket-service", lifespan=lifespan)
app.include_router(build_health_router(container))
app.include_router(build_tickets_router(container.ticket_queries))
