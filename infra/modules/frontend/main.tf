# Front estático: arquivos num bucket S3 PRIVADO, entregues pelo CloudFront.
# - AWS: CloudFront (HTTPS grátis em *.cloudfront.net) com duas origens:
#     /*      → bucket S3 (Origin Access Control: só o CloudFront lê o bucket)
#     /api/*  → ALB do request-service (mesma origem para o navegador: sem CORS)
# - MiniStack (enable_cdn = false): só o bucket + arquivos; o nginx do compose faz o papel do CloudFront.

locals {
  files = fileset(var.source_dir, "**")
  content_types = {
    html = "text/html; charset=utf-8"
    css  = "text/css; charset=utf-8"
    js   = "application/javascript; charset=utf-8"
    json = "application/json"
    svg  = "image/svg+xml"
    png  = "image/png"
    ico  = "image/x-icon"
    txt  = "text/plain; charset=utf-8"
    mp3  = "audio/mpeg"
  }
  # configuração em tempo de deploy (o app.js lê window.VOXTICKET_CONFIG)
  config_js = "window.VOXTICKET_CONFIG = ${jsonencode(var.app_config)};\n"
}

resource "aws_s3_bucket" "site" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "file" {
  for_each     = { for f in local.files : f => f if f != "config.js" && !endswith(f, ".conf") }
  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${var.source_dir}/${each.value}"
  etag         = filemd5("${var.source_dir}/${each.value}")
  content_type = lookup(local.content_types, reverse(split(".", each.value))[0], "application/octet-stream")
}

resource "aws_s3_object" "config" {
  bucket        = aws_s3_bucket.site.id
  key           = "config.js"
  content       = local.config_js
  content_type  = local.content_types.js
  cache_control = "no-store"
}

# ---------------- CloudFront (só na AWS) ----------------

data "aws_cloudfront_cache_policy" "optimized" {
  count = var.enable_cdn ? 1 : 0
  name  = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  count = var.enable_cdn ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  count = var.enable_cdn ? 1 : 0
  name  = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "site" {
  count                             = var.enable_cdn ? 1 : 0
  name                              = var.bucket_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# /api/audios → /audios no ALB (o request-service não conhece o prefixo; igual ao nginx local)
resource "aws_cloudfront_function" "strip_api" {
  count   = var.enable_cdn && var.api_origin_domain != null ? 1 : 0
  name    = "${var.bucket_name}-strip-api"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      request.uri = request.uri.replace(/^\/api/, "") || "/";
      return request;
    }
  JS
}

resource "aws_cloudfront_distribution" "site" {
  count               = var.enable_cdn ? 1 : 0
  enabled             = true
  comment             = "${var.bucket_name} (front estático + /api)"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # só América do Norte e Europa: mais barato
  http_version        = "http2and3"

  origin {
    origin_id                = "site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site[0].id
  }

  dynamic "origin" {
    for_each = var.api_origin_domain == null ? [] : [1]
    content {
      origin_id   = "api"
      domain_name = var.api_origin_domain
      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only" # ALB sem certificado (sem domínio próprio)
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized[0].id
    compress               = true
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.api_origin_domain == null ? [] : [1]
    content {
      path_pattern             = "/api/*"
      target_origin_id         = "api"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled[0].id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host[0].id

      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.strip_api[0].arn
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Só o CloudFront desta distribuição lê o bucket
data "aws_iam_policy_document" "site" {
  count = var.enable_cdn ? 1 : 0
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site[0].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  count      = var.enable_cdn ? 1 : 0
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.site[0].json
  depends_on = [aws_s3_bucket_public_access_block.site]
}
