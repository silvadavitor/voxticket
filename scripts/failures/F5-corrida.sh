#!/usr/bin/env bash
# F5 — 100 requisições simultâneas para 10 créditos: exatamente 10 sucessos.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f5
set_quota "$TENANT" 10
recreate transcription-worker TRANSCRIBE_FAILURE_RATE=0
log "disparando 100 POSTs em paralelo"
seq 100 | xargs -P 100 -I{} curl -s -o /dev/null -w "%{http_code}\n" -F "tenantId=$TENANT" -F "file=@$SAMPLE_AUDIO" "$API/audios" | sort | uniq -c
sleep 30
q quota "SELECT tenant_id, used, quota_limit FROM tenant_quota WHERE tenant_id='$TENANT';"
q quota "SELECT status, count(*) FROM reservations WHERE tenant_id='$TENANT' GROUP BY 1;"
q requests "SELECT status, count(*) FROM requests WHERE tenant_id='$TENANT' GROUP BY 1;"
recreate transcription-worker
