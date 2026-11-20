#!/usr/bin/env bash
# Cadastra o cliente da demonstração (o mesmo que o front usa por padrão) pela API do quota-service.
# Cliente novo começa com limite 0: sem isso, o primeiro áudio da demo sairia REJECTED.
# Só cadastra se ainda não existir: não mexe no limite nem no uso de quem já está lá.
set -euo pipefail

API=${API:-http://localhost:8088/api}
TENANT=${DEMO_TENANT:-tenant-demo}
CREDITS=${DEMO_CREDITS:-1000}

for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "$API/tenants" 2>/dev/null && break
  sleep 2
done

code=$(curl -s -o /dev/null -w '%{http_code}' "$API/tenants/$TENANT")
case $code in
  200) echo "cliente $TENANT já cadastrado" ;;
  404) curl -fsS -X PUT -H 'Content-Type: application/json' -d "{\"quotaLimit\":$CREDITS}" "$API/tenants/$TENANT" >/dev/null \
         && echo "cliente $TENANT cadastrado com $CREDITS créditos" ;;
  *)   echo "aviso: quota-service não respondeu ($code); rode 'make seed' depois" >&2 ;;
esac
