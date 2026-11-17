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
│   ├── github-oidc/         #   OIDC + roles de deploy e de plan do CI       [só aws]
│   └── datadog/             #   dashboard + monitores (só com DD_API_KEY/DD_APP_KEY)
├── live/
│   ├── root.hcl             # provider (MiniStack x AWS), backend de estado, nomes comuns
│   ├── ministack/           # env local: storage, secrets, datadog
│   └── aws/                 # env de entrega: budget, github-oidc (bootstrap) → network → storage → secrets
│                            #   → database, messaging, ecr, ecs-cluster → ecs-init → ecs-services, datadog
├── docker/                  # imagens: terragrunt (infra-init), db-init (só AWS), rabbitmq-init
└── scripts/                 # run-init-tasks.sh, db-init.sh, rabbitmq-init.sh

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

## AWS (entrega): pelo GitHub Actions

Nenhuma chave da AWS fica no GitHub. Cada workflow troca um token **OIDC** do GitHub por credenciais
temporárias de uma role que **só este repositório** consegue assumir.

| Workflow | Gatilho | O que faz | Role |
|---|---|---|---|
| `ci` | todo push e PR | `make test`, Checkov, `docker build` | nenhuma |
| `infra-plan` | PR que mexe em `infra/` | `terragrunt plan` de tudo, resultado no resumo do job | **somente leitura** |
| `deploy` | push na `main` | **se a infra existe**: build com cache e push no ECR (tag = SHA), aplica mudanças da infra, roda o init, atualiza o ECS. **Se não existe, só avisa** | deploy, environment `aws` |
| `infra-up` | manual | cria tudo do zero (~25 min) e faz o primeiro release | deploy, environment `aws` |
| `infra-destroy` | manual, digitando `destruir` | destrói tudo (mantém state, orçamento e OIDC) | deploy, environment `aws` |

Por que assim:
- **Push nunca cria infra.** Com a infra destruída, um merge não volta a gerar custo; criar é sempre manual (`infra-up`).
- **Plan no PR, apply só depois do merge.** O time vê o que vai mudar antes de aprovar.
- **Duas roles.** A de plan é somente leitura e roda sem aprovação. A de deploy só funciona no environment
  `aws`, que pode exigir aprovação manual ("Required reviewers").
- **Imagem imutável por commit**, com cache de camadas. O ECS troca as tasks sem derrubar o serviço
  (circuit breaker com rollback automático).
- **`concurrency: aws-infra`**: nunca roda dois applies ou destroys ao mesmo tempo no mesmo state.
- Só sobem os serviços que já têm `Dockerfile`.

### Configuração (uma vez)

1. **Bootstrap, na máquina de quem opera a infra, com credencial de administrador:** cria o alerta de
   orçamento (o enunciado exige antes do primeiro deploy), o provedor OIDC e as duas roles (unit
   `github-oidc`). Pode ser feito pelo atalho local `make aws-bootstrap` ou direto:
   ```bash
   cd infra/live/aws
   export BUDGET_EMAILS="a@x.com,b@y.com" GITHUB_REPOSITORY=silvadavitor/voxticket
   terragrunt run --working-dir budget --backend-bootstrap -- apply -auto-approve
   terragrunt run --working-dir github-oidc -- apply -auto-approve   # CREATE_OIDC_PROVIDER=false se a conta já tiver o provider
   terragrunt run --working-dir github-oidc --tf-forward-stdout -- output
   ```
2. **No GitHub, em Settings → Environments:** crie o environment `aws`. Recomendado: adicionar "Required reviewers".
3. **No GitHub, em Settings → Secrets and variables → Actions:**

   | Tipo | Nome | Valor |
   |---|---|---|
   | Variable | `AWS_ROLE_ARN` | output `role_arn` |
   | Variable | `AWS_PLAN_ROLE_ARN` | output `plan_role_arn` |
   | Variable | `AWS_REGION` | `us-east-1` |
   | Variable | `BUDGET_EMAILS` | e-mails do alerta, separados por vírgula |
   | Variable | `API_ALLOWED_CIDRS` | opcional, ex.: `200.1.2.3/32` |
   | Variable | `DD_SITE` | opcional, ex.: `us5.datadoghq.com` |
   | Secret | `DD_API_KEY`, `DD_APP_KEY` | opcionais (Datadog) |

4. **Actions → infra-up → Run workflow.** Daí em diante, todo merge na `main` faz deploy sozinho.
   Depois da apresentação: **Actions → infra-destroy**.

**Permissões:**
- **Role de deploy:** `PowerUserAccess` (serviços gerenciados, sem IAM) mais IAM **só** em roles
  `voxticket-*`. O nome dela (`gha-voxticket-deploy`) não segue esse padrão, então o CI não consegue
  alterar as próprias permissões.
- **Role de plan:** `ReadOnlyAccess` mais leitura dos segredos do projeto, que o refresh do Terraform
  precisa.

### Sem CI (manual, mesma ordem dos workflows)

```bash
cd infra/live/aws
terragrunt run --all --backend-bootstrap \
  --filter '!./github-oidc' --filter '!./ecs-init' --filter '!./ecs-services' --filter '!./datadog' apply
# build e push das imagens para <conta>.dkr.ecr.<região>.amazonaws.com/voxticket/<nome>:<tag>
export IMAGE_TAG=<tag>
terragrunt run --working-dir ecs-init -- apply -auto-approve && ../../scripts/run-init-tasks.sh
DEPLOY_SERVICES=request-service,quota-service terragrunt run --working-dir ecs-services -- apply -auto-approve

# destruir
terragrunt run --all --filter '!./budget' --filter '!./github-oidc' destroy
```

**Pegadinha do Terragrunt 1.x:** flags do Terraform só passam depois de `--` (ex.: `-- plan -lock=false`).
Apply de uma unit só (`--working-dir`) **não** é aprovado automaticamente, por isso o `-auto-approve`;
já o `run --all` aprova sozinho.

## Custo estimado (us-east-1, ligado 24 h)

RDS `db.t4g.micro` + Amazon MQ `mq.t3.micro` + 8 tasks Fargate 0.25 vCPU + ALB ≈ **US$ 3–4/dia**.
Suba perto da apresentação (`infra-up`) e destrua logo depois (`infra-destroy`).
Sem NAT Gateway: as tasks usam subnet pública com IP público, e o RDS e o MQ ficam em subnet privada.

## Decisões e pendências

- ADRs em [`docs/adr/`](../docs/adr/).
- `TODO(infra)` no código: imagem do MiniStack, suporte a lifecycle no MiniStack, versão do RabbitMQ no Amazon MQ.
