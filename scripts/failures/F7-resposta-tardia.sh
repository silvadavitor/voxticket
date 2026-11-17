#!/usr/bin/env bash
# F7 — Latência (20 s) maior que o timeout da saga (10 s): EXPIRED, crédito liberado 1x, transcrição descartada.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f7
set_quota "$TENANT" 5
recreate transcription-worker TRANSCRIBE_LATENCY_MS_MIN=20000 TRANSCRIBE_LATENCY_MS_MAX=20000 TRANSCRIBE_FAILURE_RATE=0
recreate request-service SAGA_TIMEOUT_MS=10000
ID=$(post_audio "$TENANT"); log "requestId=$ID"
sleep 30
status "$ID"
q quota "SELECT request_id, status FROM reservations WHERE request_id='$ID';"
q quota "SELECT used FROM tenant_quota WHERE tenant_id='$TENANT';"
q transcription "SELECT request_id, status FROM transcriptions WHERE request_id='$ID';"
q ticket "SELECT count(*) AS tickets FROM tickets WHERE request_id='$ID';"
log "linha do tempo"; docker compose --profile apps logs --no-log-prefix | grep "$ID" | sort
recreate transcription-worker; recreate request-service
