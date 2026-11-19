#!/usr/bin/env bash
# F6 — Broker fora por 30 s enquanto áudios chegam.
# Esperado: API segue respondendo 202 (outbox), serviços reconectam sozinhos, nada se perde.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F6 broker fora do ar"
T=$(new_tenant f6); set_quota "$T" 20
IDS=()

log "parando o RabbitMQ"; $COMPOSE stop rabbitmq >/dev/null 2>&1
STOP=$(date +%s)
for _ in 1 2 3 4 5; do IDS+=("$(post_audio "$T")"); sleep 1; done
check "API respondeu 202 com o broker fora"       '[[ ${#IDS[@]} == 5 && -n "${IDS[4]}" ]]'
check "eventos esperando no outbox"               '[[ "$(val requests "SELECT count(*) FROM outbox WHERE sent_at IS NULL")" -gt 0 ]]'
check "health mostra broker down (sem cair)"      'health request-service | grep -q "\"broker\":\"down\""'

sleep $(( 30 - ($(date +%s) - STOP) > 0 ? 30 - ($(date +%s) - STOP) : 0 ))
log "subindo o RabbitMQ de novo"; $COMPOSE start rabbitmq >/dev/null 2>&1

check "todos reconectaram sozinhos"               'until_ok 90 all_brokers_up'
check "outbox drenou (0 pendentes)"               'until_ok 60 "[[ \$(val requests \"SELECT count(*) FROM outbox WHERE sent_at IS NULL\") == 0 ]]"'
for ID in "${IDS[@]}"; do wait_status "$ID" "TICKET_OPENED|FAILED" 180 || true; done
check "os 5 pedidos chegaram ao fim"              '[[ "$(val requests "SELECT count(*) FROM requests WHERE tenant_id='"'$T'"' AND status='"'TICKET_OPENED'"'")" == 5 ]]'
finish
