# Operations

## Ambientes

| | local | aws |
|---|---|---|
| Infra | `make up` (o `infra-init` roda Terragrunt em `infra/live/ministack`) | GitHub Actions: `infra-up` / `deploy` / `infra-destroy` |
| Serviços | containers do compose | ECS Fargate (imagens no ECR) |
| Broker | container RabbitMQ | Amazon MQ |
| Banco | 1 container Postgres por serviço | RDS (database + usuário por serviço) |

Passo a passo do deploy AWS: [`infra/README.md`](../infra/README.md).

## Runbook da apresentação

1. `docker compose ps`: todos `healthy`.
2. Abrir: painel do RabbitMQ, Grafana (`make grafana`: dashboard da saga, traces e logs) e um terminal com `psql`.
3. O professor escolhe o cenário: `scripts/failures/F<n>.sh`, depois as consultas de
   `scripts/failures/sql/F<n>.sql`.

## Falha surpresa — previsões

| Derrubar | O que acontece |
|---|---|
| uma réplica do request-service | A outra segue: o gateway manda as requisições para ela e ela consome a fila sozinha |
| as 2 réplicas do request-service | API fora (sem 202). Eventos acumulam em `request-service.q`. Ao voltar, consome tudo e a rotina de timeout trata o que expirou |
| quota-service | Pedidos ficam em `RECEIVED`. Ao voltar, processa; nada se perde |
| ticket-service | Pedidos ficam em `TICKET_REQUESTED` até ele voltar, ou expiram e compensam |
| notification-service | Só atrasa os avisos |
| transcription-worker (todas as réplicas) | Pedidos ficam em `TRANSCRIBING`; o timeout expira e compensa |
| Postgres de um serviço (`docker compose stop postgres-quota`) | Só aquele serviço fica unhealthy e não dá ACK; as mensagens dele esperam na fila. Os outros seguem. Se for o `postgres-request`, a API responde 503 |
| MiniStack (S3) | O `POST` responde 503 (falha rápida). O worker faz retry com backoff, sem DLQ |
| RabbitMQ | F6: a API continua com 202 via outbox, os consumidores reconectam e o outbox drena |
