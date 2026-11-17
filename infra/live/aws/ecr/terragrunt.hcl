include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//ecr"
}

inputs = {
  prefix       = include.root.locals.project
  repositories = concat(keys(include.root.locals.databases), ["db-init", "rabbitmq-init"])
}
