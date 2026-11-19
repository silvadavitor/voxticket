#!/usr/bin/env bash
# F2 — Serviço morre no meio: docker kill na réplica que está transcrevendo.
# Esperado: a mensagem volta para a fila, outra réplica processa, efeito aplicado uma vez só.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F2 serviço morre"
T=$(new_tenant f2); set_quota "$T" 5

step "Deixando a transcrição lenta (8 s) para dar tempo de matar a réplica"
recreate transcription-worker TRANSCRIBE_LATENCY_MS_MIN=8000 TRANSCRIBE_LATENCY_MS_MAX=8000 TRANSCRIBE_FAILURE_RATE=0
say "réplicas: $($COMPOSE ps --format '{{.Name}}' transcription-worker | tr '\n' ' ')"

step "Enviando um áudio"
ID=$(post_audio "$T"); say "pedido $ID"; links "$ID"

step "Descobrindo qual réplica pegou o pedido (log \"processing $ID\")"
VICTIM=""
until_ok 30 'VICTIM=$(for c in $($COMPOSE ps -q transcription-worker); do docker logs "$c" 2>&1 | grep -q "processing $ID" && echo "$c"; done | head -1); [[ -n "$VICTIM" ]]' || true
VNAME=$( [[ -n "$VICTIM" ]] && docker inspect -f '{{.Name}}' "$VICTIM" | tr -d / )
say "réplica processando: ${VNAME:-não encontrada} (hostname ${VICTIM:0:12})"

step "docker kill nessa réplica no meio do processamento"
[[ -n "$VICTIM" ]] && docker kill "$VICTIM" >/dev/null && say "$VNAME morta"
queue_link transcription-worker.q

step "A mensagem (sem ACK) volta para a fila e outra réplica assume"
watch_status "$ID" "TICKET_OPENED|FAILED" 180 || true
show_logs transcription-worker "$ID" 6

step "Evidências"
show transcription "quem processou" "SELECT request_id, status, processed_by, attempts FROM transcriptions WHERE request_id='$ID'"
show ticket "chamados do pedido" "SELECT ticket_id, request_id FROM tickets WHERE request_id='$ID'"

step "Resultado"
check "achou a réplica processando o pedido"      '[[ -n "$VICTIM" ]]'
check "pedido concluído por outra réplica"        '[[ "$(api_status $ID)" == TICKET_OPENED ]]'
check "transcrição gravada uma vez só"            '[[ "$(val transcription "SELECT count(*) FROM transcriptions WHERE request_id='"'$ID'"'")" == 1 ]]'
check "processado por réplica diferente da morta" '[[ "$(val transcription "SELECT processed_by FROM transcriptions WHERE request_id='"'$ID'"'")" != "${VICTIM:0:12}" ]]'
check "um chamado só"                             '[[ "$(val ticket "SELECT count(*) FROM tickets WHERE request_id='"'$ID'"'")" == 1 ]]'

step "Restaurando o worker (sobe a réplica morta)"; recreate transcription-worker
finish
