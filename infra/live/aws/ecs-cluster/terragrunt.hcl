include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//ecs-cluster"
}

inputs = {
  name           = include.root.locals.name
  secrets_prefix = include.root.locals.secrets_prefix
}
