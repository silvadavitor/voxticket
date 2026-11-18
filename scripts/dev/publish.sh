#!/usr/bin/env bash
# Publica um evento no exchange `events` para testar um serviço sozinho, sem os outros prontos.
#
#   scripts/dev/publish.sh <Tipo> [arquivo.json]
#
# Sem arquivo, gera um exemplo válido do tipo (veja os payloads em contracts/schemas/<Tipo>.v1.schema.json).
# O envelope (messageId, correlationId, occurredAt...) é montado aqui; o arquivo traz só o payload.
set -euo pipefail
TYPE=${1:?uso: scripts/dev/publish.sh <Tipo> [payload.json]}
FILE=${2:-}
MGMT=${MGMT:-http://localhost:15672}
AUTH="${RABBITMQ_USER:-guest}:${RABBITMQ_PASSWORD:-guest}"
REQ=${REQUEST_ID:-$(cat /proc/sys/kernel/random/uuid)}

if [[ -n "$FILE" ]]; then
  PAYLOAD=$(cat "$FILE")
else
  case "$TYPE" in
    AudioReceived)           PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", audioKey:("audios/tenant-demo/"+$r+".ogg")}') ;;
    CreditReserved)          PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo"}') ;;
    CreditRejected)          PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", reason:"sem crédito"}') ;;
    TranscriptionRequested)  PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", audioKey:("audios/tenant-demo/"+$r+".ogg")}') ;;
    AudioTranscribed)        PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, transcriptKey:("transcripts/"+$r+".json")}') ;;
    TranscriptionFailed)     PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, attempts:3, reason:"falha simulada"}') ;;
    CategorizationRequested) PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", transcriptKey:("transcripts/"+$r+".json")}') ;;
    AudioCategorized)        PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, category:"TECNICO", priority:"HIGH", confidence:0.9}') ;;
    TicketRequested)         PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", category:"TECNICO", priority:"HIGH"}') ;;
    TicketOpened)            PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", ticketId:"TCK-1"}') ;;
    TicketRejected)          PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, reason:"recusado"}') ;;
    CreditReleaseRequested)  PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", reason:"compensação"}') ;;
    RequestFailed)           PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r, tenantId:"tenant-demo", finalStatus:"FAILED", reason:"teste"}') ;;
    TranscriptDiscardRequested) PAYLOAD=$(jq -n --arg r "$REQ" '{requestId:$r}') ;;
    *) echo "tipo desconhecido: $TYPE (veja contracts/schemas/)"; exit 1 ;;
  esac
fi

ENVELOPE=$(jq -cn --arg t "$TYPE" --arg r "$REQ" --arg m "${MESSAGE_ID:-$(cat /proc/sys/kernel/random/uuid)}" \
  --arg now "$(date -u +%FT%TZ)" --argjson p "$PAYLOAD" \
  '{messageId:$m, correlationId:$r, type:$t, version:1, occurredAt:$now, payload:$p}')
BODY=$(jq -n --arg rk "$TYPE" --arg p "$ENVELOPE" \
  '{properties:{delivery_mode:2, content_type:"application/json"}, routing_key:$rk, payload:$p, payload_encoding:"string"}')

curl -fsS -u "$AUTH" -H 'content-type: application/json' -X POST --data "$BODY" "$MGMT/api/exchanges/%2F/events/publish" \
  | jq -e '.routed' >/dev/null && echo "publicado $TYPE (requestId $REQ)" || echo "publicado, mas nenhuma fila recebeu: o rabbitmq-init rodou?"
echo "$ENVELOPE" | jq .
