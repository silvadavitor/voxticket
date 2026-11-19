#!/usr/bin/env bash
# F4 — Mensagem venenosa (fora do contrato). Esperado: 3 tentativas, DLQ, as outras seguem.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F4 mensagem venenosa"
T=$(new_tenant f4); set_quota "$T" 10
DLQ_BEFORE=$(depth quota-service.dlq)

log "publicando payload inválido (correlationId não é uuid, payload vazio)"
publish AudioReceived "$(jq -cn --arg m "$(uuid)" '{messageId:$m, correlationId:"nao-e-uuid", type:"AudioReceived", version:1, occurredAt:"ontem", payload:{}}')"

log "publicando uma mensagem válida logo depois"
REQ=$(uuid)
publish AudioReceived "$(jq -cn --arg m "$(uuid)" --arg r "$REQ" --arg t "$T" --arg now "$(date -u +%FT%TZ)" \
  '{messageId:$m, correlationId:$r, type:"AudioReceived", version:1, occurredAt:$now,
    payload:{requestId:$r, tenantId:$t, audioKey:("audios/"+$t+"/"+$r+".ogg")}}')"

check "venenosa foi para quota-service.dlq"       'until_ok 30 "[[ \$(depth quota-service.dlq) -gt $DLQ_BEFORE ]]"'
check "a válida foi processada (reserva criada)"  'until_ok 20 "[[ \$(val quota \"SELECT count(*) FROM reservations WHERE request_id='"'$REQ'"'\") == 1 ]]"'
check "fila principal não ficou travada"          'until_ok 15 "[[ \$(depth quota-service.q) == 0 ]]"'
finish
