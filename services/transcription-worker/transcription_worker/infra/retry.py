"""Backoff exponencial com jitter e retry "para sempre" de erros de infraestrutura."""

from __future__ import annotations

import asyncio
import logging
import random
from typing import Awaitable, Callable, TypeVar

from .errors import is_infra_error

T = TypeVar("T")
log = logging.getLogger("transcription_worker.infra.retry")


class Backoff:
    def __init__(self, base: float = 0.5, cap: float = 30.0) -> None:
        self.base = base
        self.cap = cap
        self.attempt = 0

    def next_delay(self) -> float:
        delay = min(self.cap, self.base * (2**self.attempt))
        self.attempt += 1
        return delay * random.uniform(0.5, 1.0)

    def reset(self) -> None:
        self.attempt = 0

    async def sleep(self) -> float:
        delay = self.next_delay()
        await asyncio.sleep(delay)
        return delay


async def retry_infra(
    fn: Callable[[], Awaitable[T]],
    what: str,
    *,
    should_continue: Callable[[], bool] = lambda: True,
    cap: float = 30.0,
) -> T:
    """Executa `fn` repetindo enquanto o erro for de infraestrutura (banco/S3/rede fora).

    Outros erros sobem na hora. Usado para segurar a mensagem em vez de mandá-la para a DLQ (5.5).
    `should_continue` permite abortar (ex.: o canal do broker caiu e a mensagem será reentregue).
    """
    backoff = Backoff(cap=cap)
    while True:
        try:
            return await fn()
        except Exception as exc:
            if not is_infra_error(exc) or not should_continue():
                raise
            delay = backoff.next_delay()
            log.warning(
                "infra error on %s, retrying in %.1fs: %s",
                what,
                delay,
                f"{type(exc).__name__}: {exc}",
                extra={"retry_attempt": backoff.attempt},
            )
            await asyncio.sleep(delay)
