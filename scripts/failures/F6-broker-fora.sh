#!/usr/bin/env bash
# F6 — Broker fora por 30 s enquanto áudios chegam.
# Esperado: API segue respondendo 202 (outbox), serviços reconectam sozinhos, nada se perde.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F6 broker fora do ar"
T=$(new_tenant f6); set_quota "$T" 20
IDS=()
outbox() { val requests "SELECT count(*) FROM outbox WHERE sent_at IS NULL"; }

step "Derrubando o RabbitMQ (docker compose stop rabbitmq)"
$COMPOSE stop rabbitmq >/dev/null 2>&1; STOP=$(date +%s)
say "request-service /health: $(health request-service)"

step "Enviando 5 áudios COM O BROKER FORA"
for _ in 1 2 3 4 5; do ID=$(post_audio "$T"); IDS+=("$ID"); say "202 → $ID · outbox pendente: $(outbox)"; sleep 1; done

step "Os serviços continuam vivos, só avisam broker down"
for s in $SERVICES; do say "$(printf '%-24s' "$s") $(health "$s" | grep -o '"broker":"[a-z]*"' || echo 'sem resposta')"; done

step "Esperando completar 30 s fora do ar"
while (( $(date +%s) - STOP < 30 )); do say "$(( $(date +%s) - STOP )) s · outbox pendente: $(outbox)"; sleep 5; done

step "Subindo o RabbitMQ de novo (docker compose start rabbitmq)"
$COMPOSE start rabbitmq >/dev/null 2>&1
for _ in $(seq 30); do
  P=$(outbox); say "$(date +%T) outbox pendente: $P"
  [[ "$P" == 0 ]] && all_brokers_up && break
  sleep 3
done
show_logs request-service "broker|reconect|connected" 3

step "Os 5 pedidos feitos com o broker fora chegam ao fim"
for ID in "${IDS[@]}"; do wait_status "$ID" "TICKET_OPENED|FAILED" 180 || true; say "$ID → $(api_status "$ID")"; done

step "Resultado"
check "API respondeu 202 com o broker fora"       '[[ ${#IDS[@]} == 5 && -n "${IDS[4]}" ]]'
check "todos reconectaram sozinhos"               'until_ok 90 all_brokers_up'
check "outbox drenou (0 pendentes)"               'until_ok 60 "[[ \$(outbox) == 0 ]]"'
check "os 5 pedidos chegaram ao fim"              '[[ "$(val requests "SELECT count(*) FROM requests WHERE tenant_id='"'$T'"' AND status='"'TICKET_OPENED'"'")" == 5 ]]'
finish
