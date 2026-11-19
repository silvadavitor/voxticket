#!/usr/bin/env bash
# F7 — Resposta tardia: transcrição (20 s) mais lenta que o timeout da saga (10 s).
# Esperado: pedido EXPIRED, crédito devolvido uma vez, resultado atrasado DISCARDED, nenhum chamado.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F7 resposta tardia"
T=$(new_tenant f7); set_quota "$T" 5

log "worker com 20 s de latência e saga com timeout de 10 s"
recreate transcription-worker TRANSCRIBE_LATENCY_MS_MIN=20000 TRANSCRIBE_LATENCY_MS_MAX=20000 TRANSCRIBE_FAILURE_RATE=0
recreate request-service SAGA_TIMEOUT_MS=10000
ID=$(post_audio "$T"); log "pedido $ID"

wait_status "$ID" "EXPIRED" 40 || true
check "pedido EXPIRED pelo timeout"               '[[ "$(api_status $ID)" == EXPIRED ]]'
check "crédito devolvido (reserva RELEASED)"      'until_ok 15 "[[ \$(val quota \"SELECT status FROM reservations WHERE request_id='"'$ID'"'\") == RELEASED ]]"'
check "devolvido uma vez só (used = 0)"           '[[ "$(used $T)" == 0 ]]'
check "resultado atrasado marcado DISCARDED"      'until_ok 60 "[[ \$(val transcription \"SELECT status FROM transcriptions WHERE request_id='"'$ID'"'\") == DISCARDED ]]"'
check "nenhum chamado aberto"                     '[[ "$(val ticket "SELECT count(*) FROM tickets WHERE request_id='"'$ID'"'")" == 0 ]]'
check "pedido continua EXPIRED"                   '[[ "$(api_status $ID)" == EXPIRED ]]'

log "linha do tempo do pedido"
$COMPOSE logs --no-log-prefix request-service transcription-worker 2>&1 | grep "$ID" | cut -c1-200 | tail -8
log "restaurando worker e request-service"; recreate transcription-worker; recreate request-service
finish
