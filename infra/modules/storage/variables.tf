variable "bucket_name" {
  description = "Nome do bucket de áudios."
  type        = string
}

variable "failed_expiration_days" {
  description = "Dias até apagar objetos em failed/."
  type        = number
  default     = 7
}

variable "enable_lifecycle" {
  description = "Cria regras de lifecycle (desligue se o emulador não suportar)."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Permite destruir o bucket com objetos (ambiente acadêmico)."
  type        = bool
  default     = true
}
