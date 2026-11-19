#!/usr/bin/env bash
# Teste de integração do categorization-service, sozinho (sem os outros serviços):
#   1. caminho feliz: transcrição no S3 → CategorizationRequested → AudioCategorized na fila do request-service
#   2. mesma mensagem 5x (F3): um efeito só
#   3. payload inválido (F4): 3 reentregas e DLQ; a fila principal segue vazia
# Pré-requisito: make svc s=categorization-service
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ -f .env ]] && set -a && source .env && set +a

MGMT=${MGMT:-http://localhost:15672}
AUTH="${RABBITMQ_USER:-guest}:${RABBITMQ_PASSWORD:-guest}"
BUCKET=${S3_BUCKET:-voxticket-local-audios}
AWS="docker run --rm -i --network voxticket_default -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli:2.27.0 --endpoint-url http://ministack:4566"

q() { docker compose exec -T postgres-categorization psql -U categorization_user -d categorization -tAc "$1"; }
depth() { curl -fsS -u "$AUTH" "$MGMT/api/queues/%2F/$1" | jq '.messages // 0'; }
purge() { curl -fsS -u "$AUTH" -X DELETE "$MGMT/api/queues/%2F/$1/contents" >/dev/null; }
# espera até a condição (string avaliada a cada tentativa) ser verdadeira, no máximo $1 segundos
until_ok() { local t=$1 cond=$2; for _ in $(seq "$t"); do eval "$cond" && return 0; sleep 1; done; return 1; }
pass() { printf '  \033[32m✔ %s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; FAILED=1; }
FAILED=0

publish_raw() {
  body=$(jq -n --arg p "$1" '{properties:{delivery_mode:2,content_type:"application/json"},routing_key:"CategorizationRequested",payload:$p,payload_encoding:"string"}')
  curl -fsS -u "$AUTH" -H 'content-type: application/json' -X POST --data "$body" "$MGMT/api/exchanges/%2F/events/publish" >/dev/null
}
envelope() { # $1=messageId $2=requestId
  jq -cn --arg m "$1" --arg r "$2" --arg now "$(date -u +%FT%TZ)" '{messageId:$m, correlationId:$r, type:"CategorizationRequested", version:1,
    occurredAt:$now, payload:{requestId:$r, tenantId:"tenant-demo", transcriptKey:("transcripts/"+$r+".json")}}'
}

purge request-service.q; purge categorization-service.dlq
REQ=$(cat /proc/sys/kernel/random/uuid); MSG=$(cat /proc/sys/kernel/random/uuid)

echo "1. caminho feliz (requestId $REQ)"
echo "{\"requestId\":\"$REQ\",\"text\":\"O sistema está fora do ar desde cedo, é urgente, não consigo fazer login\"}" \
  | $AWS s3 cp - "s3://$BUCKET/transcripts/$REQ.json" >/dev/null
publish_raw "$(envelope "$MSG" "$REQ")"
until_ok 15 '[[ "$(q "select count(*) from outbox where correlation_id='"'"'$REQ'"'"' and sent_at is not null")" == 1 ]]' \
  && pass "AudioCategorized publicado (outbox enviado)" || fail "outbox não foi enviado"
r=$(q "select category||'/'||priority from categorizations where request_id='$REQ'")
[[ "$r" == "TECNICO/CRITICAL" ]] && pass "classificado: $r" || fail "classificação inesperada: $r"
until_ok 10 '[[ "$(depth request-service.q)" -ge 1 ]]' && pass "chegou na fila do request-service" || fail "não chegou em request-service.q"

echo "2. mesma mensagem 5x (F3)"
for _ in 1 2 3 4 5; do publish_raw "$(envelope "$MSG" "$REQ")"; done
until_ok 15 '[[ "$(docker compose logs categorization-service 2>&1 | grep "duplicate, skipped" | grep -c "$MSG")" -ge 5 ]]' \
  && pass "5x 'duplicate, skipped' no log" || fail "não registrou as 5 duplicatas"
[[ "$(q "select count(*) from categorizations where request_id='$REQ'")" == 1 ]] && pass "1 categorização" || fail "efeito duplicado"
[[ "$(q "select count(*) from outbox where correlation_id='$REQ'")" == 1 ]] && pass "1 evento no outbox" || fail "evento duplicado"

echo "3. payload inválido (F4)"
publish_raw '{"messageId":"x","type":"CategorizationRequested","payload":{}}'
until_ok 20 '[[ "$(depth categorization-service.dlq)" -ge 1 ]]' && pass "foi para a DLQ" || fail "não chegou na DLQ"
until_ok 10 '[[ "$(depth categorization-service.q)" == 0 ]]' && pass "fila principal vazia: as outras seguem" || fail "fila principal travada"

exit $FAILED
