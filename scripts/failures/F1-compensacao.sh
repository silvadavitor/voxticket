#!/usr/bin/env bash
# F1 — Compensação: a dependência (transcrição) falha 100%.
# Esperado: crédito devolvido, áudio em failed/, pedido FAILED, cliente notificado.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F1 compensação"
T=$(new_tenant f1); set_quota "$T" 5

log "worker com TRANSCRIBE_FAILURE_RATE=1.0 (toda transcrição falha)"
recreate transcription-worker TRANSCRIBE_FAILURE_RATE=1.0
ID=$(post_audio "$T"); log "pedido $ID"

wait_status "$ID" "FAILED" 120 || true
check "pedido terminou FAILED"                    '[[ "$(api_status $ID)" == FAILED ]]'
check "reserva de crédito RELEASED"               '[[ "$(val quota "SELECT status FROM reservations WHERE request_id='"'$ID'"'")" == RELEASED ]]'
check "crédito devolvido (used voltou a 0)"       '[[ "$(used $T)" == 0 ]]'
check "cliente notificado (REQUEST_FAILED)"       'until_ok 15 "[[ \$(val notification \"SELECT count(*) FROM notifications WHERE request_id='"'$ID'"' AND kind='"'REQUEST_FAILED'"'\") == 1 ]]"'
check "áudio movido para failed/ no S3"           's3_ls failed/ | grep -q "$ID"'

log "restaurando o worker"; recreate transcription-worker
finish
