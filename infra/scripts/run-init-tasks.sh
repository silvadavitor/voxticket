#!/usr/bin/env bash
# Roda as tasks one-off db-init e rabbitmq-init no ECS, espera terminar e falha se o exit code != 0.
# Usado pelo workflow release e localmente. Requer: aws cli, terragrunt, jq; ecs-init já aplicado.
set -euo pipefail
LIVE="$(cd "$(dirname "$0")/../live/aws" && pwd)"
tg() { (cd "$LIVE" && terragrunt "$@"); }

cluster=$(tg run --working-dir ecs-cluster --tf-forward-stdout -- output -raw cluster_name)
commands=$(tg run --working-dir ecs-init --tf-forward-stdout -- output -json init_task_run_commands)

for task in db-init rabbitmq-init; do
  cmd=$(jq -r --arg k "$task" '.[$k]' <<<"$commands")
  arn=$(eval "$cmd --query 'tasks[0].taskArn' --output text")
  echo "$task: $arn"
  aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$arn"
  code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$arn" --query 'tasks[0].containers[0].exitCode' --output text)
  if [[ "$code" != "0" ]]; then
    echo "::error::$task falhou (exit $code). Logs no CloudWatch: /ecs/$cluster, stream $task/..."
    exit 1
  fi
  echo "$task ok"
done
