#!/usr/bin/env bash
# F1 — Compensação: dependência com 100% de falha.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f1
set_quota "$TENANT" 5
log "worker com TRANSCRIBE_FAILURE_RATE=1.0"
recreate transcription-worker TRANSCRIBE_FAILURE_RATE=1.0
ID=$(post_audio "$TENANT"); log "requestId=$ID"
sleep 20
status "$ID"
log "Verificação"
q quota "SELECT tenant_id, used, quota_limit FROM tenant_quota WHERE tenant_id='$TENANT';"
q quota "SELECT request_id, status FROM reservations WHERE request_id='$ID';"
q requests "SELECT id, status, failure_reason FROM requests WHERE id='$ID';"
q notification "SELECT request_id, kind, created_at FROM notifications WHERE request_id='$ID';"
aws --endpoint-url http://localhost:4566 s3 ls "s3://$S3_BUCKET/failed/" --recursive 2>/dev/null | grep "$ID" || echo "(confira failed/ no S3)"
log "restaurando worker"; recreate transcription-worker
