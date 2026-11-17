include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//secrets"
}

# Local: 1 container Postgres por serviço (docker-compose), todos com a senha do .env.
# Os segredos só espelham essas credenciais; não há usuário master nem db-init.
inputs = {
  name_prefix          = include.root.locals.secrets_prefix
  databases            = include.root.locals.databases
  db_password          = get_env("POSTGRES_PASSWORD")
  create_master_secret = false
  broker_username      = get_env("RABBITMQ_USER", "guest")
  broker_password      = get_env("RABBITMQ_PASSWORD", "guest")
}
