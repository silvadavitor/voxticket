variable "name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "engine_version" {
  description = "Versão do RabbitMQ no Amazon MQ. TODO(infra): conferir versões suportadas na região antes do deploy."
  type        = string
  default     = "3.13"
}

variable "instance_type" {
  type    = string
  default = "mq.t3.micro"
}

variable "username" {
  type = string
}

variable "password" {
  type      = string
  sensitive = true
}
