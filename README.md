# VoxTicket

**Do áudio ao chamado:** transcrição → categorização → abertura de chamados, como sistema distribuído.

![ci](../../actions/workflows/ci.yml/badge.svg)

| | |
|---|---|
| **Projeto** | Trabalho Final de Sistemas Distribuídos |
| **Instituição** | Universidade Regional de Blumenau (FURB), Departamento de Sistemas e Computação |
| **Professor** | Gabriel Castellani de Oliveira |
| **Apresentação / defesa** | 25/11/2026 |
| **Entrega do código** | 02/12/2026 |
| **Nuvem** | MiniStack local (demonstração) e AWS (Terraform pronto, ligado só sob demanda) |

| Integrante | Responsabilidade |
|---|---|
| Vitor da Silva | categorization-service, infraestrutura (Terraform/Terragrunt, AWS) e observabilidade |
| Pedro B. Freitag | request-service, notification-service, transcription-worker |
| Samuel Jose Candido | quota-service, ticket-service |

Uma empresa envia o áudio de uma ligação de suporte; o sistema transcreve, classifica o texto e abre um
chamado. O recurso escasso são os **créditos de transcrição por cliente**: o crédito é reservado quando o
áudio chega, consumido quando o chamado é aberto e devolvido se algo falhar (saga com compensação).

## Rodar

Pré-requisitos: Docker com Compose v2 e uns 8 GB de RAM livres. Para os scripts de teste: `curl` e `jq`.

```bash
git clone <url-do-repo> && cd <pasta-do-repo>
cp .env.example .env               # opcional: sem ele valem os padrões locais
docker compose up -d --build       # sobe tudo
```

Um único `docker compose up` sobe o MiniStack (S3 e Secrets Manager), o RabbitMQ, um Postgres por serviço,
a observabilidade, os 6 serviços e cadastra o cliente `tenant-demo` com 1000 créditos. Na primeira vez
leva alguns minutos (build das imagens, incluindo o modelo do Whisper).

`docker compose ps -a` deve mostrar tudo **running** e `infra-init`, `rabbitmq-init` e `seed` com
**Exited (0)**: eles rodam uma vez e terminam.

```bash
docker compose logs -f quota-service   # logs de um serviço
docker compose down                    # para tudo e mantém os dados
docker compose down -v                 # para tudo e apaga os dados
```

| Endereço | O quê | Login |
|---|---|---|
| **http://localhost:8088** | Front: gravar ou enviar áudio, saga ao vivo, chamados, clientes, corrida do F5 | — |
| http://localhost:8088/api | API pelo gateway (`/audios`, `/tickets`, `/tenants`) | — |
| http://localhost:3000 | Grafana: dashboards Saga, Serviços, Logs e Traces | sem login |
| http://localhost:15672 | Painel do RabbitMQ (filas, DLQs, consumidores) | guest / guest |
| `localhost:8085`, `8086` · `8081`–`8084` · `8090`–`8092` | `/health` do request (2 réplicas), quota, ticket, categorization, notification e workers | — |
| `localhost:5433`–`5438` | Postgres de cada serviço | `<db>_user` / senha do `.env` |

Enviar um áudio pela linha de comando:

```bash
curl -F tenantId=tenant-demo -F file=@scripts/failures/lib/tec-urg.mp3 localhost:8088/api/audios
curl localhost:8088/api/audios/<requestId>
```

## Testar

O `make` só roda os testes (o sistema precisa estar no ar):

```bash
make check       # placar rápido: R3–R6 + F3, F4, F5
make check-all   # todos os requisitos e os cenários F1–F8 (10 a 15 min)
make f5          # um cenário narrado, com a prova na tela (f1…f8); PAUSA=1 make f5 para passo a passo
make test        # infraestrutura: fmt, validate e testes dos módulos Terraform
```

Cada cenário mostra o estado no banco antes e depois, acompanha a saga ao vivo e lista os logs dos
containers. Detalhes em [scripts/failures/README.md](scripts/failures/README.md).

## Infraestrutura como código

Localmente, o bucket de áudios, o bucket do front e os segredos são criados pelo **mesmo Terraform da AWS**,
aplicado pelo Terragrunt de [infra/live/ministack](infra/live/ministack/) contra o MiniStack. É o container
`infra-init` que faz isso no `docker compose up`. Nenhum recurso é criado à mão.

```bash
docker compose logs infra-init                      # o apply que rodou no up
docker compose run --rm --no-deps infra-init 'terragrunt run --all --non-interactive plan'
docker compose run --rm --no-deps infra-init 'terragrunt run --all --non-interactive apply'
curl -s localhost:4566/ | grep -o '<Name>[^<]*'     # buckets criados no MiniStack
make test                                           # fmt, validate e testes dos módulos
```

Para mostrar o Terraform corrigindo o ambiente:

1. Reinicie o MiniStack com `docker compose restart ministack`. Ele não guarda os segredos.
2. Rode o `plan`. Ele mostra os segredos que faltam (`16 to add`).
3. Rode o `apply`. Os segredos são recriados.
4. Rode o `plan` de novo. Ele mostra **No changes**.

Na AWS, os mesmos módulos de [infra/modules](infra/modules/) são aplicados por
[infra/live/aws](infra/live/aws/), que cria rede, RDS, cluster do RabbitMQ, ECS, ALB, CloudFront, alarmes e
orçamento. Todo PR roda o **infra-plan** no GitHub Actions e mostra o plano.

## Autoescala

**Localmente** a escala é manual: o RabbitMQ divide a fila entre quantas réplicas estiverem consumindo.

1. Deixe uma réplica só do worker:
   ```bash
   docker compose up -d --scale transcription-worker=1 transcription-worker
   ```
2. Mande 10 áudios. A fila `transcription-worker.q` cresce no RabbitMQ e no Grafana:
   ```bash
   for i in $(seq 10); do curl -s -o /dev/null -F tenantId=tenant-demo -F file=@scripts/failures/lib/tec-urg.mp3 localhost:8088/api/audios; done
   ```
3. Volte para 3 réplicas. Aparecem 3 consumidores e a fila esvazia mais rápido:
   ```bash
   docker compose up -d --scale transcription-worker=3 transcription-worker
   ```

O painel **Réplicas consumindo cada fila**, no Grafana, mostra a mudança. O `make f8` faz o mesmo com 30 áudios e
confere que nenhum foi processado duas vezes. Localmente o máximo é 3 réplicas, porque cada uma usa uma porta
(8090–8092).

**Na AWS** a mesma ideia é automática, configurada em
[infra/live/aws/ecs-services](infra/live/aws/ecs-services/terragrunt.hcl). Ela não foi demonstrada porque o
ambiente da AWS não ficou ligado.

1. Um timer em cada EC2 do RabbitMQ publica, a cada 60 s, o tamanho de cada fila no CloudWatch
   (`VoxTicket/RabbitMQ`, métrica `MessageCount`).
2. O Application Auto Scaling divide esse número pela quantidade de tasks e mantém o resultado perto do alvo.
   No worker o alvo é 5 mensagens por task. Com 30 áudios na fila, ele sobe para 6 tasks, o máximo.
3. Quando a fila esvazia, ele volta ao mínimo devagar (2 minutos de espera), para não ficar subindo e descendo.
4. Uma segunda regra olha a CPU (alvo de 70% no worker). Vence a que pedir mais tasks.

| Serviço | Tasks (mín–máx) | Alvo de mensagens por task |
|---|---|---|
| transcription-worker | 2–6 | 5 (+ CPU 70%) |
| request-service | 2–4 | 20 |
| quota, categorization, ticket | 1–3 | 20 |
| notification | 1–2 | 50 |

Alguns serviços rodam com uma réplica só, pensando em custo num cenário real: cada task no Fargate é paga por hora.
Se um deles cair, as mensagens esperam na fila durável, o ECS sobe outra task e o prazo da saga compensa o que
vencer. O request-service (porta de entrada e orquestrador) e o worker (o passo lento) nunca ficam com menos de 2.

Escalar pela fila, e não só pela CPU, é o que importa aqui: a CPU só diz que as tasks estão ocupadas, e a fila diz
quanto trabalho está esperando. Com 30 mensagens paradas, a fila pede mais tasks antes da CPU perceber.

## Mapa do repositório

```
.
├── docs/                     # requisitos, arquitetura, saga, ADRs, operações e guia de defesa
├── contracts/                # AsyncAPI + JSON Schema de cada evento, OpenAPI da API HTTP
├── services/<servico>/       # código, Dockerfile e README de cada microsserviço
├── frontend/                 # página estática (S3 + CloudFront; local: MiniStack + nginx)
├── rabbitmq/definitions.json # exchange, filas quorum e DLQs (aplicado pelo rabbitmq-init)
├── infra/                    # Terraform (modules/) + Terragrunt (live/ministack, live/aws)
├── observability/            # OpenTelemetry Collector, Alloy e dashboards do Grafana
├── scripts/failures/         # um script por cenário F1–F8
├── .github/workflows/        # ci, infra-plan, infra-up, build, deploy, infra-destroy (OIDC)
├── Makefile                  # testes (make help)
└── docker-compose.yml        # sobe tudo localmente
```

| Serviço | Linguagem | Responsável |
|---|---|---|
| [request-service](services/request-service/) (API + orquestrador da saga, 2 réplicas) | C# | Pedro B. Freitag |
| [notification-service](services/notification-service/) | C# | Pedro B. Freitag |
| [transcription-worker](services/transcription-worker/) (Whisper, 3 réplicas) | Python | Pedro B. Freitag |
| [quota-service](services/quota-service/) (recurso escasso) | Python | Samuel José Candido |
| [ticket-service](services/ticket-service/) | Python | Samuel José Candido |
| [categorization-service](services/categorization-service/) | Go | Vitor da Silva |

## AWS

Pelo **GitHub Actions com OIDC**, sem nenhuma chave da AWS no repositório:

| Ação | Como |
|---|---|
| Criar tudo do zero | Actions → **infra-up** → Run workflow |
| Atualizar | merge na `main`: build das imagens, push no ECR e atualização do ECS |
| Ver o que muda na infra | abra um PR: o **infra-plan** mostra o plano |
| Destruir tudo | Actions → **infra-destroy** → digite `destruir` |

A configuração inicial e o passo a passo sem CI estão em [infra/README.md](infra/README.md). Como subir em
outra região: [docs/operations.md](docs/operations.md#se-a-região-da-aws-cair).

## Requisitos do enunciado: onde estão

| Exigência | Como foi atendida | Onde |
|---|---|---|
| ≥ 4 microsserviços, ≥ 3 linguagens | 6 serviços em C#, Python e Go | [services/](services/) |
| Mensageria assíncrona + contratos | RabbitMQ (cluster de 3 EC2 na AWS); AsyncAPI + JSON Schema, envelope único | [contracts/](contracts/), [ADR-002](docs/adr/ADR-002-mensageria-rabbitmq.md) |
| ≥ 3 categorias de nuvem | Mensageria, armazenamento de objetos (S3), segredos (Secrets Manager); na AWS também RDS e ECS | [docs/architecture.md](docs/architecture.md#nuvem) |
| Banco por serviço | Postgres próprio por serviço; na AWS, um database e um usuário isolados por serviço | [ADR-003](docs/adr/ADR-003-postgres-database-por-servico.md) |
| Infra só por script | Terraform + Terragrunt; MiniStack e AWS com os mesmos módulos | [infra/](infra/) |
| Dockerfile + `/health` + `docker compose up` | um por serviço; um `docker compose up` sobe tudo | [docker-compose.yml](docker-compose.yml) |
| R1–R6 e cenários F1–F8 | Outbox, idempotência, reserva atômica, 202, réplicas, reconexão; um script por cenário | [docs/requirements.md](docs/requirements.md), [scripts/failures/](scripts/failures/) |
| Segurança | Menor privilégio por serviço, segredos fora do código, rede privada, Checkov no CI | [docs/security-scalability.md](docs/security-scalability.md#segurança) |
| Escalabilidade | Consumidores concorrentes, autoescala pela fila (AWS), serviços sem estado | [docs/security-scalability.md](docs/security-scalability.md#escalabilidade) |
| Bônus | OpenTelemetry e IaC demonstrados; autoescala pela fila configurada na AWS | [docs/requirements.md](docs/requirements.md#bônus-até-10-cada-item-só-conta-se-demonstrado) |
