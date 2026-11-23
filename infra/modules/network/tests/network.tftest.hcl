# Banco e broker só aceitam conexão vinda dos serviços; API pode ser restrita por CIDR.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
}

variables {
  name = "voxticket-test"
}

run "banco_e_broker_privados" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_services.from_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_services.cidr_ipv4 == null
    error_message = "Postgres só pode receber do SG dos serviços (sem CIDR aberto)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.broker_lb_from_services["amqp"].from_port == 5672 && aws_vpc_security_group_ingress_rule.broker_lb_from_services["amqp"].cidr_ipv4 == null
    error_message = "O NLB do broker só pode receber AMQP do SG dos serviços."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.broker_cluster : r.cidr_ipv4 == null])
    error_message = "As portas do cluster só abrem entre os próprios nós."
  }
}

run "api_restrita" {
  command = plan

  variables {
    api_allowed_cidrs = ["200.1.2.3/32"]
  }

  assert {
    condition     = keys(aws_vpc_security_group_ingress_rule.alb_http) == ["200.1.2.3/32"]
    error_message = "ALB deve liberar só os CIDRs informados."
  }
}
