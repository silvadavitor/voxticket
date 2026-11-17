# Um segredo por serviço; master só quando pedido (AWS).
mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix = "voxticket/test"
  databases = {
    "quota-service"  = "quota"
    "ticket-service" = "ticket"
  }
}

run "um_segredo_por_servico" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.db["quota-service"].name == "voxticket/test/db/quota-service"
    error_message = "Nome do segredo fora do padrão <prefixo>/db/<servico>."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.db) == 2
    error_message = "Deve existir exatamente um segredo por serviço."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.master) == 1
    error_message = "Na AWS (padrão) o segredo master é criado."
  }

  assert {
    condition     = alltrue([for s in aws_secretsmanager_secret.db : s.recovery_window_in_days == 0])
    error_message = "recovery_window 0 permite destroy + apply sem conflito de nome."
  }
}

run "local_sem_master" {
  command = plan

  variables {
    create_master_secret = false
    db_password          = "local"
    broker_password      = "guest"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.master) == 0
    error_message = "Local não deve criar segredo master."
  }
}
