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
- R5 — Whisper é a dependência lenta; `TRANSCRIBE_LATENCY_MS_MIN/MAX` e `TRANSCRIBE_FAILURE_RATE` injetam lentidão e falhas
- Grava `transcripts/{requestId}.json` (chave determinística)
- Erro de infra ≠ mensagem venenosa (retry com backoff)

## Checklist obrigatório (vale para todo serviço)

- [x] `Dockerfile` nesta pasta (o `docker-compose.yml` faz `build: ./services/transcription-worker`)
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
| `SERVICE_NAME` | `transcription-worker` |
| `BROKER_URL` | `amqp://guest:guest@rabbitmq:5672/` (AWS: `amqp://<NLB do cluster>:5672`, sem credenciais: elas vêm do Secrets Manager) |
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
| `WHISPER_MODEL` | `base` (build arg: o modelo é embutido na imagem; `tiny`, `base`, `small`, `medium`) |
| `WHISPER_LANGUAGE` | `pt` (`auto` = o Whisper detecta o idioma) |
| `TRANSCRIBE_MAX_ATTEMPTS` | `3` (tentativas antes de publicar `TranscriptionFailed`) |
| `TRANSCRIBE_LATENCY_MS_MIN` / `TRANSCRIBE_LATENCY_MS_MAX` | `0` / `0` (latência extra **injetada**, para F2 e F7) |
| `TRANSCRIBE_FAILURE_RATE` | `0` (0.0–1.0, falha **injetada** por tentativa, para F1) |
| `HTTP_PORT` | `8080` (`/health`) |
| `LOG_LEVEL` | `INFO` |
| `OUTBOX_POLL_MS` | `500` |

## Como funciona

A transcrição é **real**: [faster-whisper](https://github.com/SYSTRAN/faster-whisper) na CPU (int8), com o
modelo embutido na imagem no build. Aceita qualquer formato que o ffmpeg leia (`.mp4`, `.ogg`, `.mp3`, `.wav`…).
Para os cenários de falha dá para injetar latência extra e taxa de falha por variável de ambiente; com
os valores padrão (0) roda só o Whisper.

```
TranscriptionRequested ─► messageId ou requestId já processado? ──sim──► ACK ("duplicate, skipped")
                          │ não ─ log "processing <requestId>"
                          ▼
                          lê o áudio do S3 (claim-check)      S3/banco fora ⇒ retry segurando a msg
                          ▼
                          Whisper: até N tentativas (áudio inválido ou falha ⇒ nova tentativa)
                          ├─ ok     ► PUT transcripts/{requestId}.json ► TX { processed_messages + TRANSCRIBED + AudioTranscribed no outbox } ► ACK
                          └─ falhou ► TX { processed_messages + FAILED + TranscriptionFailed no outbox } ► ACK

TranscriptDiscardRequested ─► DELETE transcripts/{requestId}.json ► TX { processed_messages + DISCARDED } ► ACK
```

- Sem transação aberta durante a transcrição; se a réplica morrer no meio (F2), nada foi gravado e a
  mensagem volta para outra réplica.
- Efeito único: `processed_messages` (mesmo `messageId`) + `transcriptions.request_id` como PK.
- `AudioTranscribed` leva só `transcriptKey` (claim-check); o texto fica em `transcripts/{requestId}.json`.
- Áudio inexistente ⇒ `TranscriptionFailed {reason: AUDIO_NOT_FOUND}`.
- `processed_by = hostname` (F8). Métricas: `voxticket.transcription.processed` e `voxticket.outbox.pending`.

## Estrutura

| Pasta | O quê |
|---|---|
| `transcription_worker/` | regra de negócio: `handlers`, `transcriber` (Whisper), `storage` (S3), `settings`, `__main__` |
| `transcription_worker/infra/` | padrões distribuídos: consumidor, outbox, broker, banco, envelope, retry, segredos, health, logs, OTel |
| `contracts/` | cópia dos schemas que o serviço usa (`scripts/sync-contracts.sh` sincroniza com `contracts/schemas` do repo; um teste falha se divergirem) |
| `migrations/` | tabela `transcriptions` (`outbox` e `processed_messages` são criadas pela `infra/db.py`) |

**Integração com o categorization-service:** o único contrato direto é o arquivo
`transcripts/{requestId}.json`, do qual ele lê `requestId` e `text`. Não renomeie esses campos sem
combinar. Testado de ponta a ponta em 18/11/2026: 10/10 pedidos transcritos e categorizados, sem DLQ.

## Rodar e testar

```bash
docker compose up -d --build transcription-worker   # 3 réplicas, cada uma numa porta livre de 8090-8099
docker compose port --index 1 transcription-worker 8080   # qual porta a 1ª réplica pegou
curl localhost:$(docker compose port --index 1 transcription-worker 8080 | cut -d: -f2)/health
```

Testes unitários (sem Docker):

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest
```

Cenários que exercitam este serviço: `make f1` (falha 100%), `make f2` (kill da réplica), `make f7`
(resultado atrasado), `make f8` (divisão de carga).
