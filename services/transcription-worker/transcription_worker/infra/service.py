from __future__ import annotations

import asyncio
import logging
import signal
import socket
from pathlib import Path
from typing import Any, Callable

from . import telemetry
from .broker import Broker, build_broker_url
from .config import env_int, env_req, env_str, normalize_aws_env
from .consumer import Consumer, Handler
from .db import Database
from .envelope import SchemaValidator
from .health import create_app, serve
from .logs import setup_logging
from .outbox import OutboxRelay
from .secrets import load_db_credentials

log = logging.getLogger("transcription_worker.infra.service")


class ServiceRuntime:
    def __init__(self) -> None:
        self.service = env_req("SERVICE_NAME")
        setup_logging(self.service, env_str("LOG_LEVEL", "INFO") or "INFO")
        normalize_aws_env()
        telemetry.setup_telemetry(self.service)

        self.stop = asyncio.Event()
        self.validator = SchemaValidator(env_str("SCHEMAS_DIR", "/app/contracts/schemas") or "")
        self.queue = env_req("BROKER_QUEUE")
        self.prefetch = env_int("BROKER_PREFETCH", 1)
        self.http_port = env_int("HTTP_PORT", 8080)
        self.db_host = env_req("DB_HOST")
        self.db_port = env_int("DB_PORT", 5432)
        self.broker = Broker(
            build_broker_url(env_req("BROKER_URL"), env_str("BROKER_USERNAME"), env_str("BROKER_PASSWORD")),
            env_req("BROKER_EXCHANGE"),
            self.service,
        )
        self.db: Database | None = None
        self.relay: OutboxRelay | None = None
        self.health_extra: Callable[[], dict[str, Any]] | None = None
        self.hostname = socket.gethostname()

    async def _db_ping(self) -> bool:
        return await self.db.ping() if self.db is not None else False

    def _install_signals(self) -> None:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                loop.add_signal_handler(sig, self.stop.set)
            except (NotImplementedError, RuntimeError):  # Windows
                signal.signal(sig, lambda *_: loop.call_soon_threadsafe(self.stop.set))

    async def run(self, migrations_dir: str | Path, build_handlers: Callable[["ServiceRuntime"], dict[str, Handler]]) -> None:
        self._install_signals()
        app = create_app(self.service, lambda: self.broker.up, self._db_ping, lambda: self._extra())
        tasks = [asyncio.create_task(serve(app, self.http_port, self.stop), name="health")]
        log.info("starting", extra={"queue": self.queue, "http_port": self.http_port})
        # broker conecta em paralelo com o banco (health mostra cada um de forma independente)
        broker_ready = asyncio.create_task(self.broker.connect_forever(self.stop), name="broker-connect")

        creds = await load_db_credentials(self.stop)
        self.db = Database(self.db_host, self.db_port, creds)
        await self.db.open()
        await self.db.migrate(migrations_dir)

        self.relay = OutboxRelay(self.db, self.broker, poll_ms=env_int("OUTBOX_POLL_MS", 500))
        telemetry.observable_gauge(
            "voxticket.outbox.pending", "linhas do outbox ainda não publicadas", lambda: self.relay.pending if self.relay else None
        )
        consumer = Consumer(self.validator, build_handlers(self))

        await broker_ready
        if not self.stop.is_set():
            tasks.append(asyncio.create_task(self.relay.run(self.stop), name="outbox-relay"))
            tasks.append(asyncio.create_task(self.relay.run_pending_gauge(self.stop), name="outbox-gauge"))
            await self.broker.consume(self.queue, consumer.on_message, self.prefetch)
            log.info("ready")

        await self.stop.wait()
        log.info("shutting down")
        await self.broker.close()
        await asyncio.gather(*tasks, return_exceptions=True)
        await self.db.close()
        telemetry.shutdown_telemetry()

    def _extra(self) -> dict[str, Any]:
        data: dict[str, Any] = {}
        if self.relay is not None and self.relay.pending is not None:
            data["outboxPending"] = self.relay.pending
        if self.health_extra is not None:
            data.update(self.health_extra())
        return data
