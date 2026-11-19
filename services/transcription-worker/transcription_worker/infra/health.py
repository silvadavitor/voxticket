"""GET /health → 200 {"status": "ok"|"degraded", "broker": "up|down", "db": "up|down"}.

Sempre 200 enquanto o processo vive: broker/banco fora deixam o serviço "degraded" mas ele
continua de pé e se recupera sozinho (R6). Quem lê o estado é a demo/monitoramento.
"""

from __future__ import annotations

import asyncio
import logging
import socket
from typing import Any, Awaitable, Callable

import uvicorn
from fastapi import FastAPI

log = logging.getLogger("transcription_worker.infra.health")


def create_app(
    service: str,
    broker_up: Callable[[], bool],
    db_ping: Callable[[], Awaitable[bool]],
    extra: Callable[[], dict[str, Any]] | None = None,
) -> FastAPI:
    app = FastAPI(title=service, docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/health")
    async def health() -> dict[str, Any]:
        broker = "up" if broker_up() else "down"
        db = "up" if await db_ping() else "down"
        body: dict[str, Any] = {
            "status": "ok" if broker == "up" and db == "up" else "degraded",
            "broker": broker,
            "db": db,
            "service": service,
            "hostname": socket.gethostname(),
        }
        if extra is not None:
            body.update(extra())
        return body

    return app


async def serve(app: FastAPI, port: int, stop: asyncio.Event) -> None:
    config = uvicorn.Config(app, host="0.0.0.0", port=port, log_config=None, access_log=False, lifespan="off")
    server = uvicorn.Server(config)
    server.install_signal_handlers = lambda: None  # type: ignore[method-assign]  # sinais são nossos
    task = asyncio.create_task(server.serve())
    await stop.wait()
    server.should_exit = True
    await task
