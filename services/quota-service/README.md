# quota-service

| | |
|---|---|
| **Linguagem** | Python 3.12 |
| **Responsável** | _a definir_ |
| **Banco** | Postgres próprio (local: container `postgres-quota`; AWS: database `quota` no RDS), credenciais no Secrets Manager: `voxticket/<env>/db/quota-service` |
| **Fila** | `quota-service.q` (DLQ `quota-service.dlq`) |

## Responsabilidade

Créditos por cliente: reservar, consumir, liberar. Recurso escasso do sistema.

## Eventos

- **Consome:** `AudioReceived`, `CreditReleaseRequested`, `TicketOpened`
- **Publica:** `CreditRejected`, `CreditReserved`

Schemas em [`contracts/schemas/`](../../contracts/schemas/). Não altere um contrato sem combinar com quem consome.

## Requisitos que este serviço demonstra

- R2 — reserva atômica `UPDATE ... WHERE used < quota_limit` (F5)
- Liberação só se `RESERVED` (sem devolução dupla)
- F3 — duplicatas descartadas

## Checklist obrigatório (vale para todo serviço)

- [ ] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/quota-service`)
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
| `SERVICE_NAME` | `quota-service` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqps://<host>:5671`, sem credenciais) |
| `BROKER_USERNAME` / `BROKER_PASSWORD` | vazios local (credenciais já na URL); na AWS vêm do Secrets Manager e **têm precedência** sobre a URL |
| `BROKER_EXCHANGE` | `events` |
| `BROKER_QUEUE` | `quota-service.q` |
| `AWS_ENDPOINT_URL` | `http://ministack:4566` (vazio na AWS real) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | `voxticket-local-audios` |
| `DB_HOST` / `DB_PORT` | `postgres-quota` / `5432` |
| `DB_SECRET_ID` | `voxticket/local/db/quota-service` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `quota-service` |


## Implementação (Python)

Stack: Python 3.12, FastAPI (health), aio-pika (RabbitMQ), asyncpg (Postgres), jsonschema, OpenTelemetry.
Arquitetura em camadas (Clean Architecture / POO) - dependências apontam sempre para dentro:

```
app/
  domain/          # Reservation (entidade), eventos, exceções - sem dependências externas
  application/     # ProcessQuotaUseCase + portas (QuotaRepository, ReservationRepository, Outbox, UnitOfWork...)
  infrastructure/  # adapters: Postgres (UoW/repos), RabbitMQ (consumer, outbox relay), config, logs, telemetry
  presentation/    # GET /health
  container.py     # composition root (injeção de dependências)
  main.py          # FastAPI + lifespan
migrations/        # SQL executado no start (tenant_quota, reservations, processed_messages, outbox)
contracts/schemas/ # cópia dos schemas usados (o build do compose usa esta pasta como contexto)
tests/             # testes unitários do caso de uso com fakes em memória
```

Regras:
- `AudioReceived`: reserva 1 crédito atomicamente (`UPDATE ... WHERE used < quota_limit`); se indisponível, publica `CreditRejected`. Pedido repetido com o mesmo `requestId` republica `CreditReserved` com o mesmo `reservationId`.
- `CreditReleaseRequested`: libera 1 crédito apenas se a reserva estiver `RESERVED` (sem devolução dupla).
- `TicketOpened`: marca a reserva `RESERVED` como `CONSUMED`.

```bash
pip install -r requirements.txt pytest && pytest -q
```
