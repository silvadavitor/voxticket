#!/usr/bin/env bash
# F8 — 3 réplicas do worker, 30 áudios: carga dividida, sem duplicação.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f8
set_quota "$TENANT" 100
recreate transcription-worker TRANSCRIBE_FAILURE_RATE=0
# o compose já sobe 3 réplicas (deploy.replicas=3); recreate mantém o override de env
for i in $(seq 30); do post_audio "$TENANT" >/dev/null; done
sleep 40
q transcription "SELECT processed_by, count(*) FROM transcriptions GROUP BY 1 ORDER BY 1;"
q transcription "SELECT count(*) AS total, count(DISTINCT request_id) AS distintos FROM transcriptions;"
