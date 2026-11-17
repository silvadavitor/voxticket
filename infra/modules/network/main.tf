# VPC sem NAT Gateway (custo): tasks Fargate em subnets públicas com IP público;
# RDS e Amazon MQ em subnets privadas, acessíveis só pelo SG dos serviços.

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.8.0"

  name = var.name
  cidr = var.cidr
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets  = [cidrsubnet(var.cidr, 8, 0), cidrsubnet(var.cidr, 8, 1)]
  private_subnets = [cidrsubnet(var.cidr, 8, 10), cidrsubnet(var.cidr, 8, 11)]

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

resource "aws_security_group" "broker" {
  name        = "${var.name}-broker"
  description = "Amazon MQ RabbitMQ"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "broker_amqps" {
  security_group_id            = aws_security_group.broker.id
  referenced_security_group_id = aws_security_group.services.id
  from_port                    = 5671
  to_port                      = 5671
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "broker_mgmt" {
  security_group_id            = aws_security_group.broker.id
  referenced_security_group_id = aws_security_group.services.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "API de management (rabbitmq-init, receiver do OTel)"
}
