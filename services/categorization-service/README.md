# categorization-service

| | |
|---|---|
| **Linguagem** | Go |
| **Responsável** | Vitor da Silva |
| **Banco** | Postgres próprio (local: container `postgres-categorization`; AWS: database `categorization` no RDS), credenciais no Secrets Manager: `voxticket/<env>/db/categorization-service` |
| **Fila** | `categorization-service.q` (DLQ `categorization-service.dlq`) |

## Responsabilidade

Classifica o texto em categoria e prioridade (palavras-chave ou modelo simples).

## Eventos

- **Consome:** `CategorizationRequested`
- **Publica:** `AudioCategorized`

Schemas em [`contracts/schemas/`](../../contracts/schemas/). Não altere um contrato sem combinar com quem consome.

## Requisitos que este serviço demonstra

- Bônus: `AudioCategorized` v1 e v2 convivendo

## Checklist obrigatório (vale para todo serviço)

- [ ] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/categorization-service`)
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
| `SERVICE_NAME` | `categorization-service` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqps://<host>:5671`, sem credenciais) |
| `BROKER_USERNAME` / `BROKER_PASSWORD` | vazios local (credenciais já na URL); na AWS vêm do Secrets Manager e **têm precedência** sobre a URL |
| `BROKER_EXCHANGE` | `events` |
| `BROKER_QUEUE` | `categorization-service.q` |
| `AWS_ENDPOINT_URL` | `http://ministack:4566` (vazio na AWS real) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | `voxticket-local-audios` |
| `DB_HOST` / `DB_PORT` | `postgres-categorization` / `5432` |
| `DB_SECRET_ID` | `voxticket/local/db/categorization-service` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `categorization-service` |

## Estrutura do código

```
cmd/categorization/main.go   # sobe tudo: /health, consumidor, relay do outbox; -healthcheck para o Docker
internal/
├── config/       # config só por variável de ambiente
├── awsx/         # S3 + Secrets Manager (MiniStack ou AWS: o SDK lê AWS_ENDPOINT_URL)
├── db/           # Secrets Manager → pool pgx → schema.sql embutido (retry; nunca derruba o processo)
├── broker/       # conexão RabbitMQ com reconexão automática (NotifyClose + backoff) — R6
├── envelope/     # envelope + validação JSON Schema (contratos embutidos, format uuid/date-time)
├── consumer/     # padrão R1: processed_messages + efeito + outbox na mesma transação, ACK após COMMIT
├── outbox/       # relay com publisher confirms + gauge voxticket.outbox.pending
├── classifier/   # palavras-chave → categoria, prioridade, confiança
├── handler/      # CategorizationRequested → lê transcrição no S3 → AudioCategorized
└── telemetry/    # OpenTelemetry: traces, métricas e logs (OTLP) + log JSON no stdout
```

Imagem final: binário estático em `distroless` (~50 MB, sem shell, usuário não-root).

**Formato da transcrição** que este serviço lê em `transcripts/{requestId}.json` (combinar com o
transcription-worker): `{"requestId": "...", "text": "..."}`.

## Rodando

```bash
# testes unitários (precisa Go ≥ 1.27; ou pelo container abaixo)
go test ./...
docker run --rm -v "$PWD":/src -w /src golang:1.27.3-alpine go test ./...

# no compose, com as dependências (MiniStack, RabbitMQ, Postgres próprio)
make svc s=categorization-service
curl localhost:8083/health

# teste de integração: caminho feliz, duplicada 5x (F3), payload inválido → DLQ (F4)
scripts/dev/test-categorization.sh
```

Se mudar um contrato em `contracts/`, rode `scripts/sync-contracts.sh` (o teste `TestContratosEmDia`
falha enquanto a cópia estiver desatualizada).

Verificado em 18/11 no compose:
- os 9 testes de integração passam;
- com o RabbitMQ derrubado e religado, o `/health` mostra `broker: down`, o serviço não cai e
  reconecta e volta a consumir sozinho (R6).
