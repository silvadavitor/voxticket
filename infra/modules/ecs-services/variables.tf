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

variable "cluster_name" {
  description = "Nome do cluster (dimensão das métricas de autoescala)."
  type        = string
}

variable "bucket_arn" {
  description = "Bucket de áudios (para as permissões s3_access)."
  type        = string
  default     = "arn:aws:s3:::none"
}

variable "broker_name" {
  description = "Nome do broker Amazon MQ (dimensão da métrica MessageCount). Obrigatório se algum serviço tiver autoscaling."
  type        = string
  default     = null
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
  default     = {}
  type = map(object({
    image         = string
    cpu           = optional(number, 256)
    memory        = optional(number, 512)
    desired_count = optional(number, 1)
    port          = optional(number)
    public        = optional(bool, false)
    discoverable  = optional(bool, false)
    health_path   = optional(string, "/health")
    # rotas do ALB para este serviço (ex.: ["/tickets", "/tickets/*"]); vazio = destino padrão
    alb_path_patterns = optional(list(string), [])
    command           = optional(list(string), [])
    environment       = optional(map(string), {})
    secrets           = optional(map(string), {})
    iam_secret_arns   = optional(list(string), [])
    s3_access         = optional(string, "none")
    autoscaling = optional(object({
      min              = number
      max              = number
      queue            = string
      backlog_per_task = optional(number, 5)
    }))
  }))

  validation {
    condition     = alltrue([for s in values(var.services) : contains(["none", "read", "readwrite"], s.s3_access)])
    error_message = "s3_access deve ser none, read ou readwrite."
  }
}

variable "init_tasks" {
  description = "Tasks one-off (db-init, rabbitmq-init): só task definition; rodar com aws ecs run-task."
  type = map(object({
    image           = string
    cpu             = optional(number, 256)
    memory          = optional(number, 512)
    port            = optional(number)
    command         = optional(list(string), [])
    environment     = optional(map(string), {})
    secrets         = optional(map(string), {})
    iam_secret_arns = optional(list(string), [])
    s3_access       = optional(string, "none")
  }))
  default = {}
}
