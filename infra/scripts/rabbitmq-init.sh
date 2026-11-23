#!/bin/sh
# Env: BROKER_MGMT_URL (local: http://rabbitmq:15672 · AWS: http://<ip privado da EC2>:15672),
#      BROKER_USERNAME, BROKER_PASSWORD, EXPECTED_NODES (opcional, padrão 1)
set -eu
AUTH="$BROKER_USERNAME:$BROKER_PASSWORD"

until curl -fsS -u "$AUTH" "$BROKER_MGMT_URL/api/overview" >/dev/null 2>&1; do
  echo "aguardando broker em $BROKER_MGMT_URL..."
  sleep 3
done

# Cluster: espera todos os nós antes de criar as filas, senão a fila quorum nasce com menos réplicas
EXPECTED=${EXPECTED_NODES:-1}
until [ "$(curl -fsS -u "$AUTH" "$BROKER_MGMT_URL/api/nodes" 2>/dev/null | grep -o '"running":true' | wc -l)" -ge "$EXPECTED" ]; do
  echo "aguardando $EXPECTED nós no cluster..."
  sleep 5
done

curl -fsS -u "$AUTH" -H "content-type: application/json" \
  -X POST --data @/definitions.json "$BROKER_MGMT_URL/api/definitions"
echo "topologia aplicada (exchanges, filas quorum, DLQs)"
