# Tasks one-off que preparam o ambiente (rodadas pelo infra/scripts/aws.sh antes dos serviços):
#   db-init       → cria 1 database + 1 usuário por serviço no RDS (ADR-003)
#   rabbitmq-init → aplica rabbitmq/definitions.json no Amazon MQ (ADR-002)

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//ecs-services"
}

locals {
  tag = get_env("IMAGE_TAG", "latest")
}

dependency "network" {
  config_path                             = "../network"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    vpc_id                     = "vpc-mock"
    public_subnet_ids          = ["subnet-mock1", "subnet-mock2"]
    services_security_group_id = "sg-mock"
    alb_security_group_id      = "sg-mock"
  }
}

dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    db_secret_arns    = { for k, _ in include.root.locals.databases : k => "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-${k}" }
    master_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-master"
    broker_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-broker"
  }
}

dependency "database" {
  config_path                             = "../database"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs                            = { address = "mock", port = 5432 }
}

dependency "messaging" {
  config_path                             = "../messaging"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs                            = { management_url = "https://mock" }
}

dependency "ecr" {
  config_path                             = "../ecr"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs                            = { repository_urls = { "db-init" = "mock/db-init", "rabbitmq-init" = "mock/rabbitmq-init" } }
}

dependency "ecs_cluster" {
  config_path                             = "../ecs-cluster"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    cluster_arn        = "arn:aws:ecs:us-east-1:000000000000:cluster/mock"
    cluster_name       = "mock"
    execution_role_arn = "arn:aws:iam::000000000000:role/mock"
    log_group_name     = "mock"
  }
}

inputs = {
  name                       = include.root.locals.name
  cluster_arn                = dependency.ecs_cluster.outputs.cluster_arn
  cluster_name               = dependency.ecs_cluster.outputs.cluster_name
  execution_role_arn         = dependency.ecs_cluster.outputs.execution_role_arn
  log_group_name             = dependency.ecs_cluster.outputs.log_group_name
  vpc_id                     = dependency.network.outputs.vpc_id
  subnet_ids                 = dependency.network.outputs.public_subnet_ids
  services_security_group_id = dependency.network.outputs.services_security_group_id
  alb_security_group_id      = dependency.network.outputs.alb_security_group_id

  common_environment = {
    AWS_REGION = include.root.locals.aws_region
  }

  # Credenciais do broker injetadas pelo ECS (chaves do JSON do segredo)
  common_secrets = {
    BROKER_USERNAME = "${dependency.secrets.outputs.broker_secret_arn}:username::"
    BROKER_PASSWORD = "${dependency.secrets.outputs.broker_secret_arn}:password::"
  }

  services = {}

  init_tasks = {
    "db-init" = {
      image = "${dependency.ecr.outputs.repository_urls["db-init"]}:${local.tag}"
      environment = {
        DB_HOST        = dependency.database.outputs.address
        DB_PORT        = tostring(dependency.database.outputs.port)
        SECRETS_PREFIX = include.root.locals.secrets_prefix
        SERVICES       = join(" ", keys(include.root.locals.databases))
      }
      # único que lê o master e os segredos de todos os bancos
      iam_secret_arns = concat([dependency.secrets.outputs.master_secret_arn], values(dependency.secrets.outputs.db_secret_arns))
    }
    "rabbitmq-init" = {
      image = "${dependency.ecr.outputs.repository_urls["rabbitmq-init"]}:${local.tag}"
      environment = {
        BROKER_MGMT_URL = dependency.messaging.outputs.management_url
      }
    }
  }
}
