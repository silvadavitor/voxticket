#!/bin/sh
# Idempotente. Env: DB_HOST, DB_PORT, SECRETS_PREFIX (ex.: voxticket/local), SERVICES ("a b c"),
#                   AWS_REGION, AWS_ENDPOINT_URL (só local).
set -eu

get_secret() {
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text
}

MASTER=$(get_secret "$SECRETS_PREFIX/db/master")
export PGHOST="$DB_HOST" PGPORT="${DB_PORT:-5432}" PGDATABASE=postgres
PGUSER=$(echo "$MASTER" | jq -r .username); export PGUSER
PGPASSWORD=$(echo "$MASTER" | jq -r .password); export PGPASSWORD

until pg_isready -q; do echo "aguardando postgres em $PGHOST..."; sleep 2; done

for svc in $SERVICES; do
  S=$(get_secret "$SECRETS_PREFIX/db/$svc")
  U=$(echo "$S" | jq -r .username)
  P=$(echo "$S" | jq -r .password)
  D=$(echo "$S" | jq -r .dbname)
  echo "-> $svc: database=$D user=$U"
  psql -v ON_ERROR_STOP=1 -q -v u="$U" -v p="$P" -v d="$D" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'u', :'p')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'u', :'p') \gexec
SELECT format('GRANT %I TO CURRENT_USER', :'u') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'d', :'u')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'d') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'d') \gexec
SQL
done
echo "db-init concluído"
