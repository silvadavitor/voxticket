# Dashboard + monitores do Datadog para a demo.
# O provider lê DD_API_KEY, DD_APP_KEY e DD_HOST (ex.: https://api.us5.datadoghq.com) do ambiente.
# Métricas usadas aqui seguem as convenções de observability/README.md.
# TODO(observabilidade): validar nomes de métricas/tags assim que a conta estiver confirmada.

locals {
  env_filter = "env:${var.environment}"
  services   = ["request-service", "quota-service", "transcription-worker", "categorization-service", "ticket-service", "notification-service"]
}

resource "datadog_dashboard_json" "saga" {
  dashboard = jsonencode({
    title       = "VoxTicket — Saga (${var.environment})"
    description = "Fluxo áudio → transcrição → categorização → chamado. Gerenciado por Terraform."
    layout_type = "ordered"
    template_variables = [
      { name = "env", prefix = "env", defaults = [var.environment] },
    ]
    widgets = [
      {
        definition = {
          type  = "query_value"
          title = "Chamados abertos (1h)"
          requests = [{
            q          = "sum:voxticket.saga.completed{$env}.as_count()"
            aggregator = "sum"
          }]
        }
      },
      {
        definition = {
          type  = "query_value"
          title = "Compensações (1h)"
          requests = [{
            q          = "sum:voxticket.saga.compensated{$env}.as_count()"
            aggregator = "sum"
          }]
        }
      },
      {
        definition = {
          type  = "timeseries"
          title = "Créditos: reservados x rejeitados x liberados"
          requests = [
            { q = "sum:voxticket.credit.reserved{$env}.as_count()", display_type = "bars" },
            { q = "sum:voxticket.credit.rejected{$env}.as_count()", display_type = "bars" },
            { q = "sum:voxticket.credit.released{$env}.as_count()", display_type = "bars" },
          ]
        }
      },
      {
        definition = {
          type  = "timeseries"
          title = "Outbox pendente por serviço (F6)"
          requests = [
            { q = "max:voxticket.outbox.pending{$env} by {service}", display_type = "line" },
          ]
        }
      },
      {
        definition = {
          type  = "timeseries"
          title = "Mensagens nas filas (RabbitMQ)"
          requests = [
            { q = "max:rabbitmq.message.current{$env} by {rabbitmq.queue.name}", display_type = "line" },
          ]
        }
      },
      {
        definition = {
          type  = "timeseries"
          title = "Transcrições por réplica (F8)"
          requests = [
            { q = "sum:voxticket.transcription.processed{$env} by {host}.as_count()", display_type = "bars" },
          ]
        }
      },
      {
        definition = {
          type    = "log_stream"
          title   = "Logs da saga"
          query   = "env:${var.environment} service:(${join(" OR ", local.services)})"
          columns = ["service", "@correlationId", "@type", "message"]
        }
      },
    ]
  })
}

resource "datadog_monitor" "dlq" {
  name    = "[voxticket ${var.environment}] Mensagem na DLQ"
  type    = "metric alert"
  message = "Há mensagens em uma DLQ (${var.environment}). Verifique payload inválido (F4). ${var.notify}"
  query   = "max(last_5m):max:rabbitmq.message.current{${local.env_filter},rabbitmq.queue.name:*dlq} > 0"

  monitor_thresholds {
    critical = 0
  }
  tags = ["project:voxticket", local.env_filter]
}

resource "datadog_monitor" "outbox_stuck" {
  name    = "[voxticket ${var.environment}] Outbox não drena"
  type    = "metric alert"
  message = "Outbox com mensagens pendentes há 5 min: broker fora? (F6) ${var.notify}"
  query   = "min(last_5m):max:voxticket.outbox.pending{${local.env_filter}} by {service} > 0"

  monitor_thresholds {
    critical = 0
  }
  tags = ["project:voxticket", local.env_filter]
}

resource "datadog_monitor" "compensations" {
  name    = "[voxticket ${var.environment}] Muitas compensações"
  type    = "metric alert"
  message = "Taxa de compensação alta: a dependência de transcrição está falhando? (F1/F7) ${var.notify}"
  query   = "sum(last_15m):sum:voxticket.saga.compensated{${local.env_filter}}.as_count() > ${var.compensation_threshold}"

  monitor_thresholds {
    critical = var.compensation_threshold
  }
  tags = ["project:voxticket", local.env_filter]
}
