# ADR-004 — OpenTelemetry + Collector; Grafana LGTM como backend (Datadog opcional)

**Status:** aceito · 18/11/2026 (revisa a versão de 17/11, que tinha Datadog como principal)

## Contexto
Precisamos de traces, métricas e logs para demonstrar os cenários de falha (F1–F8) e o bônus de
tracing distribuído. A conta Datadog e o uso da AWS ainda não estão confirmados, e a demo não pode
depender deles.

## Decisão
- Os serviços usam **só o SDK OpenTelemetry** e exportam OTLP para um **OTel Collector**.
- Backend principal: **`grafana/otel-lgtm`**, que reúne Grafana, Tempo (traces), Prometheus (métricas)
  e Loki (logs) num container. O dashboard *VoxTicket — Saga* vem embutido na imagem
  (`infra/docker/lgtm.Dockerfile`).
- O collector também lê a **API de management do RabbitMQ**: profundidade de cada fila e DLQ aparece
  sem código nos serviços.
- **Datadog** fica como backend alternativo (`OTEL_BACKEND=datadog`), com dashboard e monitores em
  Terraform. Está em standby.
- Propagação W3C `traceparent` nos headers AMQP, inclusive pelo outbox (coluna `outbox.traceparent`).

## Por quê
- **Neutro de fornecedor:** trocar de backend é trocar a config do collector; nenhum serviço muda.
- **Funciona offline e sem conta:** a demo roda inteira na máquina.
- **Os três sinais correlacionados:** do log se pula para o trace pelo `trace_id`, e no trace se acha
  um pedido pelo `requestId`.

## Hospedagem na AWS (quando for liberada)

| Opção | Prós | Contras |
|---|---|---|
| Amazon Managed Grafana + Managed Prometheus + X-Ray + CloudWatch | gerenciado | exige IAM Identity Center; ~US$ 9 por usuário; sem Tempo/Loki, então a experiência fica diferente da local |
| Grafana Cloud (free tier) | grátis, sem operação | conta externa, fora do Terraform |
| **Mesma imagem LGTM no ECS** (escolhida) | **o mesmo Grafana local e na nuvem**, tudo em Terraform | ~US$ 1,20/dia; dados efêmeros (aceitável para a demo) |

## Alternativas descartadas
- **Jaeger:** só traces, sem métricas nem logs.
- **SDK do Datadog no código:** prende os serviços a um fornecedor e quebra a demo sem a conta.
