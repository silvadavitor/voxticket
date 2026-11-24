#!/bin/sh
# Cadastra o cliente da demo se ainda não existir (cliente novo começa sem crédito).
# Roda no docker compose up (container seed); de novo: docker compose run --rm seed
set -eu

API=${API:-http://localhost:8088/api}
TENANT=${DEMO_TENANT:-tenant-demo}
CREDITS=${DEMO_CREDITS:-1000}

i=0
until curl -fsS -o /dev/null "$API/tenants" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -ge 90 ] && { echo "aviso: quota-service não respondeu; rode 'docker compose run --rm seed' depois" >&2; exit 0; }
  sleep 2
done

code=$(curl -s -o /dev/null -w '%{http_code}' "$API/tenants/$TENANT")
case $code in
  200) echo "cliente $TENANT já cadastrado" ;;
  404) curl -fsS -X PUT -H 'Content-Type: application/json' -d "{\"quotaLimit\":$CREDITS}" "$API/tenants/$TENANT" >/dev/null \
         && echo "cliente $TENANT cadastrado com $CREDITS créditos" ;;
  *)   echo "aviso: resposta inesperada ($code); rode 'docker compose run --rm seed' depois" >&2 ;;
esac
