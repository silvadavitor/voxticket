from __future__ import annotations

import asyncio
import json
import os

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError


class AudioNotFound(Exception):
    """Áudio não existe (ex.: já movido para failed/). Não adianta tentar de novo."""


def transcript_key(request_id: str) -> str:
    return f"transcripts/{request_id}.json"


class Storage:
    def __init__(self, bucket: str) -> None:
        self.bucket = bucket
        endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
        cfg = Config(
            retries={"mode": "standard", "max_attempts": 3},
            connect_timeout=5,
            read_timeout=30,
            s3={"addressing_style": "path"} if endpoint else None,  # MiniStack
        )
        self.s3 = boto3.client("s3", endpoint_url=endpoint, region_name=os.environ.get("AWS_REGION"), config=cfg)

    async def read_audio(self, key: str) -> bytes:
        def _get() -> bytes:
            return self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read()

        try:
            return await asyncio.to_thread(_get)
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
                raise AudioNotFound(key) from exc
            raise

    async def put_transcript(self, key: str, document: dict) -> None:
        body = json.dumps(document, ensure_ascii=False).encode()
        await asyncio.to_thread(
            self.s3.put_object, Bucket=self.bucket, Key=key, Body=body, ContentType="application/json"
        )

    async def delete(self, key: str) -> None:
        await asyncio.to_thread(self.s3.delete_object, Bucket=self.bucket, Key=key)
