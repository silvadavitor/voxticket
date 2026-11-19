"""Erro de infraestrutura ≠ mensagem venenosa (CLAUDE.md 5.5).

- InvalidMessage      → nack(requeue) → conta tentativa → DLQ após x-delivery-limit.
- erro de infraestrutura (banco, S3, rede) → retry interno com backoff segurando a mensagem.
"""

from __future__ import annotations

import asyncio
import socket


class InvalidMessage(Exception):
    """Mensagem que nunca vai dar certo: JSON inválido, fora do schema, tipo desconhecido."""


class InfraUnavailable(Exception):
    """Erro de infraestrutura levantado explicitamente pelo código do serviço."""


_S3_RETRYABLE_CODES = {
    "Throttling",
    "ThrottlingException",
    "SlowDown",
    "RequestTimeout",
    "RequestTimeoutException",
    "ServiceUnavailable",
    "InternalError",
    "InternalFailure",
}


def is_infra_error(exc: BaseException) -> bool:
    # ConnectionError cobre recusado/resetado; gaierror = DNS (ex.: container do banco parado)
    if isinstance(exc, (InfraUnavailable, ConnectionError, TimeoutError, asyncio.TimeoutError, socket.gaierror)):
        return True

    try:
        import psycopg
        import psycopg_pool

        if isinstance(exc, (psycopg.OperationalError, psycopg.InterfaceError, psycopg_pool.PoolTimeout)):
            return True
    except ImportError:  # pragma: no cover
        pass

    try:
        from botocore.exceptions import (
            BotoCoreError,
            ClientError,
            ConnectionError as BotoConnectionError,
            EndpointConnectionError,
            HTTPClientError,
            NoCredentialsError,
        )

        if isinstance(exc, (EndpointConnectionError, BotoConnectionError, HTTPClientError)):
            return True
        if isinstance(exc, NoCredentialsError):
            return True  # credenciais da task role ainda não disponíveis
        if isinstance(exc, ClientError):
            meta = exc.response.get("ResponseMetadata", {})
            code = exc.response.get("Error", {}).get("Code", "")
            return meta.get("HTTPStatusCode", 0) >= 500 or code in _S3_RETRYABLE_CODES
        if isinstance(exc, BotoCoreError):
            return True
    except ImportError:  # pragma: no cover
        pass

    return False
