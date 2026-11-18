output "bucket_name" {
  value = aws_s3_bucket.site.bucket
}

output "site_url" {
  description = "URL pública (HTTPS) do front na AWS."
  value       = try("https://${aws_cloudfront_distribution.site[0].domain_name}", null)
}
