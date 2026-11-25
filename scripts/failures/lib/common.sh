#!/usr/bin/env bash
# Funções comuns aos cenários de falha. Uso: source "$(dirname "$0")/lib/common.sh"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."   # raiz do repo
[[ -f .env ]] && set -a && source .env && set +a

API=${API:-http://localhost:8088/api} # pelo gateway, como o cliente (reparte entre as réplicas)
MGMT=${MGMT:-http://localhost:15672}
RMQ_AUTH="${RABBITMQ_USER:-guest}:${RABBITMQ_PASSWORD:-guest}"
# áudios de teste com fala real em pt-BR (o worker transcreve com Whisper)
SAMPLE_AUDIO=${SAMPLE_AUDIO:-scripts/failures/lib/tec-urg.mp3}   # técnico e urgente
ALT_AUDIO=${ALT_AUDIO:-scripts/failures/lib/finan.mp3}            # financeiro
BUCKET=${S3_BUCKET:-voxticket-local-audios}
COMPOSE="docker compose"

# ---------------------------------------------------------------- saída
PASS=0
FAIL=0
log()   { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date +%T)" "$*"; }
ok()    { printf '  \033[32m✅ %s\033[0m\n' "$*"; PASS=$((PASS + 1)); }
nok()   { printf '  \033[31m❌ %s\033[0m\n' "$*"; FAIL=$((FAIL + 1)); }
# check "descrição" 'condição bash'  → ✅/❌
check() { local desc=$1 cond=$2; if eval "$cond"; then ok "$desc"; else nok "$desc"; fi; }
# espera a condição (reavaliada a cada segundo) por até N segundos
until_ok() { local t=$1 cond=$2; for _ in $(seq "$t"); do eval "$cond" && return 0; sleep 1; done; return 1; }
finish() {
  printf '\n\033[1m%s: %d ok, %d falha(s)\033[0m\n' "${SCENARIO:-resultado}" "$PASS" "$FAIL"
  [[ $FAIL -eq 0 ]]
}

# ---------------------------------------------------------------- bancos (1 Postgres por serviço)
declare -A PG_CONTAINER=(
  [requests]=postgres-request [quota]=postgres-quota [transcription]=postgres-transcription
  [categorization]=postgres-categorization [ticket]=postgres-ticket [notification]=postgres-notification
)
# q quota "select ..."   → tabela formatada (para mostrar)
q()   { $COMPOSE exec -T "${PG_CONTAINER[$1]}" psql -U "$1_user" -d "$1" -c "$2"; }
# val quota "select ..." → só o valor (para comparar)
val() { $COMPOSE exec -T "${PG_CONTAINER[$1]}" psql -U "$1_user" -d "$1" -tAc "$2" | tr -d '[:space:]'; }
# txt quota "select ..." → valor de texto (mantém os espaços)
txt() { $COMPOSE exec -T "${PG_CONTAINER[$1]}" psql -U "$1_user" -d "$1" -tAc "$2" | tr -d '\r' | head -1; }

# ---------------------------------------------------------------- API (request-service)
# post_audio <tenant> [arquivo]; imprime o requestId
post_audio() {
  curl -fsS -F "tenantId=$1" -F "file=@${2:-$SAMPLE_AUDIO}" "$API/audios" | sed -E 's/.*"requestId":"([^"]+)".*/\1/'
}
api_status() { curl -fsS "$API/audios/$1" 2>/dev/null | sed -E 's/.*"status":"([^"]+)".*/\1/'; }
status()     { curl -fsS "$API/audios/$1"; echo; }
# wait_status <id> "<STATUS|OUTRO>" <segundos>
wait_status() { until_ok "${3:-120}" "[[ \"\$(api_status $1)\" =~ ^($2)\$ ]]"; }

# ---------------------------------------------------------------- cota (quota-service)
# cliente novo a cada execução: um teste não contamina o outro
new_tenant() { echo "$1-$(date +%H%M%S)-$RANDOM"; }
set_quota() {
  val quota "INSERT INTO tenant_quota(tenant_id, quota_limit, used) VALUES ('$1', $2, 0)
             ON CONFLICT (tenant_id) DO UPDATE SET quota_limit = EXCLUDED.quota_limit, used = 0;" >/dev/null
}
used() { val quota "SELECT used FROM tenant_quota WHERE tenant_id='$1'"; }

# ---------------------------------------------------------------- RabbitMQ
publish() {
  local routing_key=$1 envelope=$2 body
  body=$(jq -n --arg rk "$routing_key" --arg p "$envelope" \
    '{properties:{delivery_mode:2, content_type:"application/json"}, routing_key:$rk, payload:$p, payload_encoding:"string"}')
  curl -fsS -u "$RMQ_AUTH" -H 'content-type: application/json' \
    -X POST --data "$body" "$MGMT/api/exchanges/%2F/events/publish" >/dev/null
}
depth()     { curl -fsS -u "$RMQ_AUTH" "$MGMT/api/queues/%2F/$1" | jq '.messages // 0'; }
consumers() { curl -fsS -u "$RMQ_AUTH" "$MGMT/api/queues/%2F/$1" | jq '.consumers // 0'; }

# ---------------------------------------------------------------- utilidades
uuid() { cat /proc/sys/kernel/random/uuid; }
ALTERED=()
restore_altered() {
  local s
  for s in "${ALTERED[@]}"; do
    [[ -n $s ]] || continue
    printf '\n\033[33m⚠ cenário interrompido: restaurando %s com a configuração normal\033[0m\n' "$s"
    $COMPOSE up -d --no-deps --force-recreate "$s" >/dev/null 2>&1 || true
  done
}
trap restore_altered EXIT

# recria um serviço com variáveis sobrescritas: recreate transcription-worker VAR=valor ...
recreate() {
  local svc=$1; shift
  # com variáveis sobrescritas o serviço fica "alterado" até um recreate sem variáveis; se o cenário morrer
  # antes disso, o trap de saída restaura (senão o worker fica, por exemplo, com falha 100% para sempre)
  if (( $# )); then [[ " ${ALTERED[*]} " == *" $svc "* ]] || ALTERED+=("$svc")
  else ALTERED=("${ALTERED[@]/$svc}"); fi
  env "$@" $COMPOSE up -d --no-deps --force-recreate "$svc" >/dev/null 2>&1
  # porta resolvida a cada tentativa: o container recriado pode pegar outra porta da faixa
  until_ok 90 "curl -fsS localhost:\$(port_of $svc)/health >/dev/null 2>&1"
}
port_of() {
  case $1 in
    request-service) echo 8085 ;; quota-service) echo 8081 ;; ticket-service) echo 8082 ;;
    categorization-service) echo 8083 ;; notification-service) echo 8084 ;;
    # réplicas usam a faixa 8090-8099 e o Docker escolhe a porta livre: pergunta qual ficou com a 1ª réplica
    transcription-worker) $COMPOSE port --index 1 transcription-worker 8080 2>/dev/null | sed 's/.*://' ;;
  esac
}
health() { curl -fsS --max-time 3 "localhost:$(port_of "$1")/health" 2>/dev/null; }
SERVICES="request-service quota-service ticket-service categorization-service notification-service transcription-worker"
# todos os serviços com broker "up" no /health
all_brokers_up() { local s; for s in $SERVICES; do health "$s" | grep -q '"broker":"up"' || return 1; done; }
# objeto no S3 do MiniStack (aws-cli em container, na rede do compose)
s3_ls() {
  docker run --rm --network voxticket_default -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test \
    -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli:2.27.0 --endpoint-url http://ministack:4566 \
    s3 ls "s3://$BUCKET/$1" --recursive 2>/dev/null
}

# ---------------------------------------------------------------- demonstração (para mostrar ao vivo)
GRAFANA=${GRAFANA:-http://localhost:3000}
STEP=0
# step "texto" → passo numerado; com PAUSA=1 espera Enter (tempo de mostrar Grafana/RabbitMQ)
step() {
  STEP=$((STEP + 1))
  printf '\n\033[1;33m━━ %d. %s\033[0m\n' "$STEP" "$*"
  if [[ "${PAUSA:-0}" == 1 ]]; then read -rp "   (Enter para continuar) " _ </dev/tty; fi
}
say() { printf '   %s\n' "$*"; }
# show <db> "<titulo>" "<sql>" → mostra a consulta e o resultado em tabela
show() {
  local sql=$3
  (( ${#sql} > 110 )) && sql="${sql:0:107}…"   # consulta longa: mostra o começo
  printf '   \033[2m%s → %s\033[0m\n' "$1" "$sql"
  q "$1" "$3" | sed 's/^/   /'
}
# ruído que não prova nada (log interno do Whisper, recebimento genérico)
LOG_NOISE='VAD filter|Processing audio with|"(msg|message)": ?"received"'
# show_logs "<servico> [servico…]" <padrão> [n] → linhas que provam o comportamento,
# em ordem de horário e com o container de origem (mostra QUAL réplica fez o quê)
show_logs() {
  # shellcheck disable=SC2086
  $COMPOSE logs --timestamps $1 2>&1 | grep -E "$2" | grep -vE "$LOG_NOISE" \
    | sed -E 's/^([a-z0-9-]+)[[:space:]]*\| ([0-9-]+T[0-9:]+)[^ ]* (.*)$/\2 \1 \3/' | sort | tail -n "${3:-6}" \
    | sed -E 's/^[0-9-]+T([0-9:]+) ([a-z0-9-]+) .*"(msg|message|Message)": ?"([^"]*)".*/   \1 [\2] \4/' \
    | awk -v off="$(date +%z)" '{ # horário do Docker vem em UTC → horário local
        split($1, t, ":"); h = (t[1] + (substr(off,1,1)=="-" ? -1 : 1) * substr(off,2,2) + 24) % 24
        $1 = sprintf("   %02d:%s:%s", h, t[2], t[3]); print }' || true
}
# watch_status <id> "<FINAL1|FINAL2>" <segundos> → imprime cada mudança de estado da saga ao vivo
watch_status() {
  local id=$1 final=$2 t=${3:-120} last="" cur
  for _ in $(seq "$t"); do
    cur=$(api_status "$id")
    if [[ -n "$cur" && "$cur" != "$last" ]]; then
      printf '   %s  \033[1m%s\033[0m\n' "$(date +%T)" "$cur"; last=$cur
    fi
    [[ "$cur" =~ ^($final)$ ]] && return 0
    sleep 1
  done
  return 1
}
# links <requestId> → onde ver este pedido agora
links() {
  say "status na API:  $API/audios/$1"
  say "trace (Tempo):  $GRAFANA/explore → Tempo → {span.messaging.message.conversation_id=\"$1\"}"
}
queue_link() { say "fila no RabbitMQ: $MGMT/#/queues/%2F/$1"; }
