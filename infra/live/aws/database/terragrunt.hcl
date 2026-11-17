include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//database"
}

dependency "network" {
  config_path                             = "../network"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    private_subnet_ids         = ["subnet-mock1", "subnet-mock2"]
    database_security_group_id = "sg-mock"
  }
}

dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    master_username = "mock"
    master_password = "mockmockmock"
  }
}

inputs = {
  name              = include.root.locals.name
  subnet_ids        = dependency.network.outputs.private_subnet_ids
  security_group_id = dependency.network.outputs.database_security_group_id
  master_username   = dependency.secrets.outputs.master_username
  master_password   = dependency.secrets.outputs.master_password
}
