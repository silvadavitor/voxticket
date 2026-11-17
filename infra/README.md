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
│   ├── ecs-services/        #   Fargate: serviços, role por serviço, ALB, Cloud Map, autoescala [só aws]
│   ├── budget/              #   alerta de orçamento                          [só aws]
│   └── datadog/             #   dashboard + monitores (só com DD_API_KEY/DD_APP_KEY)
├── live/
│   ├── root.hcl             # provider (MiniStack x AWS), backend de estado, nomes comuns
│   ├── ministack/           # env local: storage, secrets, datadog
│   └── aws/                 # env de entrega: budget → network → storage → secrets → database,
│                            #   messaging, ecr, ecs-cluster → ecs-init → ecs-services, datadog
├── docker/                  # imagens: terragrunt (infra-init), db-init (só AWS), rabbitmq-init
└── scripts/                 # aws.sh (up/down), db-init.sh, rabbitmq-init.sh, push-images.sh

Cada módulo com regra importante tem `tests/*.tftest.hcl` (rodam com `make test`, sem conta AWS).
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

Pré-requisitos: AWS CLI autenticado (`aws sso login` ou `AWS_PROFILE`), Terragrunt ≥ 1.2,
Terraform ≥ 1.10, Docker e `jq`.

```bash
BUDGET_EMAILS="a@x.com,b@y.com" make aws-up   # ~25 min na primeira vez
make aws-status                                # URL da API + réplicas
make aws-deploy                                # rebuild das imagens + redeploy (após mudar código)
make aws-down                                  # destrói tudo
```

O que o `make aws-up` ([`scripts/aws.sh`](scripts/aws.sh)) faz, na ordem:

| # | Passo | Units |
|---|---|---|
| 1 | Alerta de orçamento (o enunciado exige antes do primeiro deploy) e bucket do state (`--backend-bootstrap`) | `budget` |
| 2 | Base: rede, S3, segredos, RDS (~5 min), Amazon MQ (~15 min), ECR, cluster | `network storage secrets database messaging ecr ecs-cluster` |
| 3 | Build e push das imagens (tag = hash do commit) | `scripts/push-images.sh` |
| 4 | Tasks de init: `db-init` (databases e usuários) e `rabbitmq-init` (filas e DLQs); espera terminar e confere o exit code | `ecs-init` |
| 5 | Serviços: ALB, 6 serviços, autoescala do worker; Datadog se houver chaves | `ecs-services datadog` |

`make aws-down` destrói tudo, **exceto** o alerta de orçamento (grátis) e o bucket de state (centavos).
O destroy funciona sem passo manual: bucket e ECR com `force_destroy`, segredos sem janela de
recuperação, RDS sem snapshot final e sem proteção contra deleção. Dá para rodar `aws-down` e
`aws-up` em seguida quantas vezes quiser; é a demonstração do bônus de IaC.

Variáveis opcionais: `AWS_REGION` (us-east-1), `IMAGE_TAG`, `API_ALLOWED_CIDRS` (restringe a API, ex.:
`"200.1.2.3/32"`), `DD_API_KEY`, `DD_APP_KEY`, `DD_SITE`, `BUDGET_LIMIT_USD` (20).

Comandos avulsos, se precisar:

```bash
cd infra/live/aws
terragrunt run --all plan                      # o que mudaria
terragrunt run --working-dir ecs-services apply
```

## Custo estimado (us-east-1, ligado 24 h)

RDS `db.t4g.micro` + Amazon MQ `mq.t3.micro` + 8 tasks Fargate 0.25 vCPU + ALB ≈ **US$ 3–4/dia**.
Suba perto da apresentação e rode `make aws-down` logo depois.
Sem NAT Gateway: as tasks usam subnet pública com IP público, e o RDS e o MQ ficam em subnet privada.

## Decisões e pendências

- ADRs em [`docs/adr/`](../docs/adr/).
- `TODO(infra)` no código: imagem do MiniStack, suporte a lifecycle no MiniStack, versão do RabbitMQ no Amazon MQ.
