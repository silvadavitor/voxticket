variable "name_prefix" {
  description = "Prefixo dos segredos, ex.: voxticket/local."
  type        = string
}

variable "databases" {
  description = "Mapa serviço => nome do database."
  type        = map(string)
}

variable "db_password" {
  description = "Senha fixa para todos os usuários de serviço (local, igual à dos containers). null = gerar uma por serviço."
  type        = string
  default     = null
  sensitive   = true
}

variable "create_master_secret" {
  description = "Cria o segredo do usuário master (AWS: RDS único + db-init). Local: false."
  type        = bool
  default     = true
}

variable "master_username" {
  type    = string
  default = "voxticket_admin"
}

variable "master_password" {
  description = "Senha master. null = gerar."
  type        = string
  default     = null
  sensitive   = true
}

variable "broker_username" {
  type    = string
  default = "voxticket"
}

variable "broker_password" {
  description = "Senha do broker. null = gerar (AWS). Local: a do container RabbitMQ."
  type        = string
  default     = null
  sensitive   = true
}

variable "create_datadog_secret" {
  description = "Cria o segredo do Datadog. Precisa ser conhecido no plan (não derive de valor sensível)."
  type        = bool
  default     = false
}

variable "datadog_api_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "recovery_window_in_days" {
  description = "0 = apaga na hora (permite recriar o ambiente do zero)."
  type        = number
  default     = 0
}
