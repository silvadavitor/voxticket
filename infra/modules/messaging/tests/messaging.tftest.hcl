# Cluster RabbitMQ em EC2: 3 nós em AZs diferentes, discos criptografados, IMDSv2, segredos fora do user data.
mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/net/voxticket-test-mq/0123456789abcdef"
      dns_name = "voxticket-test-mq.elb.us-east-1.amazonaws.com"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/voxticket-test-mq/0123456789abcdef" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:voxticket-test/rabbitmq-cookie" }
  }
}

mock_provider "random" {}

override_data {
  target = data.aws_subnet.node[0]
  values = { id = "subnet-a", availability_zone = "us-east-1a", cidr_block = "10.40.0.0/24", vpc_id = "vpc-1" }
}

override_data {
  target = data.aws_subnet.node[1]
  values = { id = "subnet-b", availability_zone = "us-east-1b", cidr_block = "10.40.1.0/24", vpc_id = "vpc-1" }
}

override_data {
  target = data.aws_subnet.node[2]
  values = { id = "subnet-c", availability_zone = "us-east-1c", cidr_block = "10.40.2.0/24", vpc_id = "vpc-1" }
}

variables {
  name                 = "voxticket-test"
  subnet_ids           = ["subnet-a", "subnet-b", "subnet-c"]
  security_group_id    = "sg-nodes"
  lb_security_group_id = "sg-lb"
  broker_secret_arn    = "arn:aws:secretsmanager:us-east-1:000000000000:secret:broker"
  region               = "us-east-1"
}

run "cluster_em_tres_zonas" {
  command = apply

  assert {
    condition     = length(distinct(aws_ebs_volume.data[*].availability_zone)) == 3
    error_message = "Um nó (e o disco dele) em cada AZ."
  }

  assert {
    condition     = alltrue([for v in aws_ebs_volume.data : v.encrypted]) && alltrue([for i in aws_instance.node : i.root_block_device[0].encrypted])
    error_message = "Discos de dados e raiz criptografados."
  }

  assert {
    condition     = alltrue([for i in aws_instance.node : i.metadata_options[0].http_tokens == "required"])
    error_message = "IMDSv2 obrigatório."
  }

  assert {
    condition     = aws_instance.node[1].private_ip == "10.40.1.11" && strcontains(aws_instance.node[0].user_data, "--add-host rabbitmq-2:10.40.2.12")
    error_message = "IPs fixos e cada nó conhecendo todos os outros pelo nome."
  }

  assert {
    condition     = strcontains(aws_instance.node[0].user_data, "secretsmanager get-secret-value") && !strcontains(aws_instance.node[0].user_data, "RABBITMQ_DEFAULT_PASS=$BROKER_PASS\"")
    error_message = "Senha e cookie lidos do Secrets Manager no boot."
  }

  assert {
    condition     = aws_lb.broker.internal && length(aws_lb_target_group_attachment.broker) == 6
    error_message = "NLB interno com os 3 nós em AMQP e management."
  }
}

run "numero_par_de_nos_e_recusado" {
  command = plan

  variables {
    node_count = 2
  }

  expect_failures = [var.node_count]
}
