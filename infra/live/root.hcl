# Configuração raiz do Terragrunt, incluída por todas as units de infra/live/<env>/<unit>.
# Cada ambiente define seu env.hcl (local = MiniStack, aws = conta real).

locals {
  env_cfg      = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  environment  = local.env_cfg.locals.environment
  aws_region   = local.env_cfg.locals.aws_region
  is_ministack = local.env_cfg.locals.is_ministack

  project        = "voxticket"
  name           = "${local.project}-${local.environment}"
  secrets_prefix = "${local.project}/${local.environment}"
  modules_dir    = "${dirname(get_parent_terragrunt_dir())}/modules"
  repo_root      = dirname(dirname(get_parent_terragrunt_dir()))

  # serviço => database (ADR-003)
  databases = {
    "request-service"        = "requests"
    "quota-service"          = "quota"
    "transcription-worker"   = "transcription"
    "categorization-service" = "categorization"
    "ticket-service"         = "ticket"
    "notification-service"   = "notification"
  }

  endpoint = get_env("AWS_ENDPOINT_URL", "http://localhost:4566")

  tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terragrunt"
  }

  # Provider AWS: MiniStack (endpoints locais, credenciais falsas) x conta real
  provider_ministack = <<-EOF
    provider "aws" {
      region                      = "${local.aws_region}"
      access_key                  = "test"
      secret_key                  = "test"
      skip_credentials_validation = true
      skip_metadata_api_check     = true
      skip_requesting_account_id  = true
      s3_use_path_style           = true

      endpoints {
        s3             = "${local.endpoint}"
        secretsmanager = "${local.endpoint}"
        sts            = "${local.endpoint}"
        iam            = "${local.endpoint}"
      }

      default_tags {
        tags = ${jsonencode(local.tags)}
      }
    }
  EOF

  provider_aws = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = ${jsonencode(local.tags)}
      }
    }
  EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = local.is_ministack ? local.provider_ministack : local.provider_aws
}

# Estado: arquivo local (volume do compose) no MiniStack; S3 com lock nativo na AWS.
# jsonencode/jsondecode porque os dois objetos têm formatos diferentes.
remote_state {
  backend = local.is_ministack ? "local" : "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = jsondecode(local.is_ministack ? jsonencode({
    path = "${get_env("TG_STATE_DIR", "${local.repo_root}/.tfstate")}/${local.environment}/${path_relative_to_include()}/terraform.tfstate"
    }) : jsonencode({
    bucket       = try(local.env_cfg.locals.state_bucket, "")
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.aws_region
    encrypt      = true
    use_lockfile = true
  }))
}
