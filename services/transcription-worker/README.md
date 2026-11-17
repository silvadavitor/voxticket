# transcription-worker

| | |
|---|---|
| **Linguagem** | Python |
| **Responsável** | _a definir_ |
| **Banco** | Postgres próprio (local: container `postgres-transcription`; AWS: database `transcription` no RDS), credenciais no Secrets Manager: `voxticket/<env>/db/transcription-worker` |
| **Fila** | `transcription-worker.q` (DLQ `transcription-worker.dlq`) |

## Responsabilidade

Baixa o áudio do S3 e transcreve. Dependência lenta/instável. Roda com 3 réplicas.

## Eventos

- **Consome:** `TranscriptDiscardRequested`, `TranscriptionRequested`
- **Publica:** `AudioTranscribed`, `TranscriptionFailed`

Schemas em [`contracts/schemas/`](../../contracts/schemas/). Não altere um contrato sem combinar com quem consome.

## Requisitos que este serviço demonstra

- R4 — consumidores concorrentes, `prefetch=1` (F2, F8)
- R5 — `TRANSCRIBE_LATENCY_MS_MIN/MAX`, `TRANSCRIBE_FAILURE_RATE`
- Grava `transcripts/{requestId}.json` (chave determinística)
- Erro de infra ≠ mensagem venenosa (retry com backoff)

## Checklist obrigatório (vale para todo serviço)

- [ ] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/transcription-worker`)
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
| `SERVICE_NAME` | `transcription-worker` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqps://<host>:5671`, sem credenciais) |
| `BROKER_USERNAME` / `BROKER_PASSWORD` | vazios local (credenciais já na URL); na AWS vêm do Secrets Manager e **têm precedência** sobre a URL |
| `BROKER_EXCHANGE` | `events` |
| `BROKER_QUEUE` | `transcription-worker.q` |
| `AWS_ENDPOINT_URL` | `http://ministack:4566` (vazio na AWS real) |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET` | `voxticket-local-audios` |
| `DB_HOST` / `DB_PORT` | `postgres-transcription` / `5432` |
| `DB_SECRET_ID` | `voxticket/local/db/transcription-worker` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` |
| `OTEL_SERVICE_NAME` | `transcription-worker` |
