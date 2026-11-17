include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//messaging"
}

dependency "network" {
  config_path                             = "../network"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    private_subnet_ids       = ["subnet-mock1", "subnet-mock2"]
    broker_security_group_id = "sg-mock"
  }
}

dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    broker_username = "mock"
    broker_password = "mockmockmock"
  }
}

inputs = {
  name              = include.root.locals.name
  subnet_ids        = dependency.network.outputs.private_subnet_ids
  security_group_id = dependency.network.outputs.broker_security_group_id
  username          = dependency.secrets.outputs.broker_username
  password          = dependency.secrets.outputs.broker_password
}
