# Front estático publicado no S3 do MiniStack. O container `frontend` (nginx) faz o papel do CloudFront:
# entrega o site a partir deste bucket e repassa /api para o request-service.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//frontend"
}

inputs = {
  bucket_name = "${include.root.locals.name}-frontend"
  source_dir  = "${include.root.locals.repo_root}/frontend"
  enable_cdn  = false
  app_config = {
    apiBase    = "/api"
    grafanaUrl = "http://localhost:3000"
    rabbitUrl  = "http://localhost:15672"
  }
}
