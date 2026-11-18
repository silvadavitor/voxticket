# ticket-service

| | |
|---|---|
| **Linguagem** | Java (Spring Boot) |
| **Responsável** | _a definir_ |
| **Banco** | Postgres próprio (local: container `postgres-ticket`; AWS: database `ticket` no RDS), credenciais no Secrets Manager: `voxticket/<env>/db/ticket-service` |
| **Fila** | `ticket-service.q` (DLQ `ticket-service.dlq`) |

## Responsabilidade

Abre o chamado, com unicidade por `requestId`. Publica `TicketOpened` (3 interessados).

## Eventos

- **Consome:** `TicketRequested`
- **Publica:** `TicketOpened`, `TicketRejected`

Schemas em [`contracts/schemas/`](../../contracts/schemas/). Não altere um contrato sem combinar com quem consome.

## API HTTP (contrato em [`contracts/openapi.yaml`](../../contracts/openapi.yaml))

Leitura dos chamados para a tela "Chamados" do front (o gateway manda `/api/tickets*` para cá, sem o `/api`):

| Método | Caminho | Resposta |
|---|---|---|
| `GET` | `/tickets?tenantId=&limit=` | `[{ticketId, requestId, tenantId, category, priority, createdAt}]`, mais novo primeiro |
| `GET` | `/tickets/{id}` | um chamado |
| `GET` | `/health` | `{status, service, broker, db}` |

## Requisitos que este serviço demonstra

- Unicidade por `requestId` (UNIQUE)
- Pode recusar → `TicketRejected`

## Checklist obrigatório (vale para todo serviço)

- [ ] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/ticket-service`)
- [ ] `GET /health` → `200` com `{"status":"ok","broker":"up|down","db":"up|down"}` — **nunca** derruba o processo se o broker cair (R6)
- [ ] Config **só** por variável de ambiente (ver tabela abaixo) — nada fixo no código
- [ ] Credenciais do banco lidas do **Secrets Manager** na inicialização (`DB_SECRET_ID`)
- [ ] Consumidor idempotente: `processed_messages` + efeito + `outbox` na **mesma transação**, ACK só depois do COMMIT (R1)
- [ ] Relay do outbox em background, com publisher confirms, `delivery_mode=2`
- [ ] Payload inválido (schema) → `nack` sem requeue infinito (vai para DLQ após 3); erro de infra → retry com backoff (não manda para DLQ)
- [ ] Reconexão automática ao broker (R6)
- [ ] Logs em JSON com `correlationId`, `messageId`, `type`, `service`
- [ ] OpenTelemetry: propagar `traceparent` no header AMQP (ver [`observability/README.md`](../../observability/README.md))
- [ ] Migrations do banco rodam no start (tabelas de negócio + `outbox` + `processed_messages`)

## Variáveis de ambiente

| Variável | Exemplo local |
|---|---|
| `SERVICE_NAME` | `ticket-service` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqps://<host>:5671`, sem credenciais) |
| `BROKER_USERNAME` / `BROKER_PASSWORD` | vazios local (credenciais já na URL); na AWS vêm do Secrets Manager e **têm precedência** sobre a URL |
| `BROKER_EXCHANGE` | `events` |
| `BROKER_QUEUE` | `ticket-service.q` |
| `AWS_ENDPOINT_URL` | `http://ministack:4566` (vazio na AWS real) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | `voxticket-local-audios` |
| `DB_HOST` / `DB_PORT` | `postgres-ticket` / `5432` |
| `DB_SECRET_ID` | `voxticket/local/db/ticket-service` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `ticket-service` |
