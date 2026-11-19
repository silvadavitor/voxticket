#!/usr/bin/env bash
# F3 — Mesma mensagem (mesmo messageId) publicada 5x. Esperado: um único efeito (R1).
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F3 mensagem duplicada"
T=$(new_tenant f3); set_quota "$T" 10
MSG=$(uuid); REQ=$(uuid)
ENV=$(jq -cn --arg m "$MSG" --arg r "$REQ" --arg t "$T" --arg now "$(date -u +%FT%TZ)" \
  '{messageId:$m, correlationId:$r, type:"AudioReceived", version:1, occurredAt:$now,
    payload:{requestId:$r, tenantId:$t, audioKey:("audios/"+$t+"/"+$r+".ogg")}}')

step "Cliente $T com 10 créditos. Estado antes:"
show quota "crédito" "SELECT tenant_id, quota_limit, used FROM tenant_quota WHERE tenant_id='$T'"

step "Publicando 5x a MESMA mensagem AudioReceived (messageId $MSG)"
echo "$ENV" | jq . | sed 's/^/   /'
for i in 1 2 3 4 5; do publish AudioReceived "$ENV"; say "publicação $i"; done
until_ok 20 '[[ "$($COMPOSE logs quota-service 2>&1 | grep "$MSG" | grep -c duplicate_message)" -ge 4 ]]' || true

step "O quota-service processou 1 e descartou 4 (logs)"
show_logs quota-service "$MSG" 5

step "Estado depois: só um efeito"
show quota "crédito" "SELECT tenant_id, quota_limit, used FROM tenant_quota WHERE tenant_id='$T'"
show quota "reservas do pedido" "SELECT request_id, status FROM reservations WHERE request_id='$REQ'"
show quota "mensagens processadas" "SELECT message_id, processed_at FROM processed_messages WHERE message_id='$MSG'"

step "Resultado"
check "crédito reservado uma vez só (used = 1)"   '[[ "$(used $T)" == 1 ]]'
check "uma reserva para o pedido"                 '[[ "$(val quota "SELECT count(*) FROM reservations WHERE request_id='"'$REQ'"'")" == 1 ]]'
check "messageId registrado uma vez"              '[[ "$(val quota "SELECT count(*) FROM processed_messages WHERE message_id='"'$MSG'"'")" == 1 ]]'
check "4 repetições descartadas no log"           '[[ "$($COMPOSE logs quota-service 2>&1 | grep "$MSG" | grep -c duplicate_message)" -ge 4 ]]'
finish
