# Segurança, escalabilidade e testes

## Segurança

| Camada | Medida | Onde |
|---|---|---|
| Segredos | Nenhuma senha no código ou no git. Credenciais no **Secrets Manager**, geradas pelo Terraform na AWS (`random_password`). O ECS injeta as do broker; o código lê só o segredo do próprio banco | `infra/modules/secrets`, `.env` fora do git |
| Menor privilégio (IAM) | **Uma task role por serviço**: cada uma lê só o segredo do próprio banco e tem só o acesso ao S3 de que precisa (`none`/`read`/`readwrite`). Só o `db-init` lê o usuário master | `infra/modules/ecs-services`, `infra/live/aws/ecs-services` |
| Banco por serviço | Local: um container por serviço. AWS: um database e um usuário por serviço, com `REVOKE ALL ... FROM PUBLIC` | ADR-003, `infra/scripts/db-init.sh` |
| Rede | RDS em **subnets privadas**, sem IP público. Os nós do RabbitMQ só aceitam conexão do NLB interno (5672, 15672) e uns dos outros (portas do cluster); o NLB só aceita os serviços. Security groups nunca abrem CIDR para banco ou broker. O ALB pode ser restrito por CIDR (`API_ALLOWED_CIDRS`) | `infra/modules/network` |
| Criptografia em trânsito | Broker via **AMQPS (TLS)**. Bucket com policy que **nega acesso sem HTTPS**. RDS Postgres 17 exige SSL por padrão (`rds.force_ssl`) | `messaging`, `storage` |
| Criptografia em repouso | S3 com SSE-AES256 e versionamento. RDS com `storage_encrypted` | `storage`, `database` |
| S3 | Bloqueio total de acesso público. Lifecycle apaga `failed/` em 7 dias | `infra/modules/storage` |
| Imagens | ECR com **scan de vulnerabilidades no push**. Containers rodam sem root (responsabilidade de cada Dockerfile) | `infra/modules/ecr` |
| ALB | `drop_invalid_header_fields` | `ecs-services` |
| Custo | Alerta de orçamento antes do primeiro deploy (50/80/100% e previsão) | `infra/modules/budget` |
| IaC | Scan com **Checkov** no CI | `.github/workflows/ci.yml` |
| CI/CD | **OIDC** (sem chave AWS no GitHub); role de deploy só no environment `aws` (com aprovação opcional) e sem poder alterar a si mesma; role de **plan somente leitura** para PRs | `infra/modules/github-oidc`, `.github/workflows/` |

**Fica para produção, fora do escopo acadêmico:**
- HTTPS no ALB, que exige domínio e certificado ACM;
- WAF;
- NAT Gateway com as tasks em subnet privada;
- rotação automática de segredos;
- RDS Multi-AZ.

## Escalabilidade

| Mecanismo | Detalhe |
|---|---|
| Consumidores concorrentes (R4) | O `transcription-worker` roda com 3 réplicas na mesma fila e `prefetch=1`. A idempotência evita efeito duplicado |
| **Autoescala pela fila** (bônus) | Na AWS, Application Auto Scaling com target tracking na métrica `mensagens na fila / tasks rodando` (`MessageCount` que os nós do RabbitMQ publicam no CloudWatch ÷ Container Insights `RunningTaskCount`), mais uma política por CPU. Worker de 2 a 6 tasks (alvo de 5 mensagens por task), request-service de 2 a 4, os outros de 1 a 3. Configurada e testada no Terraform (`terraform test`); como a AWS não fica ligada, não é demonstrada ao vivo |
| Serviços sem estado | Todo estado fica no Postgres, no S3 ou na fila, então qualquer serviço pode ganhar réplicas. Concorrência no recurso escasso é resolvida no banco (R2), não em memória |
| Desacoplamento | Fila durável entre serviços: um pico de áudios vira backlog, não erro. A API responde 202 e não bloqueia |
| Claim-check | As mensagens carregam só a chave do S3, nunca o áudio, então o tamanho da mensagem não cresce com o arquivo |
| Ordenação | Discutida em [requirements.md](requirements.md#ordenação-r4-discutir-na-apresentação) |

Para demonstrar a autoescala na AWS: aumente a latência do worker e mande uns 50 áudios. Em 1 a 2
minutos o `desiredCount` sobe; acompanhe com `make aws-status`.

## Testes

| Tipo | O quê | Como rodar |
|---|---|---|
| Infra: estático | `terraform fmt`, `validate`, `terragrunt hcl fmt`, `docker compose config` | `make test` |
| Infra: unitário | **`terraform test`** com provider mockado (sem conta AWS): bucket privado, criptografado e só HTTPS; um segredo por serviço; banco e broker sem CIDR aberto; uma role por serviço; ALB só para a API; autoescala com mínimo de 2 réplicas | `make test` |
| Infra: segurança | Checkov | CI |
| Serviços: unidade | Cada dono escreve os testes do seu serviço (ex.: reserva atômica, idempotência) | dentro de `services/<servico>` |
| Sistema: falhas | F1–F8 automatizados, com consultas SQL de verificação | `make f1` … `make f8` |
| CI | Todo push e PR roda testes da infra, Checkov e `docker build` de cada serviço | `.github/workflows/ci.yml` |
| Plan em PR | `terragrunt plan` de toda a infra a cada PR que mexe em `infra/` | `.github/workflows/infra-plan.yml` |
