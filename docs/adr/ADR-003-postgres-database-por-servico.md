# ADR-003 — Banco por serviço: 1 Postgres por serviço (local) / RDS compartilhado e isolado (AWS)

**Status:** aceito · 17/11/2026

## Contexto
O enunciado exige "banco por serviço: nenhum serviço lê ou escreve no banco de outro". São 6 serviços.

## Decisão
- **Local (docker compose):** **um container Postgres por serviço** (`postgres-request`, `postgres-quota`, …),
  cada um com volume próprio. Isolamento físico total: derrubar `postgres-quota` afeta só o quota-service.
- **AWS (entrega):** **uma instância RDS** (`db.t4g.micro`) com **um database e um usuário por serviço**.
  Cada usuário só acessa o próprio database (`REVOKE ALL ON DATABASE ... FROM PUBLIC`), e cada serviço lê
  **só o próprio** segredo (`voxticket/<env>/db/<servico>`). O `db-init` (task one-off) cria databases e
  usuários a partir dos segredos.
- O código dos serviços é o mesmo nos dois casos: lê `DB_HOST`/`DB_PORT` do ambiente e usuário, senha
  e database do Secrets Manager.

## Por quê
- Local, um container por serviço não custa nada e deixa a demonstração de falha ("derrubar o banco de
  um serviço") literal.
- Na AWS, 6 instâncias RDS custariam ~6× mais (≈ US$ 2,50/dia extra) sem ganho para a avaliação; o
  isolamento lógico (usuário + database + segredo por serviço) já garante que nenhum serviço acessa o
  banco de outro.

## Trade-off (para a apresentação)
Na AWS a instância é um ponto único de falha compartilhado. Em produção: uma instância por serviço (ou
por domínio), ou Aurora Serverless v2 por serviço. Na demo de falha surpresa, usamos o ambiente local.
