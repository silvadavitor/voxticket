# Front estático: S3 privado + CloudFront (HTTPS em *.cloudfront.net), /api/* → ALB.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//frontend"
}

dependency "ecs_services" {
  config_path                             = "../ecs-services"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs                            = { alb_dns_name = "mock-alb.us-east-1.elb.amazonaws.com" }
}

inputs = {
  bucket_name       = "${include.root.locals.name}-frontend${include.root.locals.env_cfg.locals.bucket_suffix}"
  source_dir        = "${include.root.locals.repo_root}/frontend"
  enable_cdn        = true
  api_origin_domain = dependency.ecs_services.outputs.alb_dns_name
  app_config = {
    apiBase    = "/api"
    grafanaUrl = get_env("GRAFANA_URL", "")
    rabbitUrl  = get_env("RABBIT_URL", "")
  }
}
