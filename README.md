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
| **Nuvem** | AWS (desenvolvimento local com MiniStack) |

### Integrantes

| Nome | Responsabilidade |
|---|---|
| Vitor da Silva | Infraestrutura (Terraform/Terragrunt, AWS), observabilidade e um serviço |
| Pedro B. Freitag | Serviços _(a definir quais)_ |
| Samuel Jose Candido | Serviços _(a definir quais)_ |

O cliente envia um áudio, o sistema transcreve, classifica o texto e abre um chamado. O recurso
escasso são os **créditos de transcrição por cliente**: o crédito é reservado quando o áudio chega,
consumido quando o chamado é aberto e devolvido se algo falhar (saga com compensação).

## Comandos rápidos

```bash
make help        # lista tudo
make up          # sobe o sistema inteiro localmente
make ps          # estado dos containers
make logs s=quota-service
make f5          # roda o cenário de falha F5 (vale f1…f8)
make test        # testes da infraestrutura
make reset       # derruba e apaga os dados locais

# AWS: pelo GitHub Actions → workflows infra-up, deploy (automático) e infra-destroy
```

## Mapa do repositório

```
.
├── docs/                     # requisitos, arquitetura, saga, ADRs, divisão do trabalho, operações
├── contracts/                # AsyncAPI + JSON Schema de cada evento (fonte da verdade)
├── services/<servico>/       # 1 pasta por microsserviço — cada dono cria o código aqui
├── rabbitmq/definitions.json # exchanges, filas quorum e DLQs (carregado pelo rabbitmq-init)
├── infra/                    # Terraform (modules/) + Terragrunt (live/ministack, live/aws)
├── observability/            # OpenTelemetry Collector → Datadog (ou Jaeger como reserva)
├── scripts/failures/         # um script por cenário F1–F8 + consultas SQL de verificação
├── .github/workflows/        # ci, infra-plan, deploy, infra-up, infra-destroy (OIDC)
├── Makefile                  # atalhos (make help)
└── docker-compose.yml        # sobe tudo localmente
```

## Serviços

| Serviço | Linguagem | Responsável | Pasta |
|---|---|---|---|
| request-service (API + orquestrador da saga) | C# | _a definir_ | [services/request-service](services/request-service/) |
| notification-service | C# | _a definir_ | [services/notification-service](services/notification-service/) |
| quota-service (recurso escasso) | Java | _a definir_ | [services/quota-service](services/quota-service/) |
| ticket-service | Java | _a definir_ | [services/ticket-service](services/ticket-service/) |
| transcription-worker (×3 réplicas) | Python | _a definir_ | [services/transcription-worker](services/transcription-worker/) |
| categorization-service | Python | Vitor da Silva | [services/categorization-service](services/categorization-service/) |
| Infra (Terraform/Terragrunt) + Observabilidade | HCL | Vitor | [infra](infra/), [observability](observability/) |

## Como subir localmente (passo a passo)

### 0. Pré-requisitos (uma vez só)

| O quê | Como conferir | Observação |
|---|---|---|
| Docker + Docker Compose v2 | `docker compose version` | Windows/Mac: Docker Desktop **aberto**. Windows: rode tudo dentro do **WSL2** (Ubuntu) |
| Git | `git --version` | |
| `curl` e `jq` | `jq --version` | só para os scripts de teste (`sudo apt install jq curl`) |
| ~8 GB de RAM livres | | são uns 15 containers |

Portas que precisam estar livres: `4566`, `5672`, `15672`, `5433`–`5438`, `8080`–`8084`, `8090`–`8092`, `4317`, `4318`, `16686`.

### 1. Clonar e configurar

```bash
git clone <url-do-repo>
cd <pasta-do-repo>
cp .env.example .env        # não precisa mudar nada para rodar local
```

> O `.env` **nunca** vai para o git (já está no `.gitignore`).

### 2. Subir só a infraestrutura (sempre funciona, mesmo sem serviço pronto)

```bash
docker compose up -d --build
```

Espere ~1 min e confira:

```bash
docker compose ps -a
```

O esperado:
- `ministack`, `rabbitmq`, `postgres-*`, `otel-collector` e `jaeger` com estado **running** (os Postgres e o RabbitMQ como **healthy**);
- `infra-init` e `rabbitmq-init` com **Exited (0)**. Eles rodam uma vez e terminam; exit 0 = deu certo.

Se algum `*-init` saiu com código diferente de 0: `docker compose logs infra-init` (ou `rabbitmq-init`).

### 3. Subir os microsserviços

```bash
make up                         # infra + todos os serviços que JÁ têm Dockerfile
make svc s=quota-service        # só o seu serviço (e o que ele precisa: Postgres dele, RabbitMQ, MiniStack)
```

Conferir:

```bash
make ps
curl localhost:8081/health      # quota (request 8080, ticket 8082, categorization 8083, notification 8084, worker 8090-8092)
make logs s=quota-service       # logs ao vivo (Ctrl+C sai)
```

### Testar o SEU serviço sozinho (sem os outros prontos)

Publique na mão o evento que o seu serviço consome. O envelope é montado pelo script, e sem arquivo ele
gera um payload de exemplo válido:

```bash
make publish t=AudioReceived                  # quota-service
make publish t=TicketRequested                # ticket-service
make publish t=CategorizationRequested        # categorization-service
make publish t=TranscriptionRequested         # transcription-worker
make publish t=TicketOpened                   # notification / quota / request
make publish t=AudioReceived f=meu.json       # payload próprio (só o "payload", sem envelope)
REQUEST_ID=<uuid> MESSAGE_ID=<uuid> make publish t=AudioReceived   # repetir a mesma mensagem (teste do F3)
```

O que o seu serviço publicar aparece nas filas dos consumidores no painel do RabbitMQ
(http://localhost:15672 → Queues), mesmo que esses serviços ainda não existam.

### 4. Testar o fluxo

```bash
curl -F tenantId=tenant-demo -F file=@scripts/failures/lib/sample.ogg localhost:8080/audios
# → 202 {"requestId": "...", "statusUrl": "/audios/..."}
curl localhost:8080/audios/<requestId>
```

Cenários de falha F1–F8: [scripts/failures/README.md](scripts/failures/README.md).

### 5. Onde olhar

| URL | O quê | Login |
|---|---|---|
| http://localhost:8080 | request-service (API) | — |
| http://localhost:8081…8084, 8090…8092 | `/health` de quota, ticket, categorization, notification, workers | — |
| http://localhost:15672 | painel do RabbitMQ (filas, DLQs) | guest / guest |
| http://localhost:16686 | Jaeger (traces), com `OTEL_BACKEND=jaeger` | — |
| `localhost:5433`…`5438` | Postgres de request, quota, transcription, categorization, ticket, notification | usuário `<db>_user`, senha do `.env` |

Abrir o banco de um serviço pelo terminal:

```bash
docker compose exec postgres-quota psql -U quota_user -d quota
```

### 6. Parar e zerar

```bash
docker compose --profile apps down        # para tudo, MANTÉM os dados
docker compose --profile apps down -v     # para tudo e APAGA bancos, filas e S3 (recomeça do zero)
```

### Deu ruim?

| Sintoma | Causa provável | Resolve |
|---|---|---|
| `port is already allocated` | outra coisa usando a porta (um Postgres local, outro projeto) | pare o outro programa ou mude a porta no `docker-compose.yml` |
| `POSTGRES_PASSWORD ... defina` | faltou o `.env` | `cp .env.example .env` |
| `infra-init` Exited (1) | MiniStack ainda não estava pronto ou é a primeira execução | `docker compose up -d infra-init` de novo |
| serviço reinicia em loop | erro no código ou na config | `docker compose --profile apps logs <servico>` |
| `/health` com `"db":"down"` | Postgres do serviço caiu ou credencial errada | `docker compose ps postgres-<x>`; se mudou a senha no `.env`, rode `down -v` |
| `/health` com `"broker":"down"` | RabbitMQ fora | `docker compose start rabbitmq` (o serviço reconecta sozinho) |
| mudei o código e nada mudou | imagem antiga | `docker compose --profile apps up -d --build <servico>` |
| Mac M1/M2/M3 e erro de plataforma | imagem só amd64 | `DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose ...` |

## Deploy na AWS (entrega final)

Pelo **GitHub Actions com OIDC**, sem nenhuma chave da AWS no repositório:

| Ação | Como |
|---|---|
| Criar tudo do zero | Actions → **infra-up** → Run workflow |
| Atualizar | merge na `main`: build das imagens, push no ECR e atualização do ECS, sozinho |
| Ver o que muda na infra | abra um PR: o **infra-plan** mostra o `terragrunt plan` |
| Destruir tudo | Actions → **infra-destroy** → digite `destruir` |

Um push com a infra destruída **não recria nada**; criar é sempre manual. A configuração inicial
(OIDC, variáveis do GitHub) e o passo a passo manual sem CI estão em [infra/README.md](infra/README.md).

## Requisitos do enunciado: onde estão

| Exigência | Como foi atendida | Onde |
|---|---|---|
| ≥ 4 microsserviços, ≥ 3 linguagens | 6 serviços em C#, Java e Python | [services/](services/) |
| Mensageria assíncrona + contratos | RabbitMQ (Amazon MQ na AWS); AsyncAPI + JSON Schema, envelope único | [contracts/](contracts/), [ADR-002](docs/adr/ADR-002-mensageria-rabbitmq.md) |
| ≥ 3 categorias de nuvem | Mensageria, armazenamento de objetos (S3), segredos (Secrets Manager), banco (RDS), computação (ECS) | [docs/architecture.md](docs/architecture.md#nuvem) |
| Banco por serviço | Postgres próprio por serviço; na AWS, um database e um usuário isolados por serviço | [ADR-003](docs/adr/ADR-003-postgres-database-por-servico.md) |
| Infra só por script | Terraform + Terragrunt; MiniStack e AWS com os mesmos módulos | [infra/](infra/) |
| Dockerfile + `/health` + `docker compose up` | um por serviço; compose sobe tudo | [docker-compose.yml](docker-compose.yml) |
| R1–R6 e cenários F1–F8 | Outbox, idempotência, reserva atômica, 202, réplicas, reconexão; um script por cenário | [docs/requirements.md](docs/requirements.md), [scripts/failures/](scripts/failures/) |
| Segurança | Menor privilégio por serviço, segredos fora do código, rede privada, TLS, scan | [docs/security-scalability.md](docs/security-scalability.md#segurança) |
| Escalabilidade | Consumidores concorrentes, autoescala pela fila, serviços sem estado | [docs/security-scalability.md](docs/security-scalability.md#escalabilidade) |
| Testes | Testes do Terraform, CI, cenários de falha automatizados | [docs/security-scalability.md](docs/security-scalability.md#testes) |
| Bônus | OpenTelemetry, IaC, autoescala, CQRS, versionamento de eventos | [docs/requirements.md](docs/requirements.md#bônus-até-10) |

## Fluxo de trabalho do grupo

1. Leia [docs/README.md](docs/README.md) e o README do seu serviço em `services/<servico>/`.
2. Trabalhe numa branch (`git checkout -b feat/<servico>`) e abra PR para a `main`.
3. Mudança em `docs/` ou `contracts/` precisa de PR revisado por quem consome o evento.
4. Antes do PR: o serviço sobe com `docker compose --profile apps up -d <servico>` e o `/health` responde.
