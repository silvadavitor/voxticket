#!/usr/bin/env bash
# F5 — Corrida pelo recurso escasso: 100 pedidos simultâneos para 10 créditos (R2).
# Esperado: exatamente 10 reservas; os outros 90 recusados.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F5 corrida pelo recurso"
N=${N:-100}; LIMIT=${LIMIT:-10}
T=$(new_tenant f5); set_quota "$T" "$LIMIT"

log "disparando $N POSTs em paralelo para o cliente $T (cota $LIMIT)"
CODES=$(seq "$N" | xargs -P 50 -I{} curl -s -o /dev/null -w "%{http_code}\n" -F "tenantId=$T" -F "file=@$SAMPLE_AUDIO" "$API/audios" | sort | uniq -c)
echo "$CODES"
check "todos aceitos com 202"                     '[[ "$(echo "$CODES" | awk '"'"'$2==202{print $1}'"'"')" == "$N" ]]'

until_ok 90 '[[ "$(val requests "SELECT count(*) FROM requests WHERE tenant_id='"'$T'"' AND status <> '"'RECEIVED'"'")" == "$N" ]]' || true
check "crédito usado = $LIMIT (nunca passou)"      '[[ "$(used $T)" == "$LIMIT" ]]'
check "exatamente $LIMIT reservas"                 '[[ "$(val quota "SELECT count(*) FROM reservations WHERE tenant_id='"'$T'"'")" == "$LIMIT" ]]'
check "$((N - LIMIT)) pedidos REJECTED"            '[[ "$(val requests "SELECT count(*) FROM requests WHERE tenant_id='"'$T'"' AND status='"'REJECTED'"'")" == "$((N - LIMIT))" ]]'
q requests "SELECT status, count(*) FROM requests WHERE tenant_id='$T' GROUP BY 1 ORDER BY 1"
finish
