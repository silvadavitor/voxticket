#!/usr/bin/env bash
# Sobe / derruba o VoxTicket na AWS com um comando.
#
#   infra/scripts/aws.sh up        # tudo: orçamento, base, imagens, init, serviços
#   infra/scripts/aws.sh down      # destrói tudo (mantém só o bucket de state e o alerta de orçamento)
#   infra/scripts/aws.sh status    # URL da API e estado dos serviços
#   infra/scripts/aws.sh images    # só rebuild/push das imagens + redeploy
#
# Requer: aws cli autenticado (AWS_PROFILE ou SSO), terragrunt >= 1.2, terraform >= 1.10, docker.
# Variáveis: BUDGET_EMAILS (obrigatória no primeiro up), IMAGE_TAG (padrão: hash do commit),
#            AWS_REGION (padrão us-east-1), DD_API_KEY/DD_APP_KEY/DD_SITE (opcionais).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIVE="$ROOT/infra/live/aws"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export IMAGE_TAG="${IMAGE_TAG:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)}"
export TG_NON_INTERACTIVE=true

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
tg()  { (cd "$LIVE" && terragrunt "$@"); }
out() { tg run --working-dir "$1" output -raw "$2"; }

check_tools() {
  for t in aws terragrunt terraform docker; do
    command -v "$t" >/dev/null || { echo "faltando: $t"; exit 1; }
  done
  aws sts get-caller-identity --query Account --output text >/dev/null \
    || { echo "aws cli sem credencial (aws sso login / AWS_PROFILE)"; exit 1; }
}

budget() {
  log "1/6 alerta de orçamento (exigência do enunciado)"
  : "${BUDGET_EMAILS:?defina BUDGET_EMAILS=email1,email2}"
  tg run --working-dir budget --backend-bootstrap apply
}

base() {
  log "2/6 base: rede, S3, segredos, RDS, Amazon MQ, ECR, cluster (RDS ~5 min, MQ ~15 min)"
  tg run --all --backend-bootstrap \
    --filter '!./budget' --filter '!./ecs-init' --filter '!./ecs-services' --filter '!./datadog' \
    apply
}

images() {
  log "3/6 build + push das imagens (tag $IMAGE_TAG)"
  "$ROOT/infra/scripts/push-images.sh"
}

run_task() { # $1 = nome da task (db-init | rabbitmq-init)
  local cmd arn code
  cmd=$(tg run --working-dir ecs-init output -json init_task_run_commands | jq -r --arg k "$1" '.[$k]')
  arn=$(eval "$cmd --query 'tasks[0].taskArn' --output text")
  local cluster; cluster=$(out ecs-cluster cluster_name)
  echo "   $1: $arn"
  aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$arn"
  code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$arn" --query 'tasks[0].containers[0].exitCode' --output text)
  [[ "$code" == "0" ]] || { echo "   $1 falhou (exit $code). Logs: CloudWatch /ecs/voxticket-aws, stream $1/..."; exit 1; }
  echo "   $1 ok"
}

init() {
  log "4/6 tasks de init: databases/usuários no RDS e filas no Amazon MQ"
  tg run --working-dir ecs-init apply
  run_task db-init
  run_task rabbitmq-init
}

services() {
  log "5/6 serviços no ECS (ALB, 6 serviços, autoescala do worker)"
  tg run --working-dir ecs-services apply
  if [[ -n "${DD_API_KEY:-}" && -n "${DD_APP_KEY:-}" ]]; then
    log "    dashboard e monitores do Datadog"
    tg run --working-dir datadog apply
  fi
}

status() {
  log "6/6 status"
  echo "API: $(out ecs-services api_url)"
  aws ecs describe-services --cluster "$(out ecs-cluster cluster_name)" \
    --services $(tg run --working-dir ecs-services output -json service_names | jq -r '.[]') \
    --query 'services[].[serviceName,runningCount,desiredCount]' --output table
}

down() {
  log "destruindo tudo (exceto alerta de orçamento e bucket de state)"
  tg run --all --filter '!./budget' destroy
  log "pronto: nenhum recurso cobrando além do bucket de state (centavos)."
}

check_tools
case "${1:-}" in
  up)       budget; base; images; init; services; status ;;
  down)     down ;;
  status)   status ;;
  images)   images; services ;;
  *)        sed -n '2,12p' "$0"; exit 1 ;;
esac
