#!/usr/bin/env bash
# F7 — Resposta tardia: transcrição (20 s) mais lenta que o timeout da saga (10 s).
# Esperado: pedido EXPIRED, crédito devolvido uma vez, resultado atrasado DISCARDED, nenhum chamado.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F7 resposta tardia"
T=$(new_tenant f7); set_quota "$T" 5

step "Transcrição com 20 s de latência e saga com timeout de 10 s"
recreate transcription-worker TRANSCRIBE_LATENCY_MS_MIN=20000 TRANSCRIBE_LATENCY_MS_MAX=20000 TRANSCRIBE_FAILURE_RATE=0
recreate request-service SAGA_TIMEOUT_MS=10000
say "worker: 20 s por transcrição · request-service: SAGA_TIMEOUT_MS=10000"

step "Enviando um áudio e acompanhando a saga"
ID=$(post_audio "$T"); say "pedido $ID"; links "$ID"
watch_status "$ID" "EXPIRED" 40 || true

step "Aos ~10 s a rotina de timeout expirou o pedido e devolveu o crédito"
show quota "reserva" "SELECT request_id, status FROM reservations WHERE request_id='$ID'"
show quota "crédito" "SELECT tenant_id, used FROM tenant_quota WHERE tenant_id='$T'"

step "Aos ~20 s chega a transcrição atrasada → orquestrador pede o descarte"
until_ok 60 "[[ \$(val transcription \"SELECT status FROM transcriptions WHERE request_id='$ID'\") == DISCARDED ]]" || true
show transcription "transcrição" "SELECT request_id, status, processed_by FROM transcriptions WHERE request_id='$ID'"
show ticket "chamados" "SELECT count(*) AS chamados FROM tickets WHERE request_id='$ID'"

step "Linha do tempo do pedido nos logs"
show_logs "request-service transcription-worker" "$ID" 12

step "Resultado"
check "pedido EXPIRED pelo timeout"               '[[ "$(api_status $ID)" == EXPIRED ]]'
check "crédito devolvido (reserva RELEASED)"      '[[ "$(val quota "SELECT status FROM reservations WHERE request_id='"'$ID'"'")" == RELEASED ]]'
check "devolvido uma vez só (used = 0)"           '[[ "$(used $T)" == 0 ]]'
check "resultado atrasado marcado DISCARDED"      '[[ "$(val transcription "SELECT status FROM transcriptions WHERE request_id='"'$ID'"'")" == DISCARDED ]]'
check "nenhum chamado aberto"                     '[[ "$(val ticket "SELECT count(*) FROM tickets WHERE request_id='"'$ID'"'")" == 0 ]]'

step "Restaurando worker e request-service"; recreate transcription-worker; recreate request-service
finish
