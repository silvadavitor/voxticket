variable "name" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets dos nós, uma por AZ (o nó i vai na subnet i). Públicas só para ter saída (a VPC não tem NAT); os SGs não abrem nada para fora."
  type        = list(string)
}

variable "security_group_id" {
  description = "SG dos nós."
  type        = string
}

variable "lb_security_group_id" {
  description = "SG do NLB interno (recebe dos serviços, entrega aos nós)."
  type        = string
}

variable "node_count" {
  description = "Nós do cluster, um por EC2. 3 = a fila quorum continua funcionando com um nó (ou uma AZ) fora."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count % 2 == 1
    error_message = "Use número ímpar de nós: a fila quorum precisa de maioria."
  }
}

variable "broker_secret_arn" {
  description = "Segredo com {username, password} do broker. A instância lê no boot; a senha não passa pelo user data."
  type        = string
}

variable "region" {
  type = string
}

variable "instance_type" {
  description = "t4g.small (ARM, 2 GB) basta para o volume do trabalho."
  type        = string
  default     = "t4g.small"
}

variable "image" {
  description = "Mesma imagem do docker compose local."
  type        = string
  default     = "rabbitmq:4.1-management"
}

variable "data_volume_size" {
  description = "GB do disco das filas (EBS separado: sobrevive à troca da instância)."
  type        = number
  default     = 20
}

variable "metrics_namespace" {
  description = "Namespace do CloudWatch onde a instância publica a profundidade das filas (autoescala do worker)."
  type        = string
  default     = "VoxTicket/RabbitMQ"
}
