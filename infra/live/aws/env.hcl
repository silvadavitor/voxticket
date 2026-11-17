# Ambiente de entrega: conta AWS real. Use credenciais via AWS_PROFILE ou SSO.
locals {
  environment   = "aws"
  aws_region    = get_env("AWS_REGION", "us-east-1")
  is_ministack  = false
  account_id    = get_aws_account_id()
  bucket_suffix = "-${local.account_id}"
  # Criado automaticamente pelo Terragrunt no primeiro apply
  state_bucket = "voxticket-tfstate-${local.account_id}"
}
