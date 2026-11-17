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

variable "api_allowed_cidrs" {
  description = "Quem pode chamar a API no ALB. Ex.: [\"200.1.2.3/32\"] para liberar só o IP da apresentação."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
