# Units of Work

Cada unit é desenvolvida e testada de forma independente, contra os contratos em `contracts/`.

| Unit | Pasta | Linguagem | Responsável | Depende de |
|---|---|---|---|---|
| infra | `infra/` | Terraform + Terragrunt | Vitor | — |
| observability | `observability/`, `infra/modules/datadog` | OTel / Datadog | Vitor | infra |
| request-service | `services/request-service` | C# | _a definir_ | contracts, infra |
| notification-service | `services/notification-service` | C# | _a definir_ | contracts |
| quota-service | `services/quota-service` | Java | _a definir_ | contracts |
| ticket-service | `services/ticket-service` | Java | _a definir_ | contracts |
| transcription-worker | `services/transcription-worker` | Python | _a definir_ | contracts, infra (S3) |
| categorization-service | `services/categorization-service` | Python | _a definir_ | contracts |

> Atribuam os donos aqui e no README de cada serviço. Sugestão: quem pega um serviço de uma
> linguagem pega o outro da mesma linguagem, porque a "biblioteca base" (envelope, outbox,
> processed_messages, consumidor com reconexão) é reaproveitada.

## Como testar um serviço sozinho

Suba o seu serviço (`docker compose --profile apps up -d <servico>`, que traz junto o Postgres dele, o
RabbitMQ e o MiniStack) e publique
eventos de teste no RabbitMQ (painel em `:15672`, ou `scripts/failures/lib/publish.py`).

## Cronograma (apresentação 25/11)

| Quando | O quê |
|---|---|
| 17/11 | Registro do tema, repo, contratos e compose (feito) |
| 18–19/11 | Cada pessoa monta a biblioteca base na sua linguagem (R1, R6) |
| 20–22/11 | Regras de negócio e saga ponta a ponta; deploy AWS em paralelo (infra) |
| 23/11 | Scripts F1–F8 e consultas SQL |
| 24/11 | Ensaio de cada cenário + falha surpresa sorteada no grupo |
| 25/11 | Apresentação |
| até 02/12 | Código final público |
