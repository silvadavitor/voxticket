# Dashboard/monitores do Datadog para o ambiente local. Ignorado enquanto não houver chaves.
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

exclude {
  if      = get_env("DD_API_KEY", "") == "" || get_env("DD_APP_KEY", "") == ""
  actions = ["all"]
}

terraform {
  source = "${include.root.locals.modules_dir}//datadog"
}

inputs = {
  environment = include.root.locals.environment
}
