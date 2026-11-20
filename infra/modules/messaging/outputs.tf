output "amqp_endpoint" {
  description = "amqp://<NLB interno>:5672 (sem credenciais: elas vêm do Secrets Manager)."
  value       = "amqp://${aws_lb.broker.dns_name}:5672"
}

output "management_url" {
  description = "API de management pelo NLB (rabbitmq-init e receiver rabbitmq do OTel Collector)."
  value       = "http://${aws_lb.broker.dns_name}:15672"
}

output "node_count" {
  description = "O rabbitmq-init espera esse número de nós no cluster antes de criar as filas."
  value       = var.node_count
}

output "nodes" {
  description = "Nome e IP privado de cada nó."
  value       = local.nodes
}

output "instance_ids" {
  description = "Para entrar num nó: aws ssm start-session --target <id>."
  value       = aws_instance.node[*].id
}

output "metrics_namespace" {
  description = "Namespace CloudWatch com MessageCount por fila (dimensão Queue), usado na autoescala."
  value       = var.metrics_namespace
}
