# notification-service

| | |
|---|---|
| **Linguagem** | C# (.NET 10) |
| **Responsável** | _a definir_ |
| **Banco** | Postgres próprio (local: container `postgres-notification`; AWS: database `notification` no RDS), credenciais no Secrets Manager: `voxticket/<env>/db/notification-service` |
| **Fila** | `notification-service.q` (DLQ `notification-service.dlq`) |

## Responsabilidade

Avisa o cliente (e-mail simulado: log + tabela `notifications`).

## Eventos

- **Consome:** `RequestFailed`, `TicketOpened`
- **Publica:** —

Schemas em [`contracts/schemas/`](../../contracts/schemas/). Não altere um contrato sem combinar com quem consome.

## Requisitos que este serviço demonstra

- Consome `TicketOpened` e `RequestFailed`

## Checklist obrigatório (vale para todo serviço)

- [x] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/notification-service`)
- [x] `GET /health` → `200` com `{"status":"ok","broker":"up|down","db":"up|down"}` — **nunca** derruba o processo se o broker cair (R6)
- [x] Config **só** por variável de ambiente (ver tabela abaixo) — nada fixo no código
- [x] Credenciais do banco lidas do **Secrets Manager** na inicialização (`DB_SECRET_ID`)
- [x] Consumidor idempotente: `processed_messages` + efeito + `outbox` na **mesma transação**, ACK só depois do COMMIT (R1)
- [x] Relay do outbox: não se aplica, o serviço não publica eventos
- [x] Payload inválido (schema) → `nack` sem requeue infinito (vai para DLQ após 3); erro de infra → retry com backoff (não manda para DLQ)
- [x] Reconexão automática ao broker (R6)
- [x] Logs em JSON com `correlationId`, `messageId`, `type`, `service`
- [x] OpenTelemetry: propagar `traceparent` no header AMQP (ver [`observability/README.md`](../../observability/README.md))
- [x] Migrations do banco rodam no start (tabelas de negócio + `outbox` + `processed_messages`)

## Variáveis de ambiente

| Variável | Exemplo local |
|---|---|
| `SERVICE_NAME` | `notification-service` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqps://<host>:5671`, sem credenciais) |
| `BROKER_USERNAME` / `BROKER_PASSWORD` | vazios local (credenciais já na URL); na AWS vêm do Secrets Manager e **têm precedência** sobre a URL |
| `BROKER_EXCHANGE` | `events` |
| `BROKER_QUEUE` | `notification-service.q` |
| `AWS_ENDPOINT_URL` | `http://ministack:4566` (vazio na AWS real) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | `voxticket-local-audios` |
| `DB_HOST` / `DB_PORT` | `postgres-notification` / `5432` |
| `DB_SECRET_ID` | `voxticket/local/db/notification-service` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `notification-service` |
| `HTTP_PORT` | `8080` |

## Como funciona

- `TicketOpened` ⇒ "Seu chamado X foi aberto."; `RequestFailed` ⇒ "Seu pedido terminou como STATUS: motivo."
- O "e-mail" é simulado: log `e-mail (simulado) para <tenant>` + linha em `notifications` (uma por pedido e tipo).
- `Notifications/`: `NotificationHandlers` (os dois eventos) e `NotificationRepository`.
- `Messaging/`, `Persistence/`, `Configuration/`, `Infrastructure/` e `Observability/` são iguais aos do request-service (só muda o namespace).
- `contracts/` é uma cópia dos schemas usados; `scripts/sync-contracts.sh` sincroniza.
