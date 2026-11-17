#!/usr/bin/env bash
# F6 — Broker fora por 30 s enquanto áudios chegam: outbox acumula e drena, nada se perde.
source "$(dirname "$0")/lib/common.sh"
TENANT=tenant-f6
set_quota "$TENANT" 50
log "parando rabbitmq"; docker compose stop rabbitmq
for i in $(seq 10); do post_audio "$TENANT"; sleep 2; done
q requests "SELECT count(*) AS outbox_pendente FROM outbox WHERE sent_at IS NULL;"
sleep 10
log "subindo rabbitmq"; docker compose start rabbitmq
sleep 30
q requests "SELECT count(*) AS outbox_pendente FROM outbox WHERE sent_at IS NULL;"
q requests "SELECT status, count(*) FROM requests WHERE tenant_id='$TENANT' GROUP BY 1;"
