#!/usr/bin/env bash
# Verifica os requisitos do trabalho com o sistema rodando e mostra um placar no fim.
#
#   make check        rápido (~2 min): R3–R6 direto + F3 (R1), F4 e F5 (R2)
#   make check-all    completo (~10–15 min): R3–R6 + F1…F8
#
# Cada cenário mostra a própria evidência na tela (SQL, logs, saga ao vivo); o placar resume tudo.
source "$(dirname "$0")/failures/lib/common.sh"
MODE=${1:-rapido}
RESULTS=()
record() { RESULTS+=("$1|$2|$3"); }   # nome | ok/falha | segundos

# ---------------------------------------------------------------- 0. o sistema está de pé?
log "Pré-requisito: todos os serviços respondendo"
down=()
for s in $SERVICES; do health "$s" >/dev/null || down+=("$s"); done
if (( ${#down[@]} )); then
  nok "fora do ar: ${down[*]}  →  rode 'docker compose up -d --build' e espere uns segundos"
  exit 1
fi
ok "6 serviços respondendo no /health"

# ---------------------------------------------------------------- requisitos testados direto
requisito() { # requisito "<nome>" <função>
  local nome=$1 fn=$2 t0=$SECONDS before=$FAIL
  log "$nome"
  "$fn"
  if (( FAIL == before )); then record "$nome" ok $((SECONDS - t0)); else record "$nome" falha $((SECONDS - t0)); fi
}

r3() {
  local T ID BODY
  T=$(new_tenant r3); set_quota "$T" 5
  BODY=$(curl -s -w '\n%{http_code}' -F "tenantId=$T" -F "file=@$SAMPLE_AUDIO" "$API/audios")
  say "POST /audios → HTTP $(tail -1 <<<"$BODY") $(head -1 <<<"$BODY")"
  check "POST /audios responde 202 Accepted com requestId" '[[ "$(tail -1 <<<"$BODY")" == 202 && "$(head -1 <<<"$BODY")" == *requestId* ]]'
  ID=$(head -1 <<<"$BODY" | sed -E 's/.*"requestId":"([^"]+)".*/\1/')
  say "GET /audios/$ID → $(status "$ID")"
  check "GET /audios/{id} devolve o status da saga" '[[ -n "$(api_status $ID)" ]]'
  check "o pedido avança sem o cliente esperar" 'watch_status "$ID" "TICKET_OPENED|FAILED" 120'
}

r4() {
  local n
  n=$(consumers transcription-worker.q)
  say "consumidores em transcription-worker.q: $n · réplicas: $($COMPOSE ps --format '{{.Name}}' transcription-worker | tr '\n' ' ')"
  check "2 ou mais réplicas consumindo a mesma fila" '[[ "$n" -ge 2 ]]'
  check "prefetch = 1 por consumidor (divisão justa)" '[[ "$(curl -fsS -u "$RMQ_AUTH" "$MGMT/api/consumers" | jq "[.[] | select(.queue.name==\"transcription-worker.q\") | .prefetch_count] | max")" == 1 ]]'
}

r5() {
  local s
  s=$(health transcription-worker)
  say "configuração da dependência instável: $(jq -c '.settings | {latency_ms_min, latency_ms_max, failure_rate, max_attempts}' <<<"$s")"
  check "latência e taxa de falha vêm de variáveis de ambiente" 'jq -e ".settings | has(\"latency_ms_min\") and has(\"failure_rate\")" <<<"$s" >/dev/null'
  say "(F1 usa TRANSCRIBE_FAILURE_RATE=1.0; F7 usa TRANSCRIBE_LATENCY_MS=20000)"
}

r6() {
  for s in $SERVICES; do say "$(printf '%-24s' "$s") $(health "$s" | jq -c '{broker, db}' 2>/dev/null)"; done
  check "todos com broker e banco no ar" 'all_brokers_up'
  say "(queda real do broker e reconexão sozinha: F6, no make check-all)"
}

requisito "R3 API assíncrona (202 + status)" r3
requisito "R4 consumidores concorrentes" r4
requisito "R5 dependência instável configurável" r5
requisito "R6 reconexão / health" r6

# ---------------------------------------------------------------- cenários (cada um com a sua evidência)
cenario() { # cenario <arquivo> "<nome>"
  local t0=$SECONDS
  if bash "scripts/failures/$1"; then record "$2" ok $((SECONDS - t0)); else record "$2" falha $((SECONDS - t0)); fi
}

if [[ "$MODE" == completo ]]; then
  cenario F1-compensacao.sh      "F1 compensação"
  cenario F2-servico-morre.sh    "F2 serviço morre"
  cenario F3-duplicada.sh        "F3 duplicada (R1)"
  cenario F4-venenosa.sh         "F4 venenosa → DLQ"
  cenario F5-corrida.sh          "F5 corrida (R2)"
  cenario F6-broker-fora.sh      "F6 broker fora (R6)"
  cenario F7-resposta-tardia.sh  "F7 resposta tardia"
  cenario F8-escala.sh           "F8 escala (R4)"
else
  cenario F3-duplicada.sh        "F3 duplicada (R1)"
  cenario F4-venenosa.sh         "F4 venenosa → DLQ"
  cenario F5-corrida.sh          "F5 corrida (R2)"
fi

# ---------------------------------------------------------------- placar
printf '\n\033[1m%-40s %s  %s\033[0m\n' "PLACAR" "ok?" "tempo"
falhas=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r nome res seg <<<"$r"
  if [[ $res == ok ]]; then icon="✅"; else icon="❌"; falhas=$((falhas + 1)); fi
  printf '%s%*s %s   %ss\n' "$nome" $(( 40 - ${#nome} )) "" "$icon" "$seg"   # ${#} conta letras, não bytes
done
printf '\n\033[1m%d de %d ok\033[0m\n' $(( ${#RESULTS[@]} - falhas )) ${#RESULTS[@]}
(( falhas == 0 ))
