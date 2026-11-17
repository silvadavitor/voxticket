#!/usr/bin/env bash
# Funções comuns aos cenários. Uso: source "$(dirname "$0")/lib/common.sh"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."   # raiz do repo
[[ -f .env ]] && set -a && source .env && set +a

API=${API:-http://localhost:8080}
MGMT=${MGMT:-http://localhost:15672}
RMQ_AUTH="${RABBITMQ_USER:-guest}:${RABBITMQ_PASSWORD:-guest}"
SAMPLE_AUDIO=${SAMPLE_AUDIO:-scripts/failures/lib/sample.ogg}

log() { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date +%T)" "$*"; }

# psql no Postgres de um serviço (1 container por serviço): q quota "select ..."
declare -A PG_CONTAINER=(
  [requests]=postgres-request [quota]=postgres-quota [transcription]=postgres-transcription
  [categorization]=postgres-categorization [ticket]=postgres-ticket [notification]=postgres-notification
)
q() { docker compose exec -T "${PG_CONTAINER[$1]}" psql -U "$1_user" -d "$1" -c "$2"; }

# envia um áudio; imprime o requestId
post_audio() {
  local tenant=$1
  curl -fsS -F "tenantId=$tenant" -F "file=@$SAMPLE_AUDIO" "$API/audios" | sed -E 's/.*"requestId":"([^"]+)".*/\1/'
}

status() { curl -fsS "$API/audios/$1"; echo; }

# define a cota de um tenant (tabela do quota-service: tenant_quota)
set_quota() {
  q quota "INSERT INTO tenant_quota(tenant_id, quota_limit, used) VALUES ('$1', $2, 0)
           ON CONFLICT (tenant_id) DO UPDATE SET quota_limit = EXCLUDED.quota_limit, used = 0;"
}

# publica um envelope (JSON) no exchange events com a routing key informada
publish() {
  local routing_key=$1 envelope=$2
  local body
  body=$(jq -n --arg rk "$routing_key" --arg p "$envelope" \
    '{properties:{delivery_mode:2, content_type:"application/json"}, routing_key:$rk, payload:$p, payload_encoding:"string"}')
  curl -fsS -u "$RMQ_AUTH" -H 'content-type: application/json' \
    -X POST --data "$body" "$MGMT/api/exchanges/%2F/events/publish"
  echo
}

uuid() { cat /proc/sys/kernel/random/uuid; }

# recria um serviço com variáveis sobrescritas: recreate transcription-worker VAR=valor ...
recreate() {
  local svc=$1; shift
  env "$@" docker compose --profile apps up -d --force-recreate "$svc"
}
