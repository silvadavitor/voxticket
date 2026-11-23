# RabbitMQ em cluster: 3 EC2 (uma por AZ) atrás de um NLB interno, EBS próprio por nó. Ver ADR-002.
# A topologia é aplicada pelo rabbitmq-init, igual ao local.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_subnet" "node" {
  count = var.node_count
  id    = var.subnet_ids[count.index % length(var.subnet_ids)]
}

locals {
  nodes = [for i in range(var.node_count) : {
    name = "rabbitmq-${i}"
    ip   = cidrhost(data.aws_subnet.node[i].cidr_block, 10 + i)
  }]
}

# cookie do Erlang: o mesmo em todos os nós
resource "random_password" "cookie" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "cookie" {
  name                    = "${var.name}/rabbitmq-cookie"
  description             = "Cookie do cluster RabbitMQ (Erlang)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "cookie" {
  secret_id     = aws_secretsmanager_secret.cookie.id
  secret_string = random_password.cookie.result
}

# nós: só os segredos do broker e as métricas do próprio namespace
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "broker" {
  name               = "${var.name}-broker"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.broker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "broker" {
  statement {
    sid       = "LerSoOsSegredosDoBroker"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.broker_secret_arn, aws_secretsmanager_secret.cookie.arn]
  }

  statement {
    sid       = "MetricasDasFilas"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData não aceita recurso; limitado ao namespace abaixo
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metrics_namespace]
    }
  }
}

resource "aws_iam_role_policy" "broker" {
  name   = "broker"
  role   = aws_iam_role.broker.id
  policy = data.aws_iam_policy_document.broker.json
}

resource "aws_iam_instance_profile" "broker" {
  name = "${var.name}-broker"
  role = aws_iam_role.broker.name
}

resource "aws_ebs_volume" "data" {
  count             = var.node_count
  availability_zone = data.aws_subnet.node[count.index].availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${var.name}-${local.nodes[count.index].name}-data" }
}

resource "aws_instance" "node" {
  count                       = var.node_count
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.node[count.index].id
  private_ip                  = local.nodes[count.index].ip
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.broker.name
  associate_public_ip_address = true # só saída (a VPC não tem NAT); o SG não abre nada para fora
  monitoring                  = true
  ebs_optimized               = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    node_name         = local.nodes[count.index].name
    nodes             = local.nodes
    volume_id         = aws_ebs_volume.data[count.index].id
    secret_id         = var.broker_secret_arn
    cookie_secret_id  = aws_secretsmanager_secret.cookie.arn
    region            = var.region
    image             = var.image
    metrics_namespace = var.metrics_namespace
  })
  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [ami] # AMI nova não recria o broker; atualizar é decisão explícita, um nó por vez
  }

  tags = { Name = "${var.name}-${local.nodes[count.index].name}" }
}

resource "aws_volume_attachment" "data" {
  count       = var.node_count
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data[count.index].id
  instance_id = aws_instance.node[count.index].id
}

# NLB interno: um endereço só; o health check tira do ar o nó que cair
resource "aws_lb" "broker" {
  name                             = substr("${var.name}-mq", 0, 32)
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = distinct([for s in data.aws_subnet.node : s.id])
  security_groups                  = [var.lb_security_group_id]
  enable_cross_zone_load_balancing = true
}

locals {
  ports = { amqp = 5672, management = 15672 }
}

resource "aws_lb_target_group" "broker" {
  for_each             = local.ports
  name                 = substr("${var.name}-mq-${each.key}", 0, 32)
  port                 = each.value
  protocol             = "TCP"
  vpc_id               = data.aws_subnet.node[0].vpc_id
  target_type          = "instance"
  deregistration_delay = 10

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "broker" {
  for_each         = { for pair in setproduct(keys(local.ports), range(var.node_count)) : "${pair[0]}-${pair[1]}" => pair }
  target_group_arn = aws_lb_target_group.broker[each.value[0]].arn
  target_id        = aws_instance.node[each.value[1]].id
  port             = local.ports[each.value[0]]
}

resource "aws_lb_listener" "broker" {
  for_each          = local.ports
  load_balancer_arn = aws_lb.broker.arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.broker[each.key].arn
  }
}
