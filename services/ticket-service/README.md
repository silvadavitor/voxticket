# ticket-service

| | |
|---|---|
| **Linguagem** | Python 3.12 |
| **ResponsÃ¡vel** | _a definir_ |
| **Banco** | Postgres prÃ³prio (local: container `postgres-ticket`; AWS: database `ticket` no RDS), credenciais no Secrets Manager: `voxticket/<env>/db/ticket-service` |
| **Fila** | `ticket-service.q` (DLQ `ticket-service.dlq`) |

## Responsabilidade

Abre o chamado, com unicidade por `requestId`. Publica `TicketOpened` (3 interessados).

## Eventos

- **Consome:** `TicketRequested`
- **Publica:** `TicketOpened`, `TicketRejected`

Schemas em [`contracts/schemas/`](../../contracts/schemas/). NÃ£o altere um contrato sem combinar com quem consome.

## API HTTP (contrato em [`contracts/openapi.yaml`](../../contracts/openapi.yaml))

Leitura dos chamados para a tela "Chamados" do front (o gateway manda `/api/tickets*` para cá, sem o `/api`):

| Método | Caminho | Resposta |
|---|---|---|
| `GET` | `/tickets?tenantId=&limit=` | `[{ticketId, requestId, tenantId, category, priority, createdAt}]`, mais novo primeiro |
| `GET` | `/tickets/{id}` | um chamado |
| `GET` | `/health` | `{status, service, broker, db}` |

## Requisitos que este serviço demonstra

- Unicidade por `requestId` (UNIQUE)
- Pode recusar â†’ `TicketRejected`

## Checklist obrigatÃ³rio (vale para todo serviÃ§o)

- [ ] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/ticket-service`)
- [ ] `GET /health` â†’ `200` com `{"status":"ok","broker":"up|down","db":"up|down"}` â€” **nunca** derruba o processo se o broker cair (R6)
- [ ] Config **sÃ³** por variÃ¡vel de ambiente (ver tabela abaixo) â€” nada fixo no cÃ³digo
- [ ] Credenciais do banco lidas do **Secrets Manager** na inicializaÃ§Ã£o (`DB_SECRET_ID`)
- [ ] Consumidor idempotente: `processed_messages` + efeito + `outbox` na **mesma transaÃ§Ã£o**, ACK sÃ³ depois do COMMIT (R1)
- [ ] Relay do outbox em background, com publisher confirms, `delivery_mode=2`
- [ ] Payload invÃ¡lido (schema) â†’ `nack` sem requeue infinito (vai para DLQ apÃ³s 3); erro de infra â†’ retry com backoff (nÃ£o manda para DLQ)
- [ ] ReconexÃ£o automÃ¡tica ao broker (R6)
- [ ] Logs em JSON com `correlationId`, `messageId`, `type`, `service`
- [ ] OpenTelemetry: propagar `traceparent` no header AMQP (ver [`observability/README.md`](../../observability/README.md))
- [ ] Migrations do banco rodam no start (tabelas de negÃ³cio + `outbox` + `processed_messages`)

## VariÃ¡veis de ambiente

| VariÃ¡vel | Exemplo local |
|---|---|
| `SERVICE_NAME` | `ticket-service` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqps://<host>:5671`, sem credenciais) |
| `BROKER_USERNAME` / `BROKER_PASSWORD` | vazios local (credenciais jÃ¡ na URL); na AWS vÃªm do Secrets Manager e **tÃªm precedÃªncia** sobre a URL |
| `BROKER_EXCHANGE` | `events` |
| `BROKER_QUEUE` | `ticket-service.q` |
| `AWS_ENDPOINT_URL` | `http://ministack:4566` (vazio na AWS real) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | `voxticket-local-audios` |
| `DB_HOST` / `DB_PORT` | `postgres-ticket` / `5432` |
| `DB_SECRET_ID` | `voxticket/local/db/ticket-service` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `ticket-service` |


## Implementação (Python)

Stack: Python 3.12, FastAPI (health), aio-pika (RabbitMQ), asyncpg (Postgres), jsonschema, OpenTelemetry.
Arquitetura em camadas (Clean Architecture / POO) - dependências apontam sempre para dentro:

```
app/
  domain/          # Ticket (entidade), TicketOpeningPolicy, eventos, exceções - sem dependências externas
  application/     # OpenTicketUseCase + portas (TicketRepository, Outbox, UnitOfWork...)
  infrastructure/  # adapters: Postgres (UoW/repos), RabbitMQ (consumer, outbox relay), config, logs
  presentation/    # GET /health
  container.py     # composition root (injeção de dependências)
  main.py          # FastAPI + lifespan
migrations/        # SQL executado no start (tickets UNIQUE(request_id), processed_messages, outbox)
contracts/schemas/ # cópia dos schemas usados (o build do compose usa esta pasta como contexto)
tests/             # testes unitários do caso de uso com fakes em memória
```

Regras de recusa (`TicketRejected`): tenantId/categoria vazios ou categoria fora de
`TICKET_ALLOWED_CATEGORIES` (opcional, lista separada por vírgula; vazio = aceita qualquer).
Pedido repetido com o mesmo `requestId` não cria novo chamado: republica `TicketOpened` com o mesmo `ticketId`.

```bash
pip install -r requirements.txt pytest && pytest -q
```