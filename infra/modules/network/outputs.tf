output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "services_security_group_id" {
  value = aws_security_group.services.id
}

output "database_security_group_id" {
  value = aws_security_group.database.id
}

output "broker_lb_security_group_id" {
  value = aws_security_group.broker_lb.id
}

output "broker_security_group_id" {
  value = aws_security_group.broker.id
}
