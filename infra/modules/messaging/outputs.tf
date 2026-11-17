output "amqp_endpoint" {
  description = "amqps://<host>:5671 (sem credenciais — elas vêm do Secrets Manager)."
  value       = aws_mq_broker.this.instances[0].endpoints[0]
}

output "management_url" {
  value = aws_mq_broker.this.instances[0].console_url
}
