include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//secrets"
}

# AWS: senhas master e do broker são geradas (random_password).
inputs = {
  name_prefix = include.root.locals.secrets_prefix
  databases   = include.root.locals.databases
}
