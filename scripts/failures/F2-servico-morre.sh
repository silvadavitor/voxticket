#!/usr/bin/env bash
# F2 — Serviço morre no meio: kill na réplica que está processando.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f2
set_quota "$TENANT" 5
recreate transcription-worker TRANSCRIBE_LATENCY_MS_MIN=8000 TRANSCRIBE_LATENCY_MS_MAX=8000 TRANSCRIBE_FAILURE_RATE=0
# o compose já sobe 3 réplicas (deploy.replicas=3); recreate mantém o override de env
ID=$(post_audio "$TENANT"); log "requestId=$ID"
sleep 2
VICTIM=$(docker compose ps -q transcription-worker | while read -r c; do docker logs "$c" 2>&1 | grep -q "processing $ID" && echo "$c"; done | head -1)
log "docker kill $VICTIM"; docker kill "$VICTIM"
sleep 15
q transcription "SELECT request_id, processed_by, count(*) FROM transcriptions WHERE request_id='$ID' GROUP BY 1,2;"
docker compose logs transcription-worker | grep "$ID"
recreate transcription-worker
