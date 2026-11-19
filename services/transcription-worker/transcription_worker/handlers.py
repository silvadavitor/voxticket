"""TranscriptionRequested e TranscriptDiscardRequested.

Idempotência: processed_messages (mesmo messageId) + transcriptions.request_id como PK (mesmo pedido).
A transcrição é lenta, então fica FORA de transação; o efeito é gravado numa transação curta no fim.
"""

from __future__ import annotations

import logging

from .infra import telemetry
from .infra.db import Database, already_processed, mark_processed
from .infra.envelope import Envelope, SchemaValidator, new_envelope, utc_now_iso
from .infra.outbox import enqueue
from .infra.retry import retry_infra

from .storage import AudioNotFound, Storage, transcript_key
from .transcriber import Result, Transcriber

log = logging.getLogger("transcription_worker.handlers")


class TranscriptionHandlers:
    def __init__(
        self, db: Database, storage: Storage, transcriber: Transcriber, validator: SchemaValidator, hostname: str
    ) -> None:
        self.db = db
        self.storage = storage
        self.transcriber = transcriber
        self.validator = validator
        self.hostname = hostname
        self.processed = telemetry.meter().create_counter("voxticket.transcription.processed")

    def as_dict(self) -> dict:
        return {
            "TranscriptionRequested": self.on_transcription_requested,
            "TranscriptDiscardRequested": self.on_discard_requested,
        }

    async def on_transcription_requested(self, env: Envelope) -> None:
        p = env.payload
        request_id, tenant_id, audio_key = p["requestId"], p["tenantId"], p["audioKey"]

        async with self.db.pool.connection() as conn:
            if await already_processed(conn, env.message_id):
                log.info("duplicate, skipped")
                return
            cur = await conn.execute("SELECT 1 FROM transcriptions WHERE request_id = %s", (request_id,))
            done = await cur.fetchone() is not None
        if done:
            async with self.db.pool.connection() as conn, conn.transaction():
                await mark_processed(conn, env.message_id)
            log.info("request already transcribed, skipped")
            return

        log.info("processing %s", request_id)
        try:
            audio = await self.storage.read_audio(audio_key)  # S3 fora, o Consumer repete com backoff
        except AudioNotFound:
            await self._save(env, "FAILED", Result(None, None, 1, 0, reason="AUDIO_NOT_FOUND"))
            return

        result = await self.transcriber.transcribe(audio)
        if result.text is None:
            await self._save(env, "FAILED", result)
            return

        key = transcript_key(request_id)
        document = {
            "requestId": request_id,
            "tenantId": tenant_id,
            "text": result.text,
            "language": result.language,
            "processedBy": self.hostname,
            "attempts": result.attempts,
            "createdAt": utc_now_iso(),
        }
        # resultado já pronto: erro de infra daqui em diante é repetido aqui, sem transcrever de novo
        await retry_infra(lambda: self.storage.put_transcript(key, document), "put transcript")
        if await self._save(env, "TRANSCRIBED", result, key):
            self.processed.add(1, {"host": self.hostname})

    async def _save(self, env: Envelope, status: str, result: Result, key: str | None = None) -> bool:
        """processed_messages + transcriptions + outbox numa transação. False ⇒ duplicada."""
        p = env.payload
        if status == "TRANSCRIBED":
            event = new_envelope(
                "AudioTranscribed",
                env.correlation_id,
                {
                    "requestId": p["requestId"],
                    "tenantId": p["tenantId"],
                    "transcriptKey": key,
                    "processedBy": self.hostname,
                    "durationMs": result.duration_ms,
                },
            )
        else:
            event = new_envelope(
                "TranscriptionFailed",
                env.correlation_id,
                {"requestId": p["requestId"], "tenantId": p["tenantId"], "attempts": result.attempts, "reason": result.reason},
            )

        async def _tx() -> bool:
            async with self.db.pool.connection() as conn, conn.transaction():
                if not await mark_processed(conn, env.message_id):
                    return False
                cur = await conn.execute(
                    "INSERT INTO transcriptions (request_id, tenant_id, status, transcript_key, attempts,"
                    " failure_reason, processed_by, duration_ms) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"
                    " ON CONFLICT (request_id) DO NOTHING",
                    (p["requestId"], p["tenantId"], status, key, result.attempts, result.reason,
                     self.hostname, result.duration_ms),
                )
                if cur.rowcount == 0:
                    return False
                await enqueue(conn, event, self.validator)
                return True

        saved = await retry_infra(_tx, "save transcription")
        log.info("%s %s", status.lower(), p["requestId"], extra={"attempts": result.attempts, "saved": saved})
        return saved

    async def on_discard_requested(self, env: Envelope) -> None:
        """F7: resultado chegou depois do timeout. Apaga do S3 e marca DISCARDED."""
        request_id = env.payload["requestId"]
        key = transcript_key(request_id)  # chave determinística: não confiamos na que vem na mensagem

        async with self.db.pool.connection() as conn:
            if await already_processed(conn, env.message_id):
                log.info("duplicate, skipped")
                return
        await self.storage.delete(key)

        async with self.db.pool.connection() as conn, conn.transaction():
            if not await mark_processed(conn, env.message_id):
                return
            # upsert: se o descarte chegar antes do resultado, a linha DISCARDED impede transcrever depois
            await conn.execute(
                "INSERT INTO transcriptions (request_id, status, transcript_key, processed_by)"
                " VALUES (%s, 'DISCARDED', %s, %s)"
                " ON CONFLICT (request_id) DO UPDATE SET status = 'DISCARDED', updated_at = now()",
                (request_id, key, self.hostname),
            )
        log.info("discarded %s", request_id)
