variable "name" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "app_port" {
  description = "Porta HTTP dos serviços (alvo do ALB)."
  type        = number
  default     = 8080
}
