#!/usr/bin/env bash
# F5 — Corrida pelo recurso escasso: 100 pedidos simultâneos para 10 créditos (R2).
# Esperado: exatamente 10 reservas; os outros 90 recusados.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F5 corrida pelo recurso"
N=${N:-100}; LIMIT=${LIMIT:-10}
T=$(new_tenant f5); set_quota "$T" "$LIMIT"

step "Cliente $T com $LIMIT créditos. Estado antes:"
show quota "crédito" "SELECT tenant_id, quota_limit, used FROM tenant_quota WHERE tenant_id='$T'"

step "Disparando $N POSTs AO MESMO TEMPO (50 em paralelo)"
CODES=$(seq "$N" | xargs -P 50 -I{} curl -s -o /dev/null -w "%{http_code}\n" -F "tenantId=$T" -F "file=@$SAMPLE_AUDIO" "$API/audios" | sort | uniq -c)
say "respostas HTTP (quantidade × código):"; echo "$CODES" | sed 's/^/   /'

step "Acompanhando a reserva atômica (atualiza a cada 2 s)"
for _ in $(seq 45); do
  R=$(txt requests "SELECT count(*) FILTER (WHERE status='REJECTED')||' recusados, '||count(*) FILTER (WHERE status NOT IN ('RECEIVED','REJECTED'))||' com crédito, '||count(*) FILTER (WHERE status='RECEIVED')||' aguardando' FROM requests WHERE tenant_id='$T'")
  say "$(date +%T)  $R  · used=$(used $T)"
  [[ "$(val requests "SELECT count(*) FROM requests WHERE tenant_id='$T' AND status='RECEIVED'")" == 0 ]] && break
  sleep 2
done

step "Estado depois"
show quota "crédito" "SELECT tenant_id, quota_limit, used FROM tenant_quota WHERE tenant_id='$T'"
show requests "pedidos por status" "SELECT status, count(*) FROM requests WHERE tenant_id='$T' GROUP BY 1 ORDER BY 1"

step "Resultado"
check "todos aceitos com 202"                     '[[ "$(echo "$CODES" | awk '"'"'$2==202{print $1}'"'"')" == "$N" ]]'
check "crédito usado = $LIMIT (nunca passou)"      '[[ "$(used $T)" == "$LIMIT" ]]'
check "exatamente $LIMIT reservas"                 '[[ "$(val quota "SELECT count(*) FROM reservations WHERE tenant_id='"'$T'"'")" == "$LIMIT" ]]'
check "$((N - LIMIT)) pedidos REJECTED"            '[[ "$(val requests "SELECT count(*) FROM requests WHERE tenant_id='"'$T'"' AND status='"'REJECTED'"'")" == "$((N - LIMIT))" ]]'
finish
