variable "name" {
  type = string
}

variable "bucket_arn" {
  description = "Bucket de áudios que os serviços podem ler/escrever."
  type        = string
}

variable "secrets_prefix" {
  description = "Prefixo dos segredos do projeto, ex.: voxticket/aws."
  type        = string
}
