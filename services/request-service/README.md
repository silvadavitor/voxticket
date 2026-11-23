# request-service

| | |
|---|---|
| **Linguagem** | C# (.NET 10, ASP.NET Core minimal API) |
| **Responsável** | _a definir_ |
| **Banco** | Postgres próprio (local: container `postgres-request`; AWS: database `requests` no RDS), credenciais no Secrets Manager: `voxticket/<env>/db/request-service` |
| **Fila** | `request-service.q` (DLQ `request-service.dlq`) |

## Responsabilidade

API de entrada (`POST /audios` → 202, `GET /audios/{id}`), upload do áudio ao S3 e **orquestrador da saga** (máquina de estados + rotina de timeout).

## Eventos

- **Consome:** `AudioCategorized`, `AudioTranscribed`, `CreditRejected`, `CreditReserved`, `TicketOpened`, `TicketRejected`, `TranscriptionFailed`
- **Publica:** `AudioReceived`, `CategorizationRequested`, `CreditReleaseRequested`, `RequestFailed`, `TicketRequested`, `TranscriptDiscardRequested`, `TranscriptionRequested`

Schemas em [`contracts/schemas/`](../../contracts/schemas/). Não altere um contrato sem combinar com quem consome.

## API HTTP (contrato em [`contracts/openapi.yaml`](../../contracts/openapi.yaml))

O front e o gateway dependem destes endpoints exatamente assim (o gateway remove o prefixo `/api`):

| Método | Caminho | Resposta |
|---|---|---|
| `POST` | `/audios` (multipart: `tenantId`, `file`) | `202 {requestId, statusUrl}` |
| `GET` | `/audios?tenantId=&limit=` | lista de pedidos, mais novo primeiro |
| `GET` | `/audios/{id}` | `{requestId, tenantId, status, category, priority, ticketId, failureReason, createdAt, updatedAt}` |
| `GET` | `/health` | `{status, service, broker, db}` |

O status é o estado da saga, guardado por este serviço: é ele que responde "em que pé está o pedido" (R3).

## Requisitos que este serviço demonstra

- R3 — API assíncrona (202 + statusUrl)
- Saga/compensação (F1, F7)
- Timeout `SAGA_TIMEOUT_MS`
- S3 claim-check, move para `failed/`

## Checklist obrigatório (vale para todo serviço)

- [x] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/request-service`)
- [x] `GET /health` → `200` com `{"status":"ok","broker":"up|down","db":"up|down"}` — **nunca** derruba o processo se o broker cair (R6)
- [x] Config **só** por variável de ambiente (ver tabela abaixo) — nada fixo no código
- [x] Credenciais do banco lidas do **Secrets Manager** na inicialização (`DB_SECRET_ID`)
- [x] Consumidor idempotente: `processed_messages` + efeito + `outbox` na **mesma transação**, ACK só depois do COMMIT (R1)
- [x] Relay do outbox em background, com publisher confirms, `delivery_mode=2`
- [x] Payload inválido (schema) → `nack` sem requeue infinito (vai para DLQ após 3); erro de infra → retry com backoff (não manda para DLQ)
- [x] Reconexão automática ao broker (R6)
- [x] Logs em JSON com `correlationId`, `messageId`, `type`, `service`
- [x] OpenTelemetry: propagar `traceparent` no header AMQP (ver [`observability/README.md`](../../observability/README.md))
- [x] Migrations do banco rodam no start (tabelas de negócio + `outbox` + `processed_messages`)

## Variáveis de ambiente

| Variável | Exemplo local |
|---|---|
| `SERVICE_NAME` | `request-service` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqp://<NLB do cluster>:5672`, sem credenciais: elas vêm do Secrets Manager) |
| `BROKER_USERNAME` / `BROKER_PASSWORD` | vazios local (credenciais já na URL); na AWS vêm do Secrets Manager e **têm precedência** sobre a URL |
| `BROKER_EXCHANGE` | `events` |
| `BROKER_QUEUE` | `request-service.q` |
| `AWS_ENDPOINT_URL` | `http://ministack:4566` (vazio na AWS real) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | `voxticket-local-audios` |
| `DB_HOST` / `DB_PORT` | `postgres-request` / `5432` |
| `DB_SECRET_ID` | `voxticket/local/db/request-service` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `request-service` |
| `SAGA_TIMEOUT_MS` | `60000` (prazo para a transcrição; vencido ⇒ `EXPIRED`) |
| `MAX_UPLOAD_MB` | `100` |
| `HTTP_PORT` | `8080` |

## Como funciona

| Pasta | O quê |
|---|---|
| `Program.cs` | só monta a aplicação (`AddRequestService`, endpoints) |
| `Api/` | `AudioEndpoints` (`POST /audios`, `GET /audios/{id}`) e `HealthEndpoints` |
| `Saga/` | `RequestSaga` (um handler por evento), `RequestStatus`, `AudioRequest` + `AudioRequestRepository` (todo o SQL de `requests`), `SagaTimeoutWorker` e `CompensationWorker` |
| `Outbox/` | `OutboxWriter` (grava na transação) e `OutboxRelay` (publica com publisher confirms) |
| `Storage/` | `AudioStorage` (S3: upload e mover para `failed/`) |
| `Messaging/` | `Envelope`, `ContractValidator`, `RabbitMqConnection`, `MessageConsumer` (consumidor idempotente) |
| `Persistence/` | `Database`, `DatabaseCredentials` (Secrets Manager), `DatabaseMigrator` |
| `Configuration/`, `Infrastructure/`, `Observability/`, `Hosting/` | variáveis de ambiente, retry/erros transitórios, logs JSON/tracing, registro de serviços e ordem de subida |

`Messaging/`, `Persistence/`, `Configuration/`, `Infrastructure/` e `Observability/` são iguais aos do notification-service
(só muda o namespace); ao alterar um, copie para o outro.

```
POST /audios ─► S3 audios/{tenant}/{id}.ext ─► TX { requests RECEIVED + AudioReceived } ─► 202
CreditReserved      RECEIVED      ─► TRANSCRIBING (deadline = now + SAGA_TIMEOUT_MS) + TranscriptionRequested
CreditRejected      RECEIVED      ─► REJECTED + RequestFailed
AudioTranscribed    TRANSCRIBING  ─► CATEGORIZING + CategorizationRequested
                    EXPIRED       ─► TranscriptDiscardRequested (nunca abre chamado de resultado atrasado)
AudioCategorized    CATEGORIZING  ─► TICKET_REQUESTED + TicketRequested
TicketOpened        TICKET_REQ.   ─► TICKET_OPENED
TranscriptionFailed / TicketRejected ─► COMPENSATING + CreditReleaseRequested + RequestFailed
rotina (2 s): TRANSCRIBING vencido ─► EXPIRED + CreditReleaseRequested + RequestFailed
              COMPENSATING ─► move o áudio para failed/ ─► FAILED
```

- Transição fora de ordem é ignorada (loga e dá ACK). `S3` fora no POST ⇒ `503` e nada é criado.
- Broker fora: a API segue respondendo 202 e o outbox acumula; o relay publica quando o broker volta (F6).
- `GET /audios/{id}` lê direto da tabela `requests` (o bônus de CQRS não foi feito).
- `contracts/` é uma cópia dos schemas usados; `scripts/sync-contracts.sh` sincroniza.
