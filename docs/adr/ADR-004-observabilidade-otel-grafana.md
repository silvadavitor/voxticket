# ADR-004 — OpenTelemetry + Collector + Grafana (Tempo, Prometheus, Loki)

**Status:** aceito · 19/11/2026

## Contexto
Precisamos de traces, métricas e logs para demonstrar os cenários de falha (F1–F8) e o bônus de
tracing distribuído, e de um lugar só para ver um pedido do front até o fim, como num APM.

## Decisão
- Os serviços usam **só o SDK OpenTelemetry** (nas 3 linguagens) e exportam OTLP para um
  **OTel Collector**. Nenhum SDK de fornecedor no código.
- O collector envia para a stack **Grafana LGTM** (`grafana/otel-lgtm`): **Tempo** (traces),
  **Prometheus** (métricas), **Loki** (logs) e **Grafana**, com os dashboards embutidos na imagem
  (`infra/docker/lgtm.Dockerfile`).
- O collector também lê a **API de management do RabbitMQ** (profundidade das filas e DLQs) e descarta
  os spans de `/health`.
- **Logs de todos os containers** chegam ao Loki pelo **Grafana Alloy**, que lê o stdout via Docker.
  Nenhum serviço precisa exportar log por conta própria.
- O Tempo gera **métricas de RED por serviço** a partir dos traces (spanmetrics e service graph): requisições,
  erros e latência das 3 linguagens com o mesmo nome de métrica, como o APM de um Datadog.
- Propagação W3C `traceparent` em HTTP e nos headers AMQP, inclusive pelo outbox: **um pedido vira um trace
  só**, do front até o notification-service.
- **Na AWS:** a mesma imagem LGTM e o mesmo collector rodam no ECS. O Grafana fica no ALB em
  `/grafana`, com login (senha no Secrets Manager).

## Por quê
- **Mesma experiência local e na AWS**, e tudo em código (Terraform + imagem versionada).
- **Sem conta externa e sem custo de licença.** A demo roda offline.
- **Neutro de fornecedor:** trocar de backend (Datadog, Grafana Cloud, X-Ray) seria só trocar o exporter do
  collector; nenhum serviço muda.

## Alternativas avaliadas
| Opção | Por que não |
|---|---|
| Datadog | depende de conta e licença; sem conta confirmada, a demo ficaria em risco |
| Jaeger | só traces, sem métricas nem logs |
| Amazon Managed Grafana + X-Ray + CloudWatch | exige IAM Identity Center; experiência diferente da local |
| SDK de fornecedor no código | prende os serviços a um fornecedor |
