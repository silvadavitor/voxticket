#!/usr/bin/env bash
# F3 — Mesma mensagem (mesmo messageId) publicada 5x: um único efeito.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f3
set_quota "$TENANT" 10
MSG=$(uuid); REQ=$(uuid)
ENV=$(jq -cn --arg m "$MSG" --arg r "$REQ" --arg t "$TENANT" --arg now "$(date -u +%FT%TZ)" \
  '{messageId:$m, correlationId:$r, type:"AudioReceived", version:1, occurredAt:$now,
    payload:{requestId:$r, tenantId:$t, audioKey:("audios/"+$t+"/"+$r+".ogg")}}')
for i in 1 2 3 4 5; do log "publicação $i"; publish AudioReceived "$ENV"; done
sleep 5
q quota "SELECT tenant_id, used, quota_limit FROM tenant_quota WHERE tenant_id='$TENANT';"
q quota "SELECT count(*) AS processed FROM processed_messages WHERE message_id='$MSG';"
docker compose logs quota-service | grep -c "duplicate" || true
