# Requisitos

## Tema (registro)

**VoxTicket — Transcritor de Áudio → Categorização → Abertura de Chamados.** Um cliente (empresa) envia um áudio
de suporte; o sistema transcreve, classifica (categoria + prioridade) e abre um chamado.

| Elemento exigido | Onde está |
|---|---|
| Transação distribuída com compensação | Saga: reservar crédito → transcrever → categorizar → abrir chamado. Falha, timeout ou chamado recusado ⇒ crédito devolvido, áudio movido para `failed/`, cliente avisado |
| Dependência lenta/instável | Motor de transcrição (`transcription-worker`), latência e taxa de falha por variável de ambiente |
| Evento com vários interessados | `TicketOpened` → request-service (fecha a saga), quota-service (confirma consumo), notification-service (avisa) |

**Recurso escasso:** créditos de transcrição por cliente (`tenant_quota.quota_limit`).

## Funcionais

| ID | Requisito |
|---|---|
| RF1 | `POST /audios` (multipart: `tenantId`, `file`) grava o áudio no S3 e responde `202 {requestId, statusUrl}` |
| RF2 | `GET /audios/{id}` devolve `status`, `category`, `priority`, `ticketId`, `failureReason` |
| RF3 | Cada cliente tem cota N; sem crédito o pedido termina `REJECTED` |
| RF4 | Transcrição gravada em `s3://<bucket>/transcripts/{requestId}.json` |
| RF5 | Categorização por palavras-chave (ou modelo simples) em categoria + prioridade |
| RF6 | Um chamado por `requestId`, no máximo |
| RF7 | Cliente notificado ao abrir chamado e ao falhar (e-mail simulado: log + tabela) |

## Requisitos de sistemas distribuídos

| # | Requisito | Como cumprimos | Onde |
|---|---|---|---|
| R1 | At-least-once + idempotência | `processed_messages` + efeito + `outbox` na mesma transação; ACK após COMMIT; relay com publisher confirms | todos os consumidores |
| R2 | Concorrência | `UPDATE tenant_quota SET used=used+1 WHERE tenant_id=$1 AND used<quota_limit`; liberação só se `RESERVED` | quota-service |
| R3 | API assíncrona | 202 + polling de status | request-service |
| R4 | Consumidores concorrentes | 3 réplicas na fila `transcription-worker.q`, `prefetch=1` | transcription-worker |
| R5 | Dependência instável | `TRANSCRIBE_LATENCY_MS_MIN/MAX`, `TRANSCRIBE_FAILURE_RATE`, `TRANSCRIBE_MAX_ATTEMPTS` | transcription-worker |
| R6 | Reconexão | .NET `AutomaticRecoveryEnabled`; Spring AMQP; `aio_pika.connect_robust`; `/health` com `broker: down` | todos |

### Ordenação (R4, discutir na apresentação)

A fila entrega em ordem, mas com réplicas e reentregas a ordem global se perde. Não importa aqui: a saga
serializa os passos de cada `requestId`, e a máquina de estados descarta eventos que fariam o estado
regredir. Se fosse preciso ordem por pedido: particionar por `requestId` (consistent-hash exchange).

## Cenários de falha (aceite)

| # | Provocar | Esperado | Evidência (SQL/log) |
|---|---|---|---|
| F1 | `TRANSCRIBE_FAILURE_RATE=1.0` | crédito liberado, áudio em `failed/`, `RequestFailed`, notificação | `used` volta; reserva `RELEASED`; pedido `FAILED`; linha em `notifications` |
| F2 | latência ~8 s, `docker kill` na réplica que logou `processing {id}` | outra réplica processa; efeito único | `count(*) transcriptions where request_id=… = 1`; 2 hostnames nos logs |
| F3 | publicar 5× o mesmo `AudioReceived` (mesmo `messageId`) | só 1 reserva | `used` +1; `processed_messages` 1 linha; 4× `duplicate, skipped` |
| F4 | payload que viola o schema | 3 tentativas → `*.dlq`; os outros seguem | mensagem na DLQ; demais chegam a `TICKET_OPENED` |
| F5 | cota 10, falha 0, 100 POSTs simultâneos | exatamente 10 sucessos | `used=10`; 10 reservas; 90 `REJECTED` |
| F6 | parar o broker 30 s enviando áudios | API segue com 202; outbox drena; nada perdido | `count(*) outbox where sent_at is null` sobe e volta a 0 |
| F7 | latência 20 s, `SAGA_TIMEOUT_MS=10000` | `EXPIRED` + crédito liberado; resultado atrasado `DISCARDED`; 0 tickets | linha do tempo por `correlationId` |
| F8 | `--scale transcription-worker=3`, 30 áudios | carga dividida, sem duplicação | `select processed_by, count(*) from transcriptions group by 1` = 30 |

## Bônus (até +1,0)

| Bônus | Plano | Dono |
|---|---|---|
| OpenTelemetry (tracing ponta a ponta) | SDK OTel nas 3 linguagens, `traceparent` no header AMQP, Collector → Datadog/Jaeger | infra/observabilidade + todos |
| IaC que recria o ambiente | Terraform + Terragrunt (MiniStack e AWS) | infra |
| CQRS | `request_status_view` alimentada por eventos | request-service |
| Versionamento de eventos | `AudioCategorized` v1 e v2 convivendo | categorization-service |
| Autoescala por fila | ECS Service Auto Scaling na métrica de profundidade da fila (AWS) | infra (opcional) |
