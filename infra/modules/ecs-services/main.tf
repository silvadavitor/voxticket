# Serviços Fargate genéricos (microsserviços + otel-collector) e tasks de init (one-off).
# - public = true      → atrás do ALB (só o request-service)
# - discoverable       → registrado no Cloud Map: <nome>.<namespace> (ex.: otel-collector.voxticket.internal)
# - iam_secret_arns    → segredos que o CÓDIGO do serviço pode ler (só o próprio banco)
# - s3_access          → none | read | readwrite no bucket de áudios
# - autoscaling        → escala pelo backlog da fila no Amazon MQ (mensagens por task)

data "aws_region" "current" {}

locals {
  public_services = { for k, s in var.services : k => s if s.public }
  # API gateway no ALB: serviço público SEM alb_path_patterns é o padrão; os outros por caminho
  path_routed    = { for k, s in local.public_services : k => s if length(s.alb_path_patterns) > 0 }
  default_public = try([for k, s in local.public_services : k if length(s.alb_path_patterns) == 0][0], null)
  discoverable   = { for k, s in var.services : k => s if s.discoverable }
  autoscaled     = { for k, s in var.services : k => s if s.autoscaling != null }
  create_alb     = length(local.public_services) > 0

  # services e init_tasks normalizados no mesmo tipo de objeto (para usar em for_each)
  all_tasks = merge(
    { for k, s in var.services : k => {
      image       = s.image, cpu = s.cpu, memory = s.memory, port = s.port, command = s.command,
      environment = s.environment, secrets = s.secrets, iam_secret_arns = s.iam_secret_arns, s3_access = s.s3_access
    } },
    { for k, s in var.init_tasks : k => {
      image       = s.image, cpu = s.cpu, memory = s.memory, port = s.port, command = s.command,
      environment = s.environment, secrets = s.secrets, iam_secret_arns = s.iam_secret_arns, s3_access = s.s3_access
    } },
  )

  s3_actions = {
    none      = []
    read      = ["s3:GetObject"]
    readwrite = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"] # mover p/ failed/ = Get + Put + Delete
  }

  container_defs = {
    for k, s in local.all_tasks : k => [{
      name                   = k
      image                  = s.image
      essential              = true
      readonlyRootFilesystem = false
      command                = length(s.command) > 0 ? s.command : null
      environment            = [for name, value in merge(var.common_environment, s.environment, { SERVICE_NAME = k, OTEL_SERVICE_NAME = k }) : { name = name, value = value }]
      secrets                = [for name, arn in merge(var.common_secrets, s.secrets) : { name = name, valueFrom = arn }]
      portMappings = s.port == null ? [] : [{
        containerPort = s.port
        protocol      = "tcp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.log_group_name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = k
        }
      }
    }]
  }
}

# ---------------- IAM: uma task role por serviço (menor privilégio) ----------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task" {
  for_each           = local.all_tasks
  name               = substr("${var.name}-${each.key}-task", 0, 64)
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "task" {
  for_each = local.all_tasks

  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(each.value.iam_secret_arns) > 0 ? [1] : []
    content {
      sid       = "OwnSecretsOnly"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = each.value.iam_secret_arns
    }
  }

  dynamic "statement" {
    for_each = each.value.s3_access != "none" ? [1] : []
    content {
      sid       = "AudiosBucket"
      actions   = local.s3_actions[each.value.s3_access]
      resources = ["${var.bucket_arn}/*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  for_each = local.all_tasks
  name     = "least-privilege"
  role     = aws_iam_role.task[each.key].id
  policy   = data.aws_iam_policy_document.task[each.key].json
}

# ---------------- task definitions ----------------

resource "aws_ecs_task_definition" "this" {
  for_each                 = local.all_tasks
  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task[each.key].arn
  container_definitions    = jsonencode(local.container_defs[each.key])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }
}

# ---------------- Cloud Map ----------------

resource "aws_service_discovery_private_dns_namespace" "this" {
  count = length(local.discoverable) > 0 ? 1 : 0
  name  = var.discovery_namespace
  vpc   = var.vpc_id
}

resource "aws_service_discovery_service" "this" {
  for_each = local.discoverable
  name     = each.key

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this[0].id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# ---------------- ALB (API pública) ----------------

resource "aws_lb" "this" {
  count                      = local.create_alb ? 1 : 0
  name                       = substr("${var.name}-api", 0, 32)
  load_balancer_type         = "application"
  security_groups            = [var.alb_security_group_id]
  subnets                    = var.subnet_ids
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "this" {
  for_each    = local.public_services
  name        = substr("${var.name}-${each.key}", 0, 32)
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 15

  health_check {
    path                = each.value.health_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
  }
}

resource "aws_lb_listener" "http" {
  count             = local.create_alb ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[coalesce(local.default_public, keys(local.public_services)[0])].arn
  }
}

resource "aws_lb_listener_rule" "path" {
  for_each     = local.path_routed
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 100 + index(sort(keys(local.path_routed)), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  condition {
    path_pattern {
      values = each.value.alb_path_patterns
    }
  }
}

# ---------------- serviços ----------------

resource "aws_ecs_service" "this" {
  for_each               = var.services
  name                   = each.key
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this[each.key].arn
  desired_count          = each.value.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.services_security_group_id]
    assign_public_ip = true # sem NAT: precisa de IP público para ECR/Secrets/S3
  }

  dynamic "load_balancer" {
    for_each = each.value.public ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[each.key].arn
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  dynamic "service_registries" {
    for_each = each.value.discoverable ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.this[each.key].arn
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]
}

# ---------------- autoescala pelo backlog da fila (bônus) ----------------
# backlog por task = mensagens na fila (Amazon MQ) / tasks rodando (Container Insights).
# Target tracking mantém esse valor perto de `backlog_per_task`.

resource "aws_appautoscaling_target" "this" {
  for_each           = local.autoscaled
  min_capacity       = each.value.autoscaling.min
  max_capacity       = each.value.autoscaling.max
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "backlog" {
  for_each           = local.autoscaled
  name               = "${each.key}-queue-backlog"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.this[each.key].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[each.key].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = each.value.autoscaling.backlog_per_task
    scale_out_cooldown = 30
    scale_in_cooldown  = 120

    customized_metric_specification {
      metrics {
        id          = "backlog"
        label       = "mensagens por task"
        expression  = "queue / IF(tasks < 1, 1, tasks)"
        return_data = true
      }

      metrics {
        id          = "queue"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "AWS/AmazonMQ"
            metric_name = "MessageCount"
            dimensions {
              name  = "Broker"
              value = var.broker_name
            }
            dimensions {
              name  = "VirtualHost"
              value = "/"
            }
            dimensions {
              name  = "Queue"
              value = each.value.autoscaling.queue
            }
          }
        }
      }

      metrics {
        id          = "tasks"
        return_data = false
        metric_stat {
          stat = "Average"
          metric {
            namespace   = "ECS/ContainerInsights"
            metric_name = "RunningTaskCount"
            dimensions {
              name  = "ClusterName"
              value = var.cluster_name
            }
            dimensions {
              name  = "ServiceName"
              value = each.key
            }
          }
        }
      }
    }
  }
}
