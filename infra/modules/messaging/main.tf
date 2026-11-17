# Amazon MQ for RabbitMQ (mesmo protocolo AMQP do container local — ADR-002).
# A topologia (exchanges/filas/DLQs) é aplicada pelo rabbitmq-init via API de management.

resource "aws_mq_broker" "this" {
  broker_name                = var.name
  engine_type                = "RabbitMQ"
  engine_version             = var.engine_version
  host_instance_type         = var.instance_type
  deployment_mode            = "SINGLE_INSTANCE"
  publicly_accessible        = false
  subnet_ids                 = [var.subnet_ids[0]]
  security_groups            = [var.security_group_id]
  auto_minor_version_upgrade = true
  apply_immediately          = true

  user {
    username = var.username
    password = var.password
  }

  logs {
    general = true
  }
}
