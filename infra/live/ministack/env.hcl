# Ambiente local: MiniStack (AWS emulada). Só S3 e Secrets Manager;
# RabbitMQ e Postgres rodam como containers do docker-compose.
locals {
  environment   = "local"
  aws_region    = get_env("AWS_REGION", "us-east-1")
  is_ministack  = true
  bucket_suffix = ""
}
