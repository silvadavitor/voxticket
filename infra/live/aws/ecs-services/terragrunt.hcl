# Microsserviços + observabilidade (otel-collector e Grafana LGTM) no ECS Fargate.
# Imagens: <ecr>/voxticket/<servico>:${IMAGE_TAG} (workflow build-images).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//ecs-services"
}

locals {
  tag            = get_env("IMAGE_TAG", "latest")
  otel_namespace = "voxticket.internal"

  # Só sobe serviço que já tem imagem (o workflow release passa os que têm Dockerfile). Vazio = todos.
  deploy_only = compact(split(",", get_env("DEPLOY_SERVICES", "")))

  # O que é específico de cada serviço. s3_access: none | read | readwrite (menor privilégio).
  catalog = {
    "request-service" = {
      public            = true
      alb_path_patterns = []
      desired_count     = 2           # orquestrador sem ponto único de falha
      s3_access         = "readwrite" # upload do áudio e move para failed/
      autoscaling       = null
      environment = {
        SAGA_TIMEOUT_MS = get_env("SAGA_TIMEOUT_MS", "60000")
      }
    }
    "quota-service" = {
      public            = true
      alb_path_patterns = ["/tenants", "/tenants/*"] # cadastro de clientes
      desired_count     = 1
      s3_access         = "none"
      autoscaling       = null
      environment       = {}
    }
    "transcription-worker" = {
      public            = false
      alb_path_patterns = []
      desired_count     = 3           # R4: réplicas concorrentes na mesma fila
      s3_access         = "readwrite" # lê o áudio, grava transcripts/
      # Whisper (modelo base, int8) precisa de mais CPU e ~1 GB de RAM
      cpu    = 1024
      memory = 2048
      # bônus: autoescala pelo backlog da fila (mínimo 2 mantém o R4)
      autoscaling = {
        min              = 2
        max              = 6
        queue            = "transcription-worker.q"
        backlog_per_task = 5
      }
      environment = {
        TRANSCRIBE_LATENCY_MS_MIN = get_env("TRANSCRIBE_LATENCY_MS_MIN", "0")
        TRANSCRIBE_LATENCY_MS_MAX = get_env("TRANSCRIBE_LATENCY_MS_MAX", "0")
        TRANSCRIBE_FAILURE_RATE   = get_env("TRANSCRIBE_FAILURE_RATE", "0")
        TRANSCRIBE_MAX_ATTEMPTS   = get_env("TRANSCRIBE_MAX_ATTEMPTS", "3")
      }
    }
    "categorization-service" = {
      public            = false
      alb_path_patterns = []
      desired_count     = 1
      s3_access         = "read" # lê a transcrição
      autoscaling       = null
      environment       = {}
    }
    "ticket-service" = {
      public            = true
      alb_path_patterns = ["/tickets", "/tickets/*"] # API de leitura dos chamados
      desired_count     = 1
      s3_access         = "none"
      autoscaling       = null
      environment       = {}
    }
    "notification-service" = {
      public            = false
      alb_path_patterns = []
      desired_count     = 1
      s3_access         = "none"
      autoscaling       = null
      environment       = {}
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
  mock_outputs                            = { bucket_name = "mock", bucket_arn = "arn:aws:s3:::mock" }
}

dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    db_secret_arns     = { for k, _ in include.root.locals.databases : k => "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-${k}" }
    db_secret_names    = { for k, _ in include.root.locals.databases : k => "mock-${k}" }
    broker_secret_arn  = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-broker"
    grafana_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-grafana"
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
    amqp_endpoint     = "amqp://10.0.0.10:5672"
    management_url    = "http://10.0.0.10:15672"
    metrics_namespace = "VoxTicket/RabbitMQ"
  }
}

dependency "ecr" {
  config_path                             = "../ecr"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs                            = { repository_urls = { for k in concat(keys(include.root.locals.databases), ["lgtm"]) : k => "mock/${k}" } }
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
  discovery_namespace        = local.otel_namespace
  bucket_arn                 = dependency.storage.outputs.bucket_arn
  queue_metrics_namespace    = dependency.messaging.outputs.metrics_namespace

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
  }

  # Credenciais do broker injetadas pelo ECS a partir do Secrets Manager (chaves do JSON)
  common_secrets = {
    BROKER_USERNAME = "${dependency.secrets.outputs.broker_secret_arn}:username::"
    BROKER_PASSWORD = "${dependency.secrets.outputs.broker_secret_arn}:password::"
  }

  services = merge(
    {
      for svc, cfg in local.catalog : svc => {
        image             = "${dependency.ecr.outputs.repository_urls[svc]}:${local.tag}"
        port              = 8080
        public            = cfg.public
        alb_path_patterns = cfg.alb_path_patterns
        cpu               = try(cfg.cpu, 256)
        memory            = try(cfg.memory, 512)
        desired_count     = cfg.desired_count
        s3_access         = cfg.s3_access
        autoscaling       = cfg.autoscaling
        iam_secret_arns   = [dependency.secrets.outputs.db_secret_arns[svc]] # só o próprio banco
        environment = merge(cfg.environment, {
          BROKER_QUEUE = "${svc}.q"
          DB_SECRET_ID = dependency.secrets.outputs.db_secret_names[svc]
        })
      } if length(local.deploy_only) == 0 || contains(local.deploy_only, svc)
    },
    # Observabilidade: a MESMA stack do ambiente local (ADR-004)
    {
      # recebe OTLP dos serviços e lê as filas do RabbitMQ (Cloud Map: otel-collector.voxticket.internal)
      "otel-collector" = {
        image        = "otel/opentelemetry-collector-contrib:0.165.0"
        port         = 4317
        discoverable = true
        command      = ["--config=env:OTEL_CONFIG"]
        environment = {
          OTEL_CONFIG        = file("${include.root.locals.repo_root}/observability/otel-collector/config.yaml")
          LGTM_OTLP_ENDPOINT = "lgtm.${local.otel_namespace}:4317"
          RABBITMQ_MGMT_URL  = dependency.messaging.outputs.management_url
        }
        secrets = {
          RABBITMQ_USER     = "${dependency.secrets.outputs.broker_secret_arn}:username::"
          RABBITMQ_PASSWORD = "${dependency.secrets.outputs.broker_secret_arn}:password::"
        }
      }
      # Grafana + Tempo + Prometheus + Loki, com os dashboards embutidos; no ALB em /grafana, com login
      "lgtm" = {
        image             = "${dependency.ecr.outputs.repository_urls["lgtm"]}:${local.tag}"
        port              = 3000
        public            = true
        alb_path_patterns = ["/grafana", "/grafana/*"]
        health_path       = "/grafana/api/health"
        discoverable      = true
        cpu               = 1024
        memory            = 4096
        environment = {
          GF_SERVER_ROOT_URL            = "%(protocol)s://%(domain)s/grafana/"
          GF_SERVER_SERVE_FROM_SUB_PATH = "true"
          GF_AUTH_ANONYMOUS_ENABLED     = "false"
          GF_SECURITY_ADMIN_USER        = "admin"
        }
        secrets = {
          GF_SECURITY_ADMIN_PASSWORD = "${dependency.secrets.outputs.grafana_secret_arn}:password::"
        }
      }
    }
  )
}
