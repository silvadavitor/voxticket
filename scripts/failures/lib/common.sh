#!/usr/bin/env bash
# Funções comuns aos cenários de falha. Uso: source "$(dirname "$0")/lib/common.sh"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."   # raiz do repo
[[ -f .env ]] && set -a && source .env && set +a

API=${API:-http://localhost:8080}
MGMT=${MGMT:-http://localhost:15672}
RMQ_AUTH="${RABBITMQ_USER:-guest}:${RABBITMQ_PASSWORD:-guest}"
SAMPLE_AUDIO=${SAMPLE_AUDIO:-scripts/failures/lib/sample.ogg}   # fala real em pt-BR (o worker usa Whisper)
BUCKET=${S3_BUCKET:-voxticket-local-audios}
COMPOSE="docker compose --profile apps"

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

# ---------------------------------------------------------------- API (request-service)
# envia um áudio; imprime o requestId
post_audio() {
  curl -fsS -F "tenantId=$1" -F "file=@$SAMPLE_AUDIO" "$API/audios" | sed -E 's/.*"requestId":"([^"]+)".*/\1/'
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
# recria um serviço com variáveis sobrescritas: recreate transcription-worker VAR=valor ...
recreate() {
  local svc=$1; shift
  env "$@" $COMPOSE up -d --force-recreate "$svc" >/dev/null 2>&1
  until_ok 90 "curl -fsS localhost:$(port_of "$svc")/health >/dev/null 2>&1"
}
port_of() {
  case $1 in
    request-service) echo 8080 ;; quota-service) echo 8081 ;; ticket-service) echo 8082 ;;
    categorization-service) echo 8083 ;; notification-service) echo 8084 ;; transcription-worker) echo 8090 ;;
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
