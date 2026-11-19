#!/usr/bin/env bash
# F8 — Escala horizontal: 3 réplicas do worker, 30 áudios. Esperado: carga dividida, sem duplicação.
source "$(dirname "$0")/lib/common.sh"
SCENARIO="F8 escala horizontal"
N=${N:-30}
T=$(new_tenant f8); set_quota "$T" 100

step "Subindo 3 réplicas do transcription-worker (docker compose up --scale transcription-worker=3)"
$COMPOSE up -d --scale transcription-worker=3 transcription-worker >/dev/null 2>&1
until_ok 60 '[[ $(consumers transcription-worker.q) == 3 ]]' || true
say "réplicas: $($COMPOSE ps --format '{{.Name}}' transcription-worker | tr '\n' ' ')"
say "consumidores na fila transcription-worker.q: $(consumers transcription-worker.q)"
queue_link transcription-worker.q

step "Enviando $N áudios"
for i in $(seq "$N"); do post_audio "$T" >/dev/null; printf '\r   enviados: %d/%d' "$i" "$N"; done; echo

step "Acompanhando a divisão do trabalho entre as réplicas"
for _ in $(seq 100); do
  DONE=$(val requests "SELECT count(*) FROM requests WHERE tenant_id='$T' AND status IN ('TICKET_OPENED','FAILED')")
  say "$(date +%T) concluídos: $DONE/$N · fila: $(depth transcription-worker.q)"
  [[ "$DONE" == "$N" ]] && break
  sleep 3
done

IDS=$(val requests "SELECT string_agg(quote_literal(id::text), ',') FROM requests WHERE tenant_id='$T'")
step "Quantas transcrições cada réplica fez"
show transcription "por réplica" "SELECT processed_by AS replica, count(*) FROM transcriptions WHERE request_id::text IN ($IDS) GROUP BY 1 ORDER BY 1"

TOTAL=$(val transcription "SELECT count(*) FROM transcriptions WHERE request_id::text IN ($IDS)")
DISTINCT=$(val transcription "SELECT count(DISTINCT request_id) FROM transcriptions WHERE request_id::text IN ($IDS)")
REPLICAS=$(val transcription "SELECT count(DISTINCT processed_by) FROM transcriptions WHERE request_id::text IN ($IDS)")
step "Resultado"
check "3 consumidores na mesma fila"              '[[ $(consumers transcription-worker.q) == 3 ]]'
check "$N transcrições"                           '[[ "$TOTAL" == "$N" ]]'
check "nenhuma duplicada"                         '[[ "$DISTINCT" == "$TOTAL" ]]'
check "trabalho dividido entre as réplicas"       '[[ "$REPLICAS" -ge 2 ]]'
finish
