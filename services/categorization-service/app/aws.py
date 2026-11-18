"""Clientes AWS. Com AWS_ENDPOINT_URL apontam para o MiniStack; sem ele, para a AWS real."""

import json
from functools import lru_cache

import boto3
from botocore.config import Config

from .settings import settings


@lru_cache
def _client(service: str):
    config = Config(retries={"max_attempts": 3, "mode": "standard"}, s3={"addressing_style": "path"})
    return boto3.client(service, region_name=settings.aws_region, endpoint_url=settings.aws_endpoint_url, config=config)


def read_secret(secret_id: str) -> dict:
    raw = _client("secretsmanager").get_secret_value(SecretId=secret_id)["SecretString"]
    return json.loads(raw)


def read_json_object(key: str) -> dict:
    body = _client("s3").get_object(Bucket=settings.s3_bucket, Key=key)["Body"].read()
    return json.loads(body)
