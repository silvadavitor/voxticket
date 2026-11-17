# Bootstrap do CI/CD (OIDC GitHub → AWS). Aplicar UMA vez, localmente, com admin:
#   ver infra/README.md, seção "Configuração (uma vez)"
# Fica fora do destroy (workflow infra-destroy).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//github-oidc"
}

inputs = {
  project              = include.root.locals.project
  github_repository    = get_env("GITHUB_REPOSITORY", "silvadavitor/voxticket")
  create_oidc_provider = get_env("CREATE_OIDC_PROVIDER", "true") == "true"
}
