#!/usr/bin/env bash
# Builda e envia todas as imagens para o ECR. Uso: IMAGE_TAG=v1 infra/scripts/push-images.sh
# Requer: aws cli logado na conta, docker, e o apply de infra/live/aws/ecr feito.
set -euo pipefail
cd "$(dirname "$0")/../.."

REGION=${AWS_REGION:-us-east-1}
TAG=${IMAGE_TAG:-latest}  # aws.sh exporta o hash do commit
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
PLATFORM=${PLATFORM:-linux/amd64}

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

for svc in services/*/; do
  name=$(basename "$svc")
  if [[ ! -f "$svc/Dockerfile" ]]; then echo "pulando $name (sem Dockerfile)"; continue; fi
  docker build --platform "$PLATFORM" -t "$REGISTRY/voxticket/$name:$TAG" "$svc"
  docker push "$REGISTRY/voxticket/$name:$TAG"
done

for job in db-init rabbitmq-init; do
  docker build --platform "$PLATFORM" -f "infra/docker/$job.Dockerfile" -t "$REGISTRY/voxticket/$job:$TAG" .
  docker push "$REGISTRY/voxticket/$job:$TAG"
done
