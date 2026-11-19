#!/usr/bin/env bash
# F3 — Mesma mensagem (mesmo messageId) publicada 5x. Esperado: um único efeito (R1).
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F3 mensagem duplicada"
T=$(new_tenant f3); set_quota "$T" 10
MSG=$(uuid); REQ=$(uuid)
ENV=$(jq -cn --arg m "$MSG" --arg r "$REQ" --arg t "$T" --arg now "$(date -u +%FT%TZ)" \
  '{messageId:$m, correlationId:$r, type:"AudioReceived", version:1, occurredAt:$now,
    payload:{requestId:$r, tenantId:$t, audioKey:("audios/"+$t+"/"+$r+".ogg")}}')

log "publicando o mesmo AudioReceived 5x (messageId $MSG)"
for _ in 1 2 3 4 5; do publish AudioReceived "$ENV"; done

until_ok 20 '[[ "$($COMPOSE logs quota-service 2>&1 | grep "$MSG" | grep -c duplicate_message)" -ge 4 ]]' || true
check "crédito reservado uma vez só (used = 1)"   '[[ "$(used $T)" == 1 ]]'
check "uma reserva para o pedido"                 '[[ "$(val quota "SELECT count(*) FROM reservations WHERE request_id='"'$REQ'"'")" == 1 ]]'
check "messageId registrado uma vez"              '[[ "$(val quota "SELECT count(*) FROM processed_messages WHERE message_id='"'$MSG'"'")" == 1 ]]'
check "4 repetições descartadas no log"           '[[ "$($COMPOSE logs quota-service 2>&1 | grep "$MSG" | grep -c duplicate_message)" -ge 4 ]]'
finish
