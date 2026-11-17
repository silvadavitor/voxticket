variable "prefix" {
  type = string
}

variable "repositories" {
  description = "Nomes das imagens (serviços + jobs de init)."
  type        = list(string)
}
