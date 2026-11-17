output "address" {
  description = "Host do Postgres (vai para DB_HOST dos serviços)."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}
