# Bootstrap do CI/CD: o GitHub Actions assume esta role via OIDC (sem chave de acesso guardada no GitHub).
# Aplicado UMA vez, localmente, com credencial de administrador: `make aws-bootstrap`.
# Sobrevive ao `make aws-down` (fica fora dos filtros de destroy).

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
  account_id        = data.aws_caller_identity.current.account_id
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Só este repositório e só jobs no environment protegido (apply/destroy)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  description          = "Deploy do ${var.project} pelo GitHub Actions (${var.github_repository})"
}

# Serviços gerenciados (VPC, S3, RDS, MQ, ECS, ECR, Secrets, CloudWatch, Budgets...).
# PowerUserAccess NÃO inclui IAM: o IAM vem abaixo, restrito aos recursos do projeto.
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "iam_scoped" {
  statement {
    sid = "ProjectRolesOnly"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:PassRole",
    ]
    # o nome da role de deploy NÃO casa com este padrão: o CI não consegue alterar as próprias permissões
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
  }
}

resource "aws_iam_role_policy" "iam_scoped" {
  name   = "project-iam-only"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.iam_scoped.json
}

# ---------------- role SÓ LEITURA: plan em PR e checagem "a infra existe?" ----------------

data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:pull_request",
        "repo:${var.github_repository}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = var.plan_role_name
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
  description          = "terragrunt plan (somente leitura) do ${var.project} pelo GitHub Actions"
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess não lê valor de segredo, e o refresh do Terraform precisa (aws_secretsmanager_secret_version)
data "aws_iam_policy_document" "plan_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:*:${local.account_id}:secret:${var.project}/*"]
  }
}

resource "aws_iam_role_policy" "plan_secrets" {
  name   = "read-project-secrets"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_secrets.json
}
