"""Regras de negócio por tipo de evento. Cada handler roda DENTRO da transação do consumidor (R1)."""

import asyncio
import logging
import uuid

import asyncpg
from botocore.exceptions import ClientError

from . import aws
from .classifier import classify
from .messaging import outbox
from .messaging.envelope import Envelope, InvalidMessage

log = logging.getLogger(__name__)


async def on_categorization_requested(conn: asyncpg.Connection, env: Envelope) -> None:
    """CategorizationRequested → lê a transcrição no S3 → classifica → AudioCategorized.

    Formato da transcrição (transcripts/{requestId}.json), a combinar com o transcription-worker:
        {"requestId": "...", "text": "..."}
    """
    request_id = env.payload["requestId"]
    key = env.payload["transcriptKey"]

    try:
        transcript = await asyncio.to_thread(aws.read_json_object, key)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            raise InvalidMessage(f"transcrição {key} não existe") from exc
        raise  # erro de infraestrutura → retry no consumidor

    text = transcript.get("text")
    if not isinstance(text, str):
        raise InvalidMessage(f"transcrição {key} sem campo 'text'")

    result = classify(text)

    # efeito idempotente por request_id (mesmo se vier outra mensagem com messageId diferente)
    inserted = await conn.execute(
        """INSERT INTO categorizations (request_id, category, priority, confidence)
           VALUES ($1, $2, $3, $4) ON CONFLICT (request_id) DO NOTHING""",
        uuid.UUID(request_id),
        result.category,
        result.priority,
        result.confidence,
    )
    if inserted.endswith(" 0"):
        log.info("pedido já categorizado, nada a publicar", extra={"correlationId": env.correlation_id})
        return

    await outbox.enqueue(
        conn,
        "AudioCategorized",
        env.correlation_id,
        {
            "requestId": request_id,
            "category": result.category,
            "priority": result.priority,
            "confidence": result.confidence,
        },
    )
    log.info(
        "categorizado: %s / %s (%.2f)", result.category, result.priority, result.confidence,
        extra={"correlationId": env.correlation_id},
    )


HANDLERS = {
    "CategorizationRequested": on_categorization_requested,
}
