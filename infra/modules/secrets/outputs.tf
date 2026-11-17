output "db_secret_arns" {
  description = "Mapa serviço => ARN do segredo do database."
  value       = { for k, s in aws_secretsmanager_secret.db : k => s.arn }
}

output "db_secret_names" {
  value = { for k, s in aws_secretsmanager_secret.db : k => s.name }
}

output "master_secret_arn" {
  value = try(aws_secretsmanager_secret.master[0].arn, null)
}

output "broker_secret_arn" {
  value = aws_secretsmanager_secret.broker.arn
}

output "datadog_secret_arn" {
  value = try(aws_secretsmanager_secret.datadog[0].arn, null)
}

output "master_username" {
  value = var.master_username
}

output "master_password" {
  value     = local.master_password
  sensitive = true
}

output "broker_username" {
  value = var.broker_username
}

output "broker_password" {
  value     = local.broker_password
  sensitive = true
}
