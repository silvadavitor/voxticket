#!/usr/bin/env bash
# F4 — Mensagem venenosa (fora do contrato). Esperado: 3 tentativas, DLQ, as outras seguem.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F4 mensagem venenosa"
T=$(new_tenant f4); set_quota "$T" 10

step "Estado das filas do quota-service antes"
DLQ_BEFORE=$(depth quota-service.dlq)
say "quota-service.q = $(depth quota-service.q) · quota-service.dlq = $DLQ_BEFORE"
queue_link quota-service.dlq

step "Publicando um payload FORA do contrato (correlationId não é uuid, data inválida, payload vazio)"
BAD=$(jq -cn --arg m "$(uuid)" '{messageId:$m, correlationId:"nao-e-uuid", type:"AudioReceived", version:1, occurredAt:"ontem", payload:{}}')
echo "$BAD" | jq . | sed 's/^/   /'
publish AudioReceived "$BAD"

step "Logo depois, uma mensagem VÁLIDA (para provar que a fila não trava)"
REQ=$(uuid)
publish AudioReceived "$(jq -cn --arg m "$(uuid)" --arg r "$REQ" --arg t "$T" --arg now "$(date -u +%FT%TZ)" \
  '{messageId:$m, correlationId:$r, type:"AudioReceived", version:1, occurredAt:$now,
    payload:{requestId:$r, tenantId:$t, audioKey:("audios/"+$t+"/"+$r+".ogg")}}')"
say "pedido válido $REQ"

step "A venenosa é rejeitada 3x (x-delivery-limit=3) e vai para a DLQ"
until_ok 30 "[[ \$(depth quota-service.dlq) -gt $DLQ_BEFORE ]]" || true
show_logs quota-service "invalid|inválid|schema|contract|DLQ|nack" 4
say "quota-service.dlq: $DLQ_BEFORE → $(depth quota-service.dlq)"
show quota "a válida foi processada" "SELECT request_id, status FROM reservations WHERE request_id='$REQ'"

step "Resultado"
check "venenosa foi para quota-service.dlq"       '[[ $(depth quota-service.dlq) -gt $DLQ_BEFORE ]]'
check "a válida foi processada (reserva criada)"  'until_ok 20 "[[ \$(val quota \"SELECT count(*) FROM reservations WHERE request_id='"'$REQ'"'\") == 1 ]]"'
check "fila principal não ficou travada"          'until_ok 15 "[[ \$(depth quota-service.q) == 0 ]]"'
finish
