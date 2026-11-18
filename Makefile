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

# ---------- observabilidade ----------
grafana: ## abre o Grafana local (traces, métricas, logs, dashboard VoxTicket)
	@echo "http://localhost:3000/d/voxticket-saga"; (xdg-open http://localhost:3000/d/voxticket-saga >/dev/null 2>&1 || open http://localhost:3000/d/voxticket-saga >/dev/null 2>&1 || true)

otel-test: ## manda traces, métricas e logs sintéticos pelo collector (testa o pipeline sem serviço pronto)
	@for sig in traces metrics logs; do \
	  docker run --rm --network voxticket_default ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.165.0 $$sig \
	    --otlp-endpoint otel-collector:4317 --otlp-insecure --service voxticket-smoke --duration 5s --rate 5 >/dev/null 2>&1 \
	  && echo "ok: $$sig enviado"; \
	done; echo "Veja em http://localhost:3000 → Explore (service.name = voxticket-smoke)"

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

.PHONY: help env infra up ps logs down reset test grafana otel-test aws-bootstrap aws-up aws-down aws-status aws-deploy
