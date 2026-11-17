#!/usr/bin/env bash
# F4 — Payload inválido: N tentativas, depois DLQ; as demais seguem.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f4
set_quota "$TENANT" 10
BAD=$(jq -cn --arg m "$(uuid)" '{messageId:$m, correlationId:"nao-e-uuid", type:"AudioReceived", version:1, occurredAt:"ontem", payload:{foo:"bar"}}')
log "publicando mensagem venenosa"; publish AudioReceived "$BAD"
log "enviando 3 áudios válidos"; for i in 1 2 3; do post_audio "$TENANT"; done
sleep 20
curl -fsS -u "$RMQ_AUTH" "$MGMT/api/queues/%2F/quota-service.dlq" | jq '{queue:.name, messages:.messages}'
q requests "SELECT status, count(*) FROM requests WHERE tenant_id='$TENANT' GROUP BY 1;"
