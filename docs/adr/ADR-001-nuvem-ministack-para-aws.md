# ADR-001 — MiniStack no desenvolvimento, AWS na entrega

**Status:** aceito · 17/11/2026

## Contexto
O enunciado aceita nuvem pública ou MiniStack. O grupo quer rodar na **AWS** na entrega, mas
desenvolver sem custo e sem depender de conta.

## Decisão
- Toda a infra é **Terraform** (módulos em `infra/modules`) orquestrado por **Terragrunt**, com dois
  ambientes: `infra/live/ministack` (local) e `infra/live/aws` (entrega).
- Os mesmos módulos servem aos dois ambientes. No MiniStack o provider aponta para `AWS_ENDPOINT_URL`.
- Serviços AWS consumidos: **S3** (áudios e transcrições), **Secrets Manager** (credenciais),
  **RDS Postgres**, **RabbitMQ em EC2** (cluster de 3 nós, ADR-002) e **ECS Fargate** + **ECR** (computação).
- O código dos serviços usa o SDK AWS padrão. Com `AWS_ENDPOINT_URL` definido ele fala com o
  MiniStack; vazio, fala com a AWS.

## Por que não as alternativas
- **Só MiniStack:** não mostra deploy real, e o grupo quer a entrega na AWS.
- **Só AWS:** custo e atrito para desenvolver; três pessoas precisariam de credenciais.
- **Áudio no Postgres em vez de S3:** binário grande no banco é caro e lento, e o S3 tem lifecycle
  (`failed/` expira em X dias) e versionamento.
- **SSM Parameter Store em vez de Secrets Manager:** o Secrets Manager tem geração e rotação de
  segredo e integração nativa com o RDS e com o campo `secrets` da task definition do ECS.
- **Lambda em vez de ECS:** os consumidores são processos longos com conexão AMQP persistente e
  prefetch, o que não combina com o modelo de invocação do Lambda.

## Custo (AWS)
Instâncias mínimas (`db.t4g.micro`, 3 × `t4g.small` do RabbitMQ, Fargate 0.25 vCPU), sem NAT Gateway (tasks em
subnets públicas com IP público; RDS em subnets privadas; nós do RabbitMQ sem nenhuma porta aberta para fora). Alerta de orçamento antes do primeiro
deploy. Rodar `terragrunt run --all destroy` depois da apresentação.
