"""categorization-service: consome CategorizationRequested e publica AudioCategorized.

Sobe mesmo com banco ou broker fora (R6): as conexões são tentadas em background e o /health
mostra o estado de cada dependência.
"""

import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from . import logging_config
from .db import Database
from .handlers import HANDLERS
from .messaging import outbox
from .messaging.broker import Broker
from .messaging.consumer import consume_forever
from .settings import settings

logging_config.setup()
log = logging.getLogger(__name__)

db = Database()
broker = Broker()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    tasks = [
        asyncio.create_task(db.connect_forever(), name="db"),
        asyncio.create_task(broker.connect_forever(), name="broker"),
        asyncio.create_task(consume_forever(db, broker, HANDLERS), name="consumer"),
        asyncio.create_task(outbox.relay_forever(db, broker), name="outbox-relay"),
    ]
    log.info("%s iniciado (fila %s)", settings.service_name, settings.broker_queue)
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        await broker.close()
        await db.close()


app = FastAPI(title=settings.service_name, lifespan=lifespan)


@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok",  # o processo está vivo; dependências fora não derrubam o serviço (R6)
        "service": settings.service_name,
        "broker": "up" if broker.is_up else "down",
        "db": "up" if await db.is_up() else "down",
    }
