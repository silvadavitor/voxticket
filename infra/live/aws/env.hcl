# Ambiente de entrega: conta AWS real. Use credenciais via AWS_PROFILE ou SSO.
locals {
  environment = "aws"
  aws_region  = get_env("AWS_REGION", "us-east-1")
  # fora da região principal, os nomes globais ganham o sufixo da região (contingência)
  primary_region = "us-east-1"
  region_suffix  = local.aws_region == local.primary_region ? "" : "-${local.aws_region}"
  is_ministack   = false
  account_id     = get_aws_account_id()
  bucket_suffix  = "-${local.account_id}" # o name já leva o sufixo da região
  # Criado automaticamente pelo Terragrunt no primeiro apply
  state_bucket = "voxticket-tfstate-${local.account_id}${local.region_suffix}"
}
