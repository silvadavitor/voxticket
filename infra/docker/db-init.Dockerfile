# Cria 1 database + 1 usuário por serviço a partir dos segredos (ADR-003). Só AWS (RDS único); local cada serviço tem seu container.
FROM postgres:17-alpine
RUN apk add --no-cache aws-cli jq
COPY infra/scripts/db-init.sh /usr/local/bin/db-init.sh
RUN chmod +x /usr/local/bin/db-init.sh
ENTRYPOINT ["/usr/local/bin/db-init.sh"]
