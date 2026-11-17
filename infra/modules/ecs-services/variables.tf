variable "name" {
  description = "Prefixo (ex.: voxticket-aws)."
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets públicas (tasks com IP público, sem NAT)."
  type        = list(string)
}

variable "services_security_group_id" {
  type = string
}

variable "alb_security_group_id" {
  type = string
}

variable "discovery_namespace" {
  type    = string
  default = "voxticket.internal"
}

variable "cpu_architecture" {
  description = "X86_64 ou ARM64 (deve bater com as imagens publicadas no ECR)."
  type        = string
  default     = "X86_64"
}

variable "common_environment" {
  description = "Variáveis de ambiente comuns a todos os containers."
  type        = map(string)
  default     = {}
}

variable "common_secrets" {
  description = "Mapa VAR => ARN do secret (ou ARN:chave::) comum a todos."
  type        = map(string)
  default     = {}
}

variable "services" {
  description = "Serviços de longa duração."
  type = map(object({
    image         = string
    cpu           = optional(number, 256)
    memory        = optional(number, 512)
    desired_count = optional(number, 1)
    port          = optional(number)
    public        = optional(bool, false)
    discoverable  = optional(bool, false)
    health_path   = optional(string, "/health")
    command       = optional(list(string), [])
    environment   = optional(map(string), {})
    secrets       = optional(map(string), {})
  }))
}

variable "init_tasks" {
  description = "Tasks one-off (db-init, rabbitmq-init): só task definition; rodar com aws ecs run-task."
  type = map(object({
    image       = string
    cpu         = optional(number, 256)
    memory      = optional(number, 512)
    port        = optional(number)
    command     = optional(list(string), [])
    environment = optional(map(string), {})
    secrets     = optional(map(string), {})
  }))
  default = {}
}
