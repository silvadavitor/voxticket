# Testes do VoxTicket. `make` ou `make help` lista tudo.
# Subir, parar e ver logs é com o docker compose direto:
#   docker compose up -d --build     docker compose ps     docker compose logs -f <serviço>
#   docker compose down              docker compose down -v (apaga os dados)
.DEFAULT_GOAL := help

help: ## lista os comandos
	@grep -E '^[a-zA-Z0-9%_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36mmake %-14s\033[0m %s\n", $$1, $$2}'

# ---------- requisitos e cenários de falha (precisam do sistema rodando) ----------
check: ## verifica os requisitos (rápido): R3–R6 + F3, F4, F5, com placar no fim
	@bash scripts/check.sh rapido

check-all: ## verifica TODOS os requisitos e cenários F1–F8 (~10–15 min), com placar
	@bash scripts/check.sh completo

f%: ## roda um cenário de falha narrado (make f5; PAUSA=1 make f5 para passo a passo)
	@ls scripts/failures/F$*-*.sh >/dev/null && bash scripts/failures/F$*-*.sh

publish: ## publica um evento de teste no RabbitMQ (make publish t=CategorizationRequested f=evento.json)
	@scripts/dev/publish.sh $(t) $(f)

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
	docker compose --env-file .env.example config -q

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

.PHONY: help check check-all publish otel-test test aws-bootstrap aws-up aws-down aws-status aws-deploy
