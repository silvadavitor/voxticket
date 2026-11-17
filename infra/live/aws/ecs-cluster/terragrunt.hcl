include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//ecs-cluster"
}

dependency "storage" {
  config_path                             = "../storage"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    bucket_arn = "arn:aws:s3:::mock"
  }
}

inputs = {
  name           = include.root.locals.name
  bucket_arn     = dependency.storage.outputs.bucket_arn
  secrets_prefix = include.root.locals.secrets_prefix
}
