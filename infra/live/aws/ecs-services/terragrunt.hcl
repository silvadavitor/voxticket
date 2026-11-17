# Todos os microsserviços + otel-collector no ECS Fargate, mais as tasks de init.
# Imagens: <ecr>/<voxticket>/<servico>:${IMAGE_TAG} (ver infra/scripts/push-images.sh).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//ecs-services"
}

locals {
  tag            = get_env("IMAGE_TAG", "latest")
  datadog        = get_env("DD_API_KEY", "") != ""
  otel_namespace = "voxticket.internal"

  # Configuração específica de cada serviço (o resto é comum)
  catalog = {
    "request-service" = {
      public        = true
      desired_count = 1
      environment = {
        SAGA_TIMEOUT_MS = get_env("SAGA_TIMEOUT_MS", "60000")
        PUBLIC_BASE_URL = "" # TODO: preencher com o DNS do ALB se a API precisar montar statusUrl absoluta
      }
    }
    "quota-service" = {
      public        = false
      desired_count = 1
      environment   = {}
    }
    "transcription-worker" = {
      public        = false
      desired_count = 3 # R4
      environment = {
        TRANSCRIBE_LATENCY_MS_MIN = get_env("TRANSCRIBE_LATENCY_MS_MIN", "500")
        TRANSCRIBE_LATENCY_MS_MAX = get_env("TRANSCRIBE_LATENCY_MS_MAX", "3000")
        TRANSCRIBE_FAILURE_RATE   = get_env("TRANSCRIBE_FAILURE_RATE", "0.1")
        TRANSCRIBE_MAX_ATTEMPTS   = get_env("TRANSCRIBE_MAX_ATTEMPTS", "3")
        TRANSCRIBER_MODE          = "fake"
      }
    }
    "categorization-service" = {
      public        = false
      desired_count = 1
      environment   = {}
    }
    "ticket-service" = {
      public        = false
      desired_count = 1
      environment   = {}
    }
    "notification-service" = {
      public        = false
      desired_count = 1
      environment   = {}
    }
  }
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

dependency "storage" {
  config_path                             = "../storage"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs                            = { bucket_name = "mock" }
}

dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    db_secret_arns     = { for k, _ in include.root.locals.databases : k => "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock" }
    db_secret_names    = { for k, _ in include.root.locals.databases : k => "mock" }
    broker_secret_arn  = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
    datadog_secret_arn = null
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
  mock_outputs = {
    amqp_endpoint  = "amqps://mock:5671"
    management_url = "https://mock"
  }
}

dependency "ecr" {
  config_path                             = "../ecr"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs                            = { repository_urls = { for k in concat(keys(include.root.locals.databases), ["db-init", "rabbitmq-init"]) : k => "mock/${k}" } }
}

dependency "ecs_cluster" {
  config_path                             = "../ecs-cluster"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    cluster_arn        = "arn:aws:ecs:us-east-1:000000000000:cluster/mock"
    execution_role_arn = "arn:aws:iam::000000000000:role/mock"
    task_role_arn      = "arn:aws:iam::000000000000:role/mock"
    log_group_name     = "mock"
  }
}

inputs = {
  name                       = include.root.locals.name
  cluster_arn                = dependency.ecs_cluster.outputs.cluster_arn
  execution_role_arn         = dependency.ecs_cluster.outputs.execution_role_arn
  task_role_arn              = dependency.ecs_cluster.outputs.task_role_arn
  log_group_name             = dependency.ecs_cluster.outputs.log_group_name
  vpc_id                     = dependency.network.outputs.vpc_id
  subnet_ids                 = dependency.network.outputs.public_subnet_ids
  services_security_group_id = dependency.network.outputs.services_security_group_id
  alb_security_group_id      = dependency.network.outputs.alb_security_group_id
  discovery_namespace        = local.otel_namespace

  common_environment = {
    ENVIRONMENT                 = include.root.locals.environment
    AWS_REGION                  = include.root.locals.aws_region
    S3_BUCKET                   = dependency.storage.outputs.bucket_name
    DB_HOST                     = dependency.database.outputs.address
    DB_PORT                     = tostring(dependency.database.outputs.port)
    BROKER_URL                  = dependency.messaging.outputs.amqp_endpoint
    BROKER_EXCHANGE             = "events"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.${local.otel_namespace}:4317"
    OTEL_RESOURCE_ATTRIBUTES    = "deployment.environment.name=${include.root.locals.environment}"
    OTEL_SDK_DISABLED           = local.datadog ? "false" : "true"
  }

  # Credenciais do broker injetadas pelo ECS a partir do Secrets Manager (chaves do JSON)
  common_secrets = {
    BROKER_USERNAME = "${dependency.secrets.outputs.broker_secret_arn}:username::"
    BROKER_PASSWORD = "${dependency.secrets.outputs.broker_secret_arn}:password::"
  }

  services = merge(
    {
      for svc, cfg in local.catalog : svc => {
        image         = "${dependency.ecr.outputs.repository_urls[svc]}:${local.tag}"
        port          = 8080
        public        = cfg.public
        desired_count = cfg.desired_count
        environment = merge(cfg.environment, {
          BROKER_QUEUE = "${svc}.q"
          DB_SECRET_ID = dependency.secrets.outputs.db_secret_names[svc]
        })
      }
    },
    # OTel Collector como serviço próprio (Cloud Map: otel-collector.voxticket.internal), só com Datadog
    local.datadog ? {
      "otel-collector" = {
        image        = "otel/opentelemetry-collector-contrib:0.165.0"
        port         = 4317
        discoverable = true
        health_path  = "/"
        command      = ["--config=env:OTEL_CONFIG"]
        environment = {
          OTEL_CONFIG       = file("${include.root.locals.repo_root}/observability/otel-collector/config.datadog.yaml")
          DD_SITE           = get_env("DD_SITE", "datadoghq.com")
          RABBITMQ_MGMT_URL = dependency.messaging.outputs.management_url
        }
        secrets = {
          # coalesce: os dois lados do ternário são avaliados, e interpolar null dá erro
          DD_API_KEY        = "${coalesce(dependency.secrets.outputs.datadog_secret_arn, "none")}:api_key::"
          RABBITMQ_USER     = "${dependency.secrets.outputs.broker_secret_arn}:username::"
          RABBITMQ_PASSWORD = "${dependency.secrets.outputs.broker_secret_arn}:password::"
        }
      }
    } : {}
  )

  # Rodar uma vez após o apply (o output init_task_run_commands imprime o comando)
  init_tasks = {
    "db-init" = {
      image = "${dependency.ecr.outputs.repository_urls["db-init"]}:${local.tag}"
      environment = {
        SECRETS_PREFIX = include.root.locals.secrets_prefix
        SERVICES       = join(" ", keys(include.root.locals.databases))
      }
    }
    "rabbitmq-init" = {
      image = "${dependency.ecr.outputs.repository_urls["rabbitmq-init"]}:${local.tag}"
      environment = {
        BROKER_MGMT_URL = dependency.messaging.outputs.management_url
      }
    }
  }
}
