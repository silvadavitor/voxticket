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

# serviços que já têm Dockerfile (os outros ainda não existem e quebrariam o build)
READY := $(patsubst services/%/Dockerfile,%,$(wildcard services/*/Dockerfile))

up: env ## sobe a infra + todos os serviços que já têm Dockerfile
	docker compose up -d --build
	@if [ -n "$(READY)" ]; then $(COMPOSE) up -d --build $(READY); fi
	@echo "serviços no ar: $(or $(READY),nenhum ainda)"

svc: env ## sobe só um serviço e as dependências dele (make svc s=quota-service)
	@test -n "$(s)" || { echo "uso: make svc s=<servico>"; exit 1; }
	$(COMPOSE) up -d --build $(s)

publish: ## publica um evento de teste no RabbitMQ (make publish t=CategorizationRequested f=evento.json)
	@scripts/dev/publish.sh $(t) $(f)

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
# O caminho oficial é o GitHub Actions (infra-up / deploy / infra-destroy).
# Estes alvos usam o atalho local infra/scripts/aws.sh (não versionado; só quem opera a infra tem).
AWS_SH := infra/scripts/aws.sh
aws-check = @test -x $(AWS_SH) || { echo "$(AWS_SH) é local e não está neste clone. Use os workflows do GitHub Actions (veja infra/README.md)."; exit 1; }

aws-bootstrap: ## [local] UMA vez, com admin: orçamento + OIDC (BUDGET_EMAILS=... GITHUB_REPOSITORY=owner/repo)
	$(aws-check)
	$(AWS_SH) bootstrap

aws-up: ## [local] cria tudo na AWS sem passar pelo CI
	$(aws-check)
	$(AWS_SH) up

aws-deploy: ## [local] rebuild das imagens + release
	$(aws-check)
	$(AWS_SH) deploy

aws-status: ## [local] URL da API e réplicas
	$(aws-check)
	$(AWS_SH) status

aws-down: ## [local] destrói tudo na AWS
	$(aws-check)
	$(AWS_SH) down

.PHONY: help env infra up svc publish ps logs down reset test aws-bootstrap aws-up aws-down aws-status aws-deploy
