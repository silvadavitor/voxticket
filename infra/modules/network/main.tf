# VPC sem NAT Gateway (custo): tasks Fargate em subnets públicas com IP público;
# RDS em subnets privadas; o broker (RabbitMQ em EC2) numa subnet pública só para ter saída, sem nenhuma
# porta aberta para fora: banco e broker só aceitam conexão vinda do SG dos serviços.

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.8.0"

  name = var.name
  cidr = var.cidr
  # 3 AZs: um nó do RabbitMQ em cada (o cluster sobrevive à queda de uma zona)
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  public_subnets  = [for i in range(3) : cidrsubnet(var.cidr, 8, i)]
  private_subnets = [for i in range(3) : cidrsubnet(var.cidr, 8, 10 + i)]

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true
}

# ---- security groups ----

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB publico da API"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = toset(var.api_allowed_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "services" {
  name        = "${var.name}-services"
  description = "Tasks ECS dos microsservicos"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "services_self" {
  security_group_id            = aws_security_group.services.id
  referenced_security_group_id = aws_security_group.services.id
  ip_protocol                  = "-1"
  description                  = "Servico <-> servico (ex.: OTLP para o collector)"
}

resource "aws_vpc_security_group_ingress_rule" "services_from_alb" {
  security_group_id            = aws_security_group.services.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "services_all" {
  security_group_id = aws_security_group.services.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "database" {
  name        = "${var.name}-database"
  description = "RDS Postgres"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "database_from_services" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.services.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# Broker: 3 EC2 (um nó do RabbitMQ em cada) atrás de um NLB interno.
# serviços → NLB (5672 AMQP, 15672 management) → nós; os nós conversam entre si (cluster Erlang).
resource "aws_security_group" "broker_lb" {
  name        = "${var.name}-broker-lb"
  description = "NLB interno do RabbitMQ"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "broker_lb_from_services" {
  for_each                     = { amqp = 5672, management = 15672 }
  security_group_id            = aws_security_group.broker_lb.id
  referenced_security_group_id = aws_security_group.services.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
  description                  = "${each.key} vindo dos serviços"
}

resource "aws_vpc_security_group_egress_rule" "broker_lb_to_nodes" {
  for_each                     = { amqp = 5672, management = 15672 }
  security_group_id            = aws_security_group.broker_lb.id
  referenced_security_group_id = aws_security_group.broker.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}


resource "aws_security_group" "broker" {
  name        = "${var.name}-broker"
  description = "Nos do RabbitMQ em EC2"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "broker_from_lb" {
  for_each                     = { amqp = 5672, management = 15672 }
  security_group_id            = aws_security_group.broker.id
  referenced_security_group_id = aws_security_group.broker_lb.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
  description                  = "${each.key} vindo do NLB (inclui o health check)"
}

# Cluster: epmd (4369), distribuição Erlang (25672) e ferramentas de CLI (35672-35682), só entre os nós
resource "aws_vpc_security_group_ingress_rule" "broker_cluster" {
  for_each                     = { epmd = [4369, 4369], erlang = [25672, 25672], cli = [35672, 35682] }
  security_group_id            = aws_security_group.broker.id
  referenced_security_group_id = aws_security_group.broker.id
  from_port                    = each.value[0]
  to_port                      = each.value[1]
  ip_protocol                  = "tcp"
  description                  = "cluster: ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "broker_all" {
  security_group_id = aws_security_group.broker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Saída: pacotes, imagem do RabbitMQ, Secrets Manager, CloudWatch, Session Manager e os outros nós"
}
