variable "environment" {
  description = "Valor da tag env (local, aws)."
  type        = string
}

variable "notify" {
  description = "Handles de notificação dos monitores, ex.: @email@dominio.com. Vazio = sem notificação."
  type        = string
  default     = ""
}

variable "compensation_threshold" {
  type    = number
  default = 5
}
