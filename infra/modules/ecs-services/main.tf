# Serviços Fargate genéricos (todos os microsserviços + otel-collector) e tasks de init (one-off).
# - public = true    → atrás do ALB (só o request-service)
# - discoverable     → registrado no Cloud Map: <nome>.<namespace> (ex.: otel-collector.voxticket.internal)

data "aws_region" "current" {}

locals {
  public_services = { for k, s in var.services : k => s if s.public }
  discoverable    = { for k, s in var.services : k => s if s.discoverable }
  create_alb      = length(local.public_services) > 0

  # services e init_tasks normalizados no mesmo tipo de objeto (para usar em for_each)
  all_tasks = merge(
    { for k, s in var.services : k => { image = s.image, cpu = s.cpu, memory = s.memory, port = s.port, command = s.command, environment = s.environment, secrets = s.secrets } },
    { for k, s in var.init_tasks : k => { image = s.image, cpu = s.cpu, memory = s.memory, port = s.port, command = s.command, environment = s.environment, secrets = s.secrets } },
  )

  container_defs = {
    for k, s in local.all_tasks : k => [{
      name        = k
      image       = s.image
      essential   = true
      command     = length(s.command) > 0 ? s.command : null
      environment = [for name, value in merge(var.common_environment, s.environment, { SERVICE_NAME = k, OTEL_SERVICE_NAME = k }) : { name = name, value = value }]
      secrets     = [for name, arn in merge(var.common_secrets, s.secrets) : { name = name, valueFrom = arn }]
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

resource "aws_ecs_task_definition" "this" {
  for_each                 = local.all_tasks
  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
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
  count              = local.create_alb ? 1 : 0
  name               = substr("${var.name}-api", 0, 32)
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.subnet_ids
}

resource "aws_lb_target_group" "this" {
  for_each    = local.public_services
  name        = substr("${var.name}-${each.key}", 0, 32)
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

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
    target_group_arn = values(aws_lb_target_group.this)[0].arn
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
