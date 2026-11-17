# ADR-004 — OpenTelemetry com Collector; Datadog como backend (a confirmar)

**Status:** proposto · 17/11/2026. Falta confirmar o acesso à conta Datadog de estudo.

## Decisão
- Os serviços usam **só o SDK OpenTelemetry** (traces, métricas e logs) e exportam OTLP para um
  **OTel Collector**. Ninguém usa SDK ou agente Datadog no código.
- O Collector decide o backend: **Datadog** (exporter `datadog`, chave em `DD_API_KEY`) ou **Jaeger**
  (reserva local, sem conta). A troca é por `OTEL_BACKEND=datadog|jaeger`.
- Propagação W3C `traceparent` no header das mensagens AMQP: um trace atravessa todos os serviços
  (bônus +0,2).
- Dashboards e monitores do Datadog ficam em Terraform (`infra/modules/datadog`), desligados até
  existir `DD_API_KEY`/`DD_APP_KEY`.

## Por quê
- Neutro de fornecedor: se a conta Datadog não estiver disponível no dia, a demo de tracing roda
  com Jaeger trocando uma variável.
- As 3 linguagens têm SDK OTel estável.
- O Datadog dá dashboards, correlação de logs com trace e monitores (DLQ, outbox parado, compensações).

## Convenções
Ver [`observability/README.md`](../../observability/README.md): atributos obrigatórios (`messaging.message.id`,
`app.request_id`, `app.tenant_id`) e métricas customizadas usadas pelos dashboards.
