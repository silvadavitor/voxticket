variable "bucket_name" {
  type = string
}

variable "source_dir" {
  description = "Pasta com os arquivos estáticos (index.html, app.js, styles.css...)."
  type        = string
}

variable "app_config" {
  description = "Vira window.VOXTICKET_CONFIG no config.js (apiBase, grafanaUrl, rabbitUrl...)."
  type        = map(string)
  default     = {}
}

variable "enable_cdn" {
  description = "Cria o CloudFront (AWS). false no MiniStack, onde o nginx do compose faz esse papel."
  type        = bool
  default     = true
}

variable "api_origin_domain" {
  description = "DNS do ALB da API (origem do /api/*). null = só o site estático."
  type        = string
  default     = null
}
