# Aplicar ANTES de qualquer outra coisa (exigência do enunciado):
#   BUDGET_EMAILS="a@x.com,b@y.com" terragrunt run --backend-bootstrap -- apply -auto-approve  (nesta pasta)
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//budget"
}

inputs = {
  name      = "${include.root.locals.name}-budget"
  limit_usd = get_env("BUDGET_LIMIT_USD", "20")
  emails    = compact(split(",", get_env("BUDGET_EMAILS", ""))) # obrigatório no apply (variable BUDGET_EMAILS no GitHub)
}
