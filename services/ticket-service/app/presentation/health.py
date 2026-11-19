from fastapi import APIRouter

from app.container import TicketServiceContainer


def build_health_router(container: TicketServiceContainer) -> APIRouter:
    router = APIRouter()

    @router.get("/health")
    async def health() -> dict[str, str]:
        # Sempre 200: o estado das dependências vai no corpo (R6).
        return {
            "status": "ok",
            "broker": "up" if container.broker_up else "down",
            "db": "up" if await container.database.is_healthy() else "down",
        }

    return router
