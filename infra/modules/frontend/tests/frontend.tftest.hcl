# Bucket privado, todos os arquivos publicados com content-type certo, CloudFront só na AWS.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_data "aws_cloudfront_cache_policy" {
    defaults = { id = "cache-policy" }
  }
  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = { id = "origin-policy" }
  }
}

variables {
  bucket_name = "voxticket-test-frontend"
  source_dir  = "../../../frontend"
  app_config  = { apiBase = "/api" }
}

run "site_na_aws" {
  command = plan

  variables {
    api_origin_domain = "alb.example.com"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.site.restrict_public_buckets
    error_message = "O bucket do site não pode ser público: só o CloudFront lê."
  }

  assert {
    condition     = aws_s3_object.file["index.html"].content_type == "text/html; charset=utf-8"
    error_message = "index.html precisa de content-type text/html."
  }

  assert {
    condition     = aws_s3_object.file["app.js"].content_type == "application/javascript; charset=utf-8"
    error_message = "app.js precisa de content-type JavaScript."
  }

  assert {
    condition     = strcontains(aws_s3_object.config.content, "\"apiBase\":\"/api\"")
    error_message = "config.js deve carregar a configuração do app."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.site) == 1 && one(aws_cloudfront_distribution.site[0].default_cache_behavior).viewer_protocol_policy == "redirect-to-https"
    error_message = "CloudFront deve existir e forçar HTTPS."
  }

  assert {
    condition     = one(aws_cloudfront_distribution.site[0].ordered_cache_behavior).path_pattern == "/api/*"
    error_message = "/api/* deve ir para a origem da API."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.strip_api[0].code, "replace")
    error_message = "A function que tira o prefixo /api deve existir."
  }
}

run "ministack_sem_cloudfront" {
  command = plan

  variables {
    enable_cdn = false
  }

  assert {
    condition     = length(aws_cloudfront_distribution.site) == 0 && length(aws_s3_bucket_policy.site) == 0
    error_message = "No MiniStack não cria CloudFront (o nginx do compose simula)."
  }

  assert {
    condition     = !contains(keys(aws_s3_object.file), "nginx.conf")
    error_message = "Arquivo de config do nginx não deve ser publicado no bucket."
  }
}
