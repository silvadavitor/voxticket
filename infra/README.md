# Infra — Terraform + Terragrunt

Mesmos módulos, dois ambientes:

```
infra/
├── modules/                 # Terraform puro, sem nada específico de ambiente
│   ├── storage/             #   S3 (audios/, transcripts/, failed/ + lifecycle)
│   ├── secrets/             #   Secrets Manager (1 por serviço, broker, datadog; master só na AWS)
│   ├── network/             #   VPC (sem NAT) + security groups              [só aws]
│   ├── database/            #   RDS Postgres                                 [só aws]
│   ├── messaging/           #   Amazon MQ for RabbitMQ                       [só aws]
│   ├── ecr/                 #   repositórios de imagens                      [só aws]
│   ├── ecs-cluster/         #   cluster, logs, IAM                           [só aws]
│   ├── ecs-services/        #   Fargate: serviços, ALB, Cloud Map, tasks init [só aws]
│   ├── budget/              #   alerta de orçamento                          [só aws]
│   └── datadog/             #   dashboard + monitores (só com DD_API_KEY/DD_APP_KEY)
├── live/
│   ├── root.hcl             # provider (MiniStack x AWS), backend de estado, nomes comuns
│   ├── ministack/           # env local: storage, secrets, datadog
│   └── aws/                 # env de entrega: budget → network → storage → secrets → database,
│                            #   messaging, ecr, ecs-cluster → ecs-services, datadog
├── docker/                  # imagens: terragrunt (infra-init), db-init (só AWS), rabbitmq-init
└── scripts/                 # db-init.sh, rabbitmq-init.sh, push-images.sh
```

## Local (MiniStack)

Automático: o `docker compose up` roda o container `infra-init`, que executa
`terragrunt run --all apply` em `live/ministack`. O estado fica no volume `tfstate`.

Para rodar na mão (com Terragrunt ≥ 1.2 e o MiniStack em `localhost:4566`):

```bash
cd infra/live/ministack
export AWS_ENDPOINT_URL=http://localhost:4566 POSTGRES_PASSWORD=... # mesmo valor do .env
terragrunt run --all plan
```

## AWS (entrega)

Pré-requisitos: AWS CLI autenticado (`AWS_PROFILE`), Terragrunt ≥ 1.2, Terraform ≥ 1.10, Docker.

```bash
cd infra/live/aws

# 0. alerta de orçamento ANTES de tudo (exigência do enunciado).
#    --backend-bootstrap cria o bucket do state (voxticket-tfstate-<account>) na primeira vez.
BUDGET_EMAILS="voce@exemplo.com" terragrunt run --working-dir budget --backend-bootstrap apply

# 1. base: rede, bucket, segredos, banco, broker, ECR, cluster (RDS ~5 min, Amazon MQ ~15 min)
terragrunt run --all --backend-bootstrap --filter '!./ecs-services' --filter '!./datadog' --filter '!./budget' apply

# 2. imagens
IMAGE_TAG=v1 ../../scripts/push-images.sh

# 3. serviços (+ otel-collector se DD_API_KEY estiver definido)
IMAGE_TAG=v1 terragrunt run --working-dir ecs-services apply

# 4. init (uma vez): copie os comandos do output
terragrunt run --working-dir ecs-services output init_task_run_commands

# 5. URL da API
terragrunt run --working-dir ecs-services output api_url
```

**Depois da apresentação:** `terragrunt run --all destroy` (custo é responsabilidade do grupo).

## Custo estimado (us-east-1, ligado 24 h)

RDS `db.t4g.micro` + Amazon MQ `mq.t3.micro` + 8 tasks Fargate 0.25 vCPU + ALB ≈ **US$ 3–4/dia**.
Sem NAT Gateway: as tasks usam subnet pública com IP público, e o RDS e o MQ ficam em subnet privada.

## Decisões e pendências

- ADRs em [`docs/adr/`](../docs/adr/).
- `TODO(infra)` no código: imagem do MiniStack, suporte a lifecycle no MiniStack, versão do RabbitMQ no Amazon MQ.
