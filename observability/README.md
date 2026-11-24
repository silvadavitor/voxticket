# Observabilidade

Traces, métricas e logs de todos os serviços num lugar só: **Grafana** em http://localhost:3000.

```
serviços (SDK OpenTelemetry) ──OTLP :4317──► otel-collector ──OTLP──► lgtm (Grafana + Tempo + Prometheus + Loki)
RabbitMQ (API de management) ── receiver rabbitmq ──┘                  └► dashboard "VoxTicket — Saga" (provisionado)
```

| Sinal | Onde fica | Como ver |
|---|---|---|
| Traces | Tempo | Explore → Tempo → `{resource.service.name="request-service"}` ou pelo requestId: `{span.messaging.message.conversation_id="<id>"}` |
| Métricas | Prometheus | dashboard **VoxTicket — Saga**, ou Explore → Prometheus |
| Logs | Loki | Explore → Loki → `{service_name="quota-service"}`; o `trace_id` do log leva direto ao trace |

```bash
docker compose up -d --build          # sobe tudo (inclui collector e lgtm)
make otel-test   # manda telemetria sintética: valida o pipeline mesmo sem serviço pronto
# Grafana: http://localhost:3000 (dashboards Saga, Serviços, Logs e Traces)
```

O dashboard já mostra a profundidade de cada fila e DLQ (lida direto do RabbitMQ), sem código nenhum
nos serviços. Os outros painéis se preenchem quando os serviços emitirem as métricas da tabela no fim
deste arquivo.

## Como funciona

| Peça | Papel |
|---|---|
| `otel-collector` | recebe OTLP de todos os serviços, lê as filas do RabbitMQ, descarta spans de `/health` (`otel-collector/config.yaml`) |
| `alloy` | lê o **stdout de todos os containers** pelo Docker e manda para o Loki (`alloy/config.alloy`): serviços, RabbitMQ, Postgres, gateway |
| `lgtm` | Grafana + Tempo + Prometheus + Loki, com os dashboards de `grafana/` embutidos |

O Tempo também gera **métricas automáticas a partir dos traces** (`traces_spanmetrics_*`, `traces_service_graph_*`):
requisições, erros e latência por serviço e por operação, com o mesmo nome nas 3 linguagens, como num APM.

**Na AWS:** a mesma imagem `lgtm` e o mesmo collector rodam no ECS. O Grafana fica no ALB em `/grafana`, com
login (usuário `admin`, senha no Secrets Manager em `voxticket/aws/grafana`). Decisão e alternativas no ADR-004.

## O que cada serviço precisa fazer

### 1. Ligar o SDK (a auto-instrumentação faz quase tudo)

As variáveis `OTEL_*` já vêm do `docker-compose.yml` (endpoint, protocolo, propagadores, amostragem,
intervalo de métricas). Não configure nada fixo no código.

| Linguagem | O que instalar | Já instrumenta sozinho |
|---|---|---|
| **.NET** | `OpenTelemetry.Extensions.Hosting`, `OpenTelemetry.Exporter.OpenTelemetryProtocol`, `OpenTelemetry.Instrumentation.AspNetCore`, `OpenTelemetry.Instrumentation.Http`, `Npgsql.OpenTelemetry` | HTTP de entrada e saída, Postgres. **RabbitMQ.Client 7** tem instrumentação nativa: registre `.AddSource("RabbitMQ.Client.*")`, que propaga o `traceparent` no publish e no consume |
| **Java** | agente `opentelemetry-javaagent.jar` no Dockerfile (`JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar`) | Spring MVC, JDBC, **Spring AMQP com propagação**, Logback (logs com trace_id) |
| **Python** | `opentelemetry-distro`, `opentelemetry-exporter-otlp`; rode com `opentelemetry-instrument python ...` e depois `opentelemetry-bootstrap -a install` no build | FastAPI/Flask, asyncpg/psycopg, **aio-pika e pika com propagação**, logging |

.NET, no `Program.cs`:

```csharp
builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(builder.Configuration["SERVICE_NAME"]!))
    .WithTracing(t => t.AddAspNetCoreInstrumentation().AddHttpClientInstrumentation()
                       .AddNpgsql().AddSource("RabbitMQ.Client.*").AddSource("VoxTicket").AddOtlpExporter())
    .WithMetrics(m => m.AddAspNetCoreInstrumentation().AddMeter("VoxTicket").AddOtlpExporter())
    .WithLogging(l => l.AddOtlpExporter());
```

### 2. A única parte manual: `traceparent` no outbox

Com outbox, o publish acontece **depois**, numa thread do relay, e o contexto do trace se perde. A
regra:

1. No mesmo `INSERT INTO outbox`, grave o `traceparent` atual na coluna `outbox.traceparent`.
2. No relay, ao publicar, coloque esse valor no header AMQP `traceparent`.

| Linguagem | Pegar o traceparent atual |
|---|---|
| .NET | `Activity.Current?.Id` (já vem no formato W3C) |
| Java | `Span.current().getSpanContext()` → `"00-" + traceId + "-" + spanId + "-01"` |
| Python | `carrier = {}; opentelemetry.propagate.inject(carrier); carrier.get("traceparent")` |

O consumo já extrai o header sozinho (auto-instrumentação). Se não extrair, use `propagate.extract(headers)`
e abra um span `CONSUMER` com esse contexto.

### 3. Atributos nos spans de mensagem

| Atributo | Valor |
|---|---|
| `messaging.message.id` | `messageId` do envelope |
| `messaging.message.conversation_id` | `correlationId` (= requestId); é por ele que se acha o pedido no Tempo |
| `app.event_type` | `type` do envelope |
| `app.tenant_id` | quando existir |

### 4. Logs

Logue normalmente (ILogger, SLF4J/Logback, logging do Python): a instrumentação manda para o Loki com
`trace_id` e `span_id`. Inclua `correlationId`, `messageId` e `type` como campos estruturados.

## Métricas customizadas (alimentam o dashboard)

Nome no OTel, com o nome correspondente no Prometheus entre parênteses.

| Métrica | Tipo | Quem emite | Quando |
|---|---|---|---|
| `voxticket.saga.completed` (`voxticket_saga_completed_total`) | counter | request-service | pedido chega a `TICKET_OPENED` |
| `voxticket.saga.compensated` (`..._total`, label `reason`) | counter | request-service | entra em `COMPENSATING` |
| `voxticket.credit.reserved` / `.rejected` / `.released` | counter | quota-service | reserva aprovada / sem crédito / devolução |
| `voxticket.transcription.processed` | counter | transcription-worker | transcrição concluída (o `instance` diferencia as réplicas) |
| `voxticket.outbox.pending` | gauge | **todos** que publicam | `count(*) where sent_at is null`, a cada 10 s |

Use um Meter chamado `VoxTicket`.
