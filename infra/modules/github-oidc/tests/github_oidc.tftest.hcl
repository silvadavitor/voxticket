# A role só pode ser assumida pelo repositório certo e não pode se autoalterar.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

variables {
  project           = "voxticket"
  github_repository = "silvadavitor/voxticket"
}

run "role_fora_do_padrao_do_projeto" {
  command = plan

  assert {
    condition     = !startswith(aws_iam_role.deploy.name, "${var.project}-")
    error_message = "A role de deploy não pode casar com <project>-* (ela se autoalteraria)."
  }

  assert {
    condition     = !startswith(aws_iam_role.plan.name, "${var.project}-")
    error_message = "A role de plan também fica fora do padrão <project>-*."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.plan_readonly.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "A role de plan precisa ser somente leitura."
  }
}

run "repositorio_invalido" {
  command = plan

  variables {
    github_repository = "qualquer-coisa"
  }

  expect_failures = [var.github_repository]
}
