# Cluster ECS + logs + IAM compartilhado pelos serviços.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  secrets_arn_pattern = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_prefix}/*"
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---- execution role: puxar imagem, escrever log, injetar secrets ----

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secrets_arn_pattern]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-project-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ---- task role: o que o código dos serviços pode fazer ----

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "AudiosBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"] # mover p/ failed/ = Get + Put + Delete
    resources = ["${var.bucket_arn}/*"]
  }

  statement {
    sid       = "AudiosBucketList"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
  }

  statement {
    sid       = "ReadSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.secrets_arn_pattern]
  }

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
}

resource "aws_iam_role_policy" "task" {
  name   = "service-permissions"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
