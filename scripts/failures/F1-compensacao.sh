#!/usr/bin/env bash
# F1 — Compensação: a dependência (transcrição) falha 100%.
# Esperado: crédito devolvido, áudio em failed/, pedido FAILED, cliente notificado.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F1 compensação"
T=$(new_tenant f1); set_quota "$T" 5

step "Cliente $T com 5 créditos. Estado antes:"
show quota "crédito" "SELECT tenant_id, quota_limit, used FROM tenant_quota WHERE tenant_id='$T'"

step "Simulando a dependência fora: transcrição falha 100% (TRANSCRIBE_FAILURE_RATE=1.0)"
recreate transcription-worker TRANSCRIBE_FAILURE_RATE=1.0
say "worker reiniciado com falha forçada"

step "Enviando um áudio e acompanhando a saga ao vivo"
ID=$(post_audio "$T"); say "pedido $ID (202 Accepted)"; links "$ID"
watch_status "$ID" "FAILED" 120 || true

step "Evidências da compensação"
show_logs transcription-worker "attempt .* failed|failed $ID" 4
show_logs request-service "COMPENSATING|failed/" 3
show quota "reserva" "SELECT request_id, status FROM reservations WHERE request_id='$ID'"
show quota "crédito" "SELECT tenant_id, quota_limit, used FROM tenant_quota WHERE tenant_id='$T'"
show notification "aviso" "SELECT request_id, kind, created_at FROM notifications WHERE request_id='$ID'"
say "S3 failed/: $(s3_ls failed/ | grep "$ID" | awk '{print $4}')"

step "Resultado"
check "pedido terminou FAILED"                    '[[ "$(api_status $ID)" == FAILED ]]'
# a devolução é assíncrona (CreditReleaseRequested → quota): pode chegar alguns ms depois do FAILED
check "reserva de crédito RELEASED"               'until_ok 15 "[[ \$(val quota \"SELECT status FROM reservations WHERE request_id='"'$ID'"'\") == RELEASED ]]"'
check "crédito devolvido (used voltou a 0)"       'until_ok 15 "[[ \$(used $T) == 0 ]]"'
check "cliente notificado (REQUEST_FAILED)"       'until_ok 15 "[[ \$(val notification \"SELECT count(*) FROM notifications WHERE request_id='"'$ID'"' AND kind='"'REQUEST_FAILED'"'\") == 1 ]]"'
check "áudio movido para failed/ no S3"           's3_ls failed/ | grep -q "$ID"'

step "Restaurando o worker"; recreate transcription-worker
finish
