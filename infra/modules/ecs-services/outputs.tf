output "api_url" {
  value = try("http://${aws_lb.this[0].dns_name}", null)
}

output "service_names" {
  value = [for s in aws_ecs_service.this : s.name]
}

output "init_task_run_commands" {
  description = "Comandos para rodar as tasks de init depois do apply."
  value = {
    for k, _ in var.init_tasks : k => join(" ", [
      "aws ecs run-task --cluster ${var.cluster_arn}",
      "--launch-type FARGATE",
      "--task-definition ${aws_ecs_task_definition.this[k].family}",
      "--network-configuration 'awsvpcConfiguration={subnets=[${join(",", var.subnet_ids)}],securityGroups=[${var.services_security_group_id}],assignPublicIp=ENABLED}'",
    ])
  }
}
