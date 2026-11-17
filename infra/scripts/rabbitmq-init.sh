#!/bin/sh
# Env: BROKER_MGMT_URL (http://rabbitmq:15672 | https://b-xxx.mq.<region>.amazonaws.com),
#      BROKER_USERNAME, BROKER_PASSWORD
set -eu
AUTH="$BROKER_USERNAME:$BROKER_PASSWORD"

until curl -fsS -u "$AUTH" "$BROKER_MGMT_URL/api/overview" >/dev/null 2>&1; do
  echo "aguardando broker em $BROKER_MGMT_URL..."
  sleep 3
done

curl -fsS -u "$AUTH" -H "content-type: application/json" \
  -X POST --data @/definitions.json "$BROKER_MGMT_URL/api/definitions"
echo "topologia aplicada (exchanges, filas quorum, DLQs)"
