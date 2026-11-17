variable "name" {
  type = string
}

variable "limit_usd" {
  type    = string
  default = "20"
}

variable "emails" {
  description = "Quem recebe o alerta."
  type        = list(string)
}
