# Observabilidade

> Status: **semi-pronto**. O backend Datadog depende da confirmação da conta (ADR-004). Até lá,
> use `OTEL_BACKEND=jaeger`.

```
serviços (SDK OpenTelemetry) ──OTLP gRPC :4317──► otel-collector ──► Datadog   (OTEL_BACKEND=datadog)
                                                         │          └► Jaeger    (OTEL_BACKEND=jaeger, http://localhost:16686)
RabbitMQ management API ─── receiver rabbitmq ───────────┘  (profundidade de filas e DLQs; só no modo datadog)
```

- Local: o container `otel-collector` usa `config.${OTEL_BACKEND}.yaml`.
- AWS: o `otel-collector` roda como serviço ECS com a mesma config (passada por env `OTEL_CONFIG`),
  e fica acessível em `otel-collector.voxticket.internal:4317` via Cloud Map.
- Dashboard e monitores: `infra/modules/datadog`, que só é aplicado se `DD_API_KEY` e `DD_APP_KEY`
  existirem no ambiente.

## O que cada serviço precisa fazer

1. Instalar o SDK OTel da linguagem e ligar a auto-instrumentação (HTTP, Postgres e AMQP, quando houver):
   - .NET: `OpenTelemetry.Extensions.Hosting` + `OpenTelemetry.Exporter.OpenTelemetryProtocol` (+ instrumentações AspNetCore/Http/Npgsql)
   - Java: agente `opentelemetry-javaagent.jar` (`JAVA_TOOL_OPTIONS=-javaagent:...`), que já instrumenta Spring AMQP e JDBC
   - Python: `opentelemetry-distro` + `opentelemetry-exporter-otlp` (`opentelemetry-instrument python ...`); para `aio_pika`, instrumentação `aio-pika`
2. Configurar só por variáveis de ambiente padrão: `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
   `OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=<env>`.
3. **Propagação pelas mensagens:** ao publicar, injetar `traceparent` (W3C) nos headers AMQP. Ao
   consumir, extrair e abrir um span `CONSUMER` filho. Se a auto-instrumentação da linguagem não fizer
   isso, faça à mão (umas 10 linhas). É o que faz um trace atravessar os 6 serviços.
   Com outbox, o publish acontece depois, numa thread do relay: **grave o `traceparent` atual na coluna
   `outbox.traceparent` no mesmo INSERT** e o relay copia essa coluna para o header da mensagem.
4. **Atributos obrigatórios** em todo span de consumo/publicação:

   | Atributo | Valor |
   |---|---|
   | `messaging.message.id` | `messageId` do envelope |
   | `messaging.message.conversation_id` | `correlationId` (= requestId) |
   | `app.event_type` | `type` do envelope |
   | `app.tenant_id` | quando existir |

5. **Logs em JSON** com `correlationId`, `messageId`, `type`, `service`, `trace_id` e `span_id`, para
   correlacionar log com trace no Datadog.

## Métricas customizadas (usadas pelo dashboard e pelos monitores)

| Métrica (OTel) | Tipo | Quem emite | Quando |
|---|---|---|---|
| `voxticket.saga.completed` | counter | request-service | pedido chega a `TICKET_OPENED` |
| `voxticket.saga.compensated` | counter (attr `reason`) | request-service | entra em `COMPENSATING` |
| `voxticket.credit.reserved` | counter | quota-service | reserva aprovada |
| `voxticket.credit.rejected` | counter | quota-service | sem crédito |
| `voxticket.credit.released` | counter | quota-service | compensação devolveu crédito |
| `voxticket.transcription.processed` | counter (attr `host`) | transcription-worker | transcrição concluída |
| `voxticket.outbox.pending` | gauge | **todos** que publicam | `count(*) where sent_at is null`, a cada 10 s |
