variable "project" {
  description = "Prefixo dos recursos do projeto (roles que o CI pode gerenciar: <project>-*)."
  type        = string
}

variable "github_repository" {
  description = "owner/repo que pode assumir a role, ex.: silvadavitor/voxticket."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use o formato owner/repo."
  }
}

variable "github_environment" {
  description = "Environment do GitHub usado pelos workflows de deploy/destroy."
  type        = string
  default     = "aws"
}

variable "role_name" {
  description = "Nome da role. Não pode começar com <project>- (senão o CI poderia alterar a si mesmo)."
  type        = string
  default     = "gha-voxticket-deploy"
}

variable "create_oidc_provider" {
  description = "false se a conta já tem o provider token.actions.githubusercontent.com (só pode existir um)."
  type        = bool
  default     = true
}

variable "plan_role_name" {
  description = "Role somente leitura (plan em PR). Também não pode começar com <project>-."
  type        = string
  default     = "gha-voxticket-plan"
}
