#!/usr/bin/env bash
# F2 — Serviço morre no meio: docker kill na réplica que está transcrevendo.
# Esperado: a mensagem volta para a fila, outra réplica processa, efeito aplicado uma vez só.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F2 serviço morre"
T=$(new_tenant f2); set_quota "$T" 5

log "worker lento (8 s por transcrição) para dar tempo de matar"
recreate transcription-worker TRANSCRIBE_LATENCY_MS_MIN=8000 TRANSCRIBE_LATENCY_MS_MAX=8000 TRANSCRIBE_FAILURE_RATE=0
ID=$(post_audio "$T"); log "pedido $ID"

VICTIM=""
until_ok 30 'VICTIM=$(for c in $($COMPOSE ps -q transcription-worker); do docker logs "$c" 2>&1 | grep -q "processing $ID" && echo "$c"; done | head -1); [[ -n "$VICTIM" ]]' || true
check "achou a réplica processando o pedido"      '[[ -n "$VICTIM" ]]'
[[ -n "$VICTIM" ]] && { log "docker kill $(docker inspect -f '{{.Name}}' "$VICTIM")"; docker kill "$VICTIM" >/dev/null; }

wait_status "$ID" "TICKET_OPENED|FAILED" 180 || true
check "pedido concluído por outra réplica"        '[[ "$(api_status $ID)" == TICKET_OPENED ]]'
check "transcrição gravada uma vez só"            '[[ "$(val transcription "SELECT count(*) FROM transcriptions WHERE request_id='"'$ID'"'")" == 1 ]]'
check "processado por réplica diferente da morta" '[[ "$(val transcription "SELECT processed_by FROM transcriptions WHERE request_id='"'$ID'"'")" != "${VICTIM:0:12}" ]]'
check "um chamado só"                             '[[ "$(val ticket "SELECT count(*) FROM tickets WHERE request_id='"'$ID'"'")" == 1 ]]'

log "restaurando o worker (sobe a réplica morta)"; recreate transcription-worker
finish
