#!/usr/bin/env bash
# F8 — Escala horizontal: 3 réplicas do worker, 30 áudios. Esperado: carga dividida, sem duplicação.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F8 escala horizontal"
N=${N:-30}
T=$(new_tenant f8); set_quota "$T" 100

log "garantindo 3 réplicas do transcription-worker"
$COMPOSE up -d --scale transcription-worker=3 transcription-worker >/dev/null 2>&1
check "3 consumidores na mesma fila"              'until_ok 60 "[[ \$(consumers transcription-worker.q) == 3 ]]"'

log "enviando $N áudios"
for _ in $(seq "$N"); do post_audio "$T" >/dev/null; done
until_ok 300 '[[ "$(val requests "SELECT count(*) FROM requests WHERE tenant_id='"'$T'"' AND status IN ('"'TICKET_OPENED'"','"'FAILED'"')")" == "$N" ]]' || true

# os pedidos deste teste (ficam no banco do request-service) → filtro para o banco do worker
IDS=$(val requests "SELECT string_agg(quote_literal(id::text), ',') FROM requests WHERE tenant_id='$T'")
TOTAL=$(val transcription "SELECT count(*) FROM transcriptions WHERE request_id::text IN ($IDS)")
DISTINCT=$(val transcription "SELECT count(DISTINCT request_id) FROM transcriptions WHERE request_id::text IN ($IDS)")
REPLICAS=$(val transcription "SELECT count(DISTINCT processed_by) FROM transcriptions WHERE request_id::text IN ($IDS)")
check "$N transcrições"                           '[[ "$TOTAL" == "$N" ]]'
check "nenhuma duplicada"                         '[[ "$DISTINCT" == "$TOTAL" ]]'
check "trabalho dividido entre as réplicas"       '[[ "$REPLICAS" -ge 2 ]]'
q transcription "SELECT processed_by AS replica, count(*) FROM transcriptions WHERE request_id::text IN ($IDS) GROUP BY 1 ORDER BY 1"
finish
