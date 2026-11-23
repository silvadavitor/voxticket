# Arquitetura

## Diagrama

```
                         Cliente
            POST /audios → 202 {id}    GET /audios/{id}
                            │
                  ┌─────────▼─────────┐   put / move    ┌──────────────────────┐
                  │  request-service  │────────────────►│ S3 (audios/,         │◄── get áudio / put transcrição
                  │  C# · saga        │                 │ transcripts/,failed/)│               │
                  └─────────┬─────────┘                 └──────────────────────┘               │
                            │ outbox                                                           │
 ═══════════════════════════╪══════════ RabbitMQ (exchange `events`) ══════════════════════════╪═══
        │                   │                │                   │                             │
  quota-service      ticket-service   categorization-svc   notification-svc        transcription-worker ×3
    Python              Python               Go                  C#                        Python
   [Postgres]          [Postgres]        [Postgres]          [Postgres]                 [Postgres]
                       (request-service também tem o seu Postgres)

  Banco por serviço. Local: 1 container Postgres por serviço. AWS: 1 RDS com 1 database + 1 usuário
  isolado por serviço (custo — ADR-003).
  Todos leem credenciais do Secrets Manager na inicialização. Traces/métricas/logs → OTel Collector → Grafana (Tempo, Prometheus, Loki).
```

## Serviços

| Serviço | Linguagem | Responsabilidade | Database |
|---|---|---|---|
| request-service | C# (ASP.NET Core) | API (202 + status), upload S3, **orquestrador da saga** (estados + timeout) | `requests` |
| quota-service | Python | créditos: reservar / consumir / liberar (R2) | `quota` |
| transcription-worker | Python | baixa áudio do S3 e transcreve; 3 réplicas (R4, R5) | `transcription` |
| categorization-service | Go | categoria + prioridade | `categorization` |
| ticket-service | Python | abre chamado, único por `requestId` | `ticket` |
| notification-service | C# | e-mail simulado (log + tabela) | `notification` |

Todo database tem também `outbox` e `processed_messages`.

## APIs HTTP e gateway

Contrato em [`contracts/openapi.yaml`](../contracts/openapi.yaml). O cliente (front) fala com **um endereço só**, e o
gateway roteia por caminho:

| Caminho | Serviço | Local | AWS |
|---|---|---|---|
| `/` (site) | S3 | nginx (`frontend`) → S3 do MiniStack | CloudFront → S3 privado |
| `/api/audios*` | request-service | nginx | CloudFront → ALB (regra padrão) |
| `/api/tickets*` | ticket-service | nginx | CloudFront → ALB (regra `/tickets*`) |

Cada serviço expõe só os **dados que são dele**: o request-service, o estado da saga; o ticket-service,
os chamados. Ninguém lê o banco de outro.

## Saga (orquestrada pelo request-service)

```
RECEIVED ──CreditReserved──► TRANSCRIBING ──AudioTranscribed──► CATEGORIZING ──AudioCategorized──► TICKET_REQUESTED ──TicketOpened──► TICKET_OPENED
   │                              │    │                                                                │
   └─CreditRejected─► REJECTED    │    └─timeout (SAGA_TIMEOUT_MS)─► EXPIRED ──(AudioTranscribed atrasado)─► publica TranscriptDiscardRequested
                                  │                                    │
                                  └─TranscriptionFailed─┐              │
                                         TicketRejected─┼──────────────┘
                                                        ▼
                                                  COMPENSATING ──► FAILED   (EXPIRED permanece EXPIRED após compensar)
                                       publica: CreditReleaseRequested, move áudio p/ failed/, RequestFailed
```

1. `POST /audios`: grava o áudio em `audios/{tenant}/{requestId}.ogg`. O pedido fica `RECEIVED` e o
   `AudioReceived` vai para o outbox, na mesma transação. A resposta é **202**.
2. O quota-service publica `CreditReserved` ou `CreditRejected`.
3. Com o crédito reservado, o estado vira `TRANSCRIBING`, o `deadline` é gravado e o request-service
   publica `TranscriptionRequested`.
4. O worker publica `AudioTranscribed` ou, depois de N tentativas, `TranscriptionFailed`.
5. Quando chega `AudioTranscribed`: se o estado é `TRANSCRIBING`, o request-service publica
   `CategorizationRequested`. Se já está `EXPIRED`, publica `TranscriptDiscardRequested` (F7).
6. Quando chega `AudioCategorized`, o request-service publica `TicketRequested`.
7. O ticket-service publica `TicketOpened`, consumido pelos 3 interessados. O quota-service muda a
   reserva para `CONSUMED`.
8. **Compensação:** publica `CreditReleaseRequested`, move o áudio para `failed/` e publica `RequestFailed`.

Regra da máquina de estados: um evento que faria o estado regredir é **descartado** (logado e com ACK).

**Claim-check:** as mensagens levam só a chave do S3, nunca o arquivo.

## Mensageria

Exchange topic `events` (routing key = nome do evento), uma fila quorum por serviço consumidor
(`x-delivery-limit=3`) e DLX `events.dlx` → `<servico>.dlq`. Topologia completa em
[`rabbitmq/definitions.json`](../rabbitmq/definitions.json).

| Evento | Produtor | Consumidores |
|---|---|---|
| AudioReceived | request | quota |
| CreditReserved / CreditRejected | quota | request |
| TranscriptionRequested | request | transcription-worker |
| AudioTranscribed / TranscriptionFailed | transcription-worker | request |
| TranscriptDiscardRequested | request | transcription-worker |
| CategorizationRequested | request | categorization |
| AudioCategorized | categorization | request |
| TicketRequested | request | ticket |
| **TicketOpened** | ticket | **request, quota, notification** |
| TicketRejected | ticket | request |
| CreditReleaseRequested | request | quota |
| RequestFailed | request | notification |

## Padrões comuns (todas as linguagens)

```sql
BEGIN;
INSERT INTO processed_messages(message_id) VALUES ($1) ON CONFLICT DO NOTHING;
-- 0 linhas → duplicata: COMMIT, ACK, log "duplicate, skipped"
-- efeito de negócio
-- INSERT INTO outbox(id, type, payload, created_at) ...
COMMIT;   -- só então ACK
```

```sql
CREATE TABLE processed_messages (message_id uuid PRIMARY KEY, processed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE outbox (
  id uuid PRIMARY KEY, type text NOT NULL, correlation_id uuid NOT NULL,
  envelope jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), sent_at timestamptz,
  traceparent text  -- W3C do span que gerou o evento; o relay publica no header AMQP
);
CREATE INDEX outbox_pending ON outbox (created_at) WHERE sent_at IS NULL;
```

O relay do outbox é uma thread em background que lê pendentes (`FOR UPDATE SKIP LOCKED`), publica
com publisher confirms e `delivery_mode=2` e só então preenche `sent_at`.

Tratamento de erro:
- **Payload inválido** (falha no schema): `nack` com requeue. Depois de 3 entregas a mensagem vai
  para a DLQ.
- **Infraestrutura fora** (banco, S3): retry interno com backoff, segurando a mensagem. Ela **não**
  vai para a DLQ.

## Nuvem

| Categoria | Local (MiniStack) | AWS (entrega) | Por quê → [ADRs](adr/) |
|---|---|---|---|
| Armazenamento de objetos | S3 (MiniStack) | S3 | ADR-001 |
| Segredos | Secrets Manager (MiniStack) | Secrets Manager | ADR-001 |
| Mensageria | RabbitMQ (container) | RabbitMQ em cluster: 3 EC2, uma por zona, NLB interno | ADR-002 |
| Banco de dados | 1 Postgres (container) por serviço | RDS Postgres (database + usuário por serviço) | ADR-003 |
| Computação | docker compose | ECS Fargate | ADR-001 |
| Front estático + CDN | S3 (MiniStack) + nginx simulando o CloudFront | S3 privado + CloudFront (HTTPS, `/api/*` → ALB) | ADR-005 |
| Observabilidade | OTel Collector → Grafana LGTM (Tempo, Prometheus, Loki) | mesma stack LGTM no ECS, Grafana no ALB em `/grafana` | ADR-004 |
