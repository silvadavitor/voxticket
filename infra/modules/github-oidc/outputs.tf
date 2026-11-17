output "role_arn" {
  description = "Variable AWS_ROLE_ARN no GitHub (apply/destroy, environment aws)."
  value       = aws_iam_role.deploy.arn
}

output "plan_role_arn" {
  description = "Variable AWS_PLAN_ROLE_ARN no GitHub (plan em PR, somente leitura)."
  value       = aws_iam_role.plan.arn
}
