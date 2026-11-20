# RabbitMQ em EC2 (mesma imagem do local), disco EBS próprio para as filas. Ver ADR-002.

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
    public_subnet_ids        = ["subnet-mock1", "subnet-mock2"]
    broker_security_group_id = "sg-mock"
  }
}

dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    broker_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-broker"
  }
}

inputs = {
  name              = include.root.locals.name
  region            = include.root.locals.aws_region
  subnet_id         = dependency.network.outputs.public_subnet_ids[0] # sem NAT: precisa de saída; SG fechado para fora
  security_group_id = dependency.network.outputs.broker_security_group_id
  broker_secret_arn = dependency.secrets.outputs.broker_secret_arn
}
