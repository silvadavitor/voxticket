include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//network"
}

inputs = {
  name     = include.root.locals.name
  cidr     = "10.40.0.0/16"
  app_port = 8080
}
