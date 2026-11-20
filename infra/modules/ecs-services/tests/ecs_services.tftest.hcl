# Menor privilégio, ALB só com serviço público, autoescala só onde configurada.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

variables {
  name                       = "voxticket-test"
  cluster_arn                = "arn:aws:ecs:us-east-1:000000000000:cluster/test"
  cluster_name               = "test"
  execution_role_arn         = "arn:aws:iam::000000000000:role/exec"
  log_group_name             = "/ecs/test"
  vpc_id                     = "vpc-1"
  subnet_ids                 = ["subnet-1", "subnet-2"]
  services_security_group_id = "sg-svc"
  alb_security_group_id      = "sg-alb"
  bucket_arn                 = "arn:aws:s3:::audios"
  queue_metrics_namespace    = "VoxTicket/RabbitMQ"
  services = {
    "request-service" = {
      image           = "img/request:1"
      port            = 8080
      public          = true
      s3_access       = "readwrite"
      iam_secret_arns = ["arn:aws:secretsmanager:us-east-1:000000000000:secret:voxticket/test/db/request-service-abc"]
    }
    "quota-service" = {
      image           = "img/quota:1"
      port            = 8080
      iam_secret_arns = ["arn:aws:secretsmanager:us-east-1:000000000000:secret:voxticket/test/db/quota-service-abc"]
    }
    "ticket-service" = {
      image             = "img/ticket:1"
      port              = 8080
      public            = true
      alb_path_patterns = ["/tickets", "/tickets/*"]
    }
    "transcription-worker" = {
      image         = "img/worker:1"
      port          = 8080
      desired_count = 3
      s3_access     = "readwrite"
      autoscaling   = { min = 2, max = 6, queue = "transcription-worker.q" }
    }
  }
}

run "uma_role_por_servico" {
  command = plan

  assert {
    condition     = length(aws_iam_role.task) == 4
    error_message = "Cada serviço precisa da própria task role."
  }

  assert {
    condition     = aws_ecs_task_definition.this["quota-service"].family == "voxticket-test-quota-service"
    error_message = "Família da task definition fora do padrão."
  }
}

run "alb_so_para_api_publica" {
  command = plan

  assert {
    condition     = length(aws_lb.this) == 1 && keys(aws_lb_target_group.this) == ["request-service", "ticket-service"]
    error_message = "Só os serviços com API pública ficam atrás do ALB."
  }

  assert {
    condition     = keys(aws_lb_listener_rule.path) == ["ticket-service"]
    error_message = "/tickets deve ir para o ticket-service; o resto vai para o request-service."
  }

  assert {
    condition     = aws_lb.this[0].drop_invalid_header_fields
    error_message = "ALB deve descartar headers inválidos."
  }
}

run "autoescala_do_worker" {
  command = plan

  assert {
    condition     = keys(aws_appautoscaling_target.this) == ["transcription-worker"]
    error_message = "Só o worker tem autoescala."
  }

  assert {
    condition     = aws_appautoscaling_target.this["transcription-worker"].min_capacity >= 2
    error_message = "Mínimo de 2 réplicas para manter o R4."
  }
}

run "sem_servico_publico_sem_alb" {
  command = plan

  variables {
    services = {
      "quota-service" = { image = "img/quota:1", port = 8080 }
    }
  }

  assert {
    condition     = length(aws_lb.this) == 0
    error_message = "Sem serviço público não deve criar ALB (custo)."
  }
}

run "s3_access_invalido" {
  command = plan

  variables {
    services = {
      "x" = { image = "img/x:1", s3_access = "admin" }
    }
  }

  expect_failures = [var.services]
}
