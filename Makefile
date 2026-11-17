# Atalhos do VoxTicket. `make` ou `make help` lista tudo.
.DEFAULT_GOAL := help
COMPOSE := docker compose --profile apps

help: ## lista os comandos
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36mmake %-14s\033[0m %s\n", $$1, $$2}'

# ---------- local ----------
env: ## cria o .env a partir do exemplo (se não existir)
	@test -f .env || cp .env.example .env

infra: env ## sobe só a infraestrutura local (MiniStack, RabbitMQ, Postgres, OTel)
	docker compose up -d --build

up: env ## sobe tudo localmente (infra + serviços)
	$(COMPOSE) up -d --build

ps: ## estado dos containers
	$(COMPOSE) ps -a

logs: ## logs ao vivo (make logs s=quota-service)
	$(COMPOSE) logs -f $(s)

down: ## para tudo e mantém os dados
	$(COMPOSE) down

reset: ## para tudo e APAGA bancos, filas e S3 locais
	$(COMPOSE) down -v

f%: ## roda um cenário de falha (make f5)
	@ls scripts/failures/F$*-*.sh >/dev/null && bash scripts/failures/F$*-*.sh

# ---------- qualidade ----------
test: ## valida infra: fmt, validate e testes dos módulos Terraform, HCL do Terragrunt, compose
	terraform fmt -check -recursive infra/modules
	@for m in infra/modules/*/; do \
	  echo "== $$m"; \
	  (cd $$m && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color && \
	   if ls tests/*.tftest.hcl >/dev/null 2>&1; then terraform test -no-color; fi) || exit 1; \
	done
	cd infra/live && terragrunt hcl fmt --check
	docker compose --env-file .env.example --profile apps config -q

# ---------- AWS ----------
aws-up: ## cria TUDO na AWS (precisa BUDGET_EMAILS=...)
	infra/scripts/aws.sh up

aws-down: ## destrói TUDO na AWS (rodar depois da apresentação!)
	infra/scripts/aws.sh down

aws-status: ## URL da API e réplicas rodando na AWS
	infra/scripts/aws.sh status

aws-deploy: ## rebuild das imagens e redeploy dos serviços na AWS
	infra/scripts/aws.sh images

.PHONY: help env infra up ps logs down reset test aws-up aws-down aws-status aws-deploy
