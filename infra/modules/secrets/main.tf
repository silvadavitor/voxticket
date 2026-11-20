# Segredos: credenciais do Postgres (1 usuário por serviço + master opcional), do broker e do Grafana.
# Local: 1 container Postgres por serviço, todos com a senha do .env (db_password).
# AWS: 1 RDS com 1 database/usuário por serviço, senhas geradas, master usado pelo db-init.
# Endpoints (host/porta) NÃO ficam aqui: vêm de variáveis de ambiente.

resource "random_password" "db" {
  for_each = var.databases # sempre gerada; só é usada quando db_password == null
  length   = 24
  special  = false
}

resource "random_password" "master" {
  count   = var.create_master_secret && var.master_password == null ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "broker" {
  count   = var.broker_password == null ? 1 : 0
  length  = 24
  special = false
}

locals {
  master_password = var.master_password != null ? var.master_password : try(random_password.master[0].result, null)
  broker_password = var.broker_password != null ? var.broker_password : random_password.broker[0].result
}

resource "aws_secretsmanager_secret" "db" {
  for_each                = var.databases
  name                    = "${var.name_prefix}/db/${each.key}"
  description             = "Credenciais do database ${each.value} (servico ${each.key})"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "db" {
  for_each  = var.databases
  secret_id = aws_secretsmanager_secret.db[each.key].id
  secret_string = jsonencode({
    username = "${each.value}_user"
    password = var.db_password != null ? var.db_password : random_password.db[each.key].result
    dbname   = each.value
  })
}

resource "aws_secretsmanager_secret" "master" {
  count                   = var.create_master_secret ? 1 : 0
  name                    = "${var.name_prefix}/db/master"
  description             = "Usuario master do Postgres (usado so pelo db-init)"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "master" {
  count     = var.create_master_secret ? 1 : 0
  secret_id = aws_secretsmanager_secret.master[0].id
  secret_string = jsonencode({
    username = var.master_username
    password = local.master_password
  })
}

resource "aws_secretsmanager_secret" "broker" {
  name                    = "${var.name_prefix}/broker"
  description             = "Credenciais do RabbitMQ"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "broker" {
  secret_id = aws_secretsmanager_secret.broker.id
  secret_string = jsonencode({
    username = var.broker_username
    password = local.broker_password
  })
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.name_prefix}/grafana"
  description             = "Login do Grafana (admin) na AWS"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.grafana.result
  })
}
