# Guia de defesa — perguntas prováveis

Além dos cenários F1–F8, o professor pode perguntar sobre as decisões. A resposta curta vem primeiro; o
detalhe está no documento linkado. **Todo mundo do grupo deve conseguir responder qualquer uma.**

## Arquitetura geral

**Por que microsserviços aqui? Não seria mais simples um monolito?**
Seria, e para um produto desse tamanho um monolito seria a escolha certa. O trabalho pede microsserviços
para exercitar o que dá errado entre processos: rede, broker, réplicas, falha parcial. Cada serviço tem
um motivo de existir separado: escala diferente (worker ×3), dependência instável isolada (transcrição),
recurso escasso com regra própria (quota).

**Saga orquestrada ou coreografada? Por quê?**
Orquestrada pelo request-service. O fluxo tem 4 passos e 3 caminhos de compensação: com orquestrador, o
estado do pedido fica num lugar só (máquina de estados), o timeout é simples e o `GET /audios/{id}`
responde direto. Na coreografia cada serviço reagiria aos eventos dos outros: menos acoplamento ao
orquestrador, porém o fluxo fica espalhado e difícil de depurar. [architecture.md](architecture.md#saga-orquestrada-pelo-request-service)

**Por que não transação distribuída (2PC)?**
O 2PC trava recursos em vários bancos esperando um coordenador; se ele cai, tudo fica bloqueado. Brokers
e bancos diferentes nem participam do mesmo 2PC. A saga troca atomicidade por **consistência eventual com
compensação**: cada passo é local e, se um falha, os anteriores são desfeitos por eventos
(`CreditReleaseRequested`, mover para `failed/`).

**Onde está o teorema CAP nisso?**
Entre serviços escolhemos **disponibilidade e tolerância a partição** (AP): a API responde 202 mesmo com o
broker fora (outbox) e o estado converge depois (consistência eventual). Dentro de cada serviço, o
Postgres dá consistência forte, e é lá que fica o que não pode errar (reserva de crédito, R2).

## Mensageria e entrega

**O sistema garante exactly-once?**
Não existe exactly-once de ponta a ponta numa rede que falha. Temos **at-least-once na entrega + efeito
idempotente** (= efeito exatamente uma vez): o `messageId` vai para `processed_messages` **na mesma
transação** do efeito; repetida, cai no `ON CONFLICT` e só faz ACK (R1, F3).

**Para que serve o outbox? Por que não publicar direto?**
Para não ter "gravei no banco mas não publiquei" (ou o contrário). Efeito e evento entram na **mesma
transação**; um relay publica depois, com confirmação do broker, e só então marca `sent_at`. Se o broker
cai, os eventos esperam no outbox (F6).

**E se o serviço morre entre o COMMIT e o ACK?**
A mensagem volta para a fila e é reprocessada; o `processed_messages` detecta a repetição e não refaz o
efeito (F2).

**Mensagem venenosa x erro de infraestrutura?**
Payload fora do contrato → `nack` → depois de `x-delivery-limit=3` vai para a DLQ, e as outras seguem (F4).
Banco ou S3 fora → retry com backoff **segurando** a mensagem. Se tratasse igual, mensagens boas iriam
para a DLQ só porque o banco piscou.

**E a ordem das mensagens?**
A fila entrega em ordem, mas com réplicas e reentregas a ordem global se perde. Não importa aqui: a saga
só avança um passo por pedido e a máquina de estados descarta evento que faria o estado regredir. Se
precisasse: particionar por `requestId` (consistent-hash exchange). [requirements.md](requirements.md#ordenação-r4-discutir-na-apresentação)

**Por que RabbitMQ e não SQS ou Kafka?** [ADR-002](adr/ADR-002-mensageria-rabbitmq.md)
Filas quorum persistentes (F6 sem perda), DLQ e delivery-limit nativos, fanout do `TicketOpened`, mesmo
protocolo local e na AWS (Amazon MQ). Kafka é log particionado, sem DLQ/reentrega por mensagem prontas.

**Como as filas estão montadas?** [definitions.json](../rabbitmq/definitions.json)
Uma exchange `events` do tipo topic, com routing key = nome do evento. Cada serviço que consome tem **uma**
fila quorum (`<servico>.q`) ligada aos eventos que interessam a ele, e uma DLQ própria (`<servico>.dlq`) via
`events.dlx`. São 6 filas e 6 DLQs. A topologia é versionada e aplicada no `make up`, ninguém cria fila à mão.

**Por que topic e não direct ou fanout?**
Com topic o produtor só publica "aconteceu X" e não sabe quem consome. O `TicketOpened` cai em 3 filas
(request, quota, notification) e o ticket-service nem sabe disso. Fanout mandaria tudo para todos; direct
funcionaria, mas topic deixa assinar padrões se precisar.

**Por que uma fila por serviço e não uma por evento?**
Réplicas do **mesmo** serviço disputam a mesma fila (competing consumers, R4); serviços **diferentes**
recebem cada um a sua cópia. Uma fila por evento multiplicaria filas e DLQs (o request-service sozinho
consome 7 tipos) sem ganho aqui. O custo: um tipo de evento lento atrasa os outros na mesma fila. Se virar
problema, separa-se só aquele evento.

**Comando e evento na mesma exchange?**
Sim. `TranscriptionRequested`, `TicketRequested` etc. são comandos (um destino); `TicketOpened` é evento
(vários). A diferença está só em quantas filas estão ligadas à routing key. Uma exchange só simplifica a
topologia e o rastreio.

**Por que fila quorum e não clássica?**
Quorum persiste em disco, é a fila recomendada pelo RabbitMQ para dado que não pode perder, e tem o
`x-delivery-limit` nativo: o broker conta as tentativas e manda para a DLQ sozinho, mesmo se o consumidor
reiniciar. Na clássica teríamos que contar no código.

**prefetch=1 não deixa lento?**
No worker é de propósito: uma transcrição leva segundos, e com prefetch maior uma réplica seguraria áudios
enquanto outra fica parada. Com 1, quem está livre pega o próximo (F8).

**O que fazer com o que cai na DLQ?**
Fica guardado com o motivo. Alguém olha, corrige o produtor (ou o contrato) e reenvia pelo painel do
RabbitMQ (shovel ou "move messages"). Não reprocessamos sozinhos: mensagem venenosa voltaria a falhar.

**Por que as mensagens não levam o áudio?**
Claim-check: brokers têm limite de tamanho e não são feitos para binário grande. A mensagem leva só a
chave do S3.

## Concorrência e escala

**Como garantem que não vende crédito a mais com 100 requisições ao mesmo tempo?**
Reserva **atômica no banco**: `UPDATE tenant_quota SET used = used + 1 WHERE tenant_id = $1 AND used < quota_limit`.
O Postgres serializa as atualizações da mesma linha; 1 linha afetada = reservou, 0 = sem crédito. Nada
em memória, então funciona com várias réplicas do quota-service (R2, F5).

**E a devolução do crédito não pode acontecer duas vezes?**
Só devolve se a reserva está `RESERVED` (`UPDATE ... WHERE status = 'RESERVED'`); a segunda tentativa
afeta 0 linhas.

**Como escala?**
Serviços sem estado (estado no Postgres, no S3 e na fila). O request-service roda com 2 réplicas (o
gateway reparte as requisições; o consumo trava a linha do pedido com `FOR UPDATE` e o timeout e o relay
usam `SKIP LOCKED`, então as duas não pisam uma na outra). O worker roda com 3 réplicas na mesma fila
(`prefetch=1`, F8) e, na AWS, tem autoescala pelo backlog da fila (mensagens ÷ tasks).
[security-scalability.md](security-scalability.md#escalabilidade)

**O que acontece se derrubar o serviço X?** [operations.md](operations.md#falha-surpresa--previsões)
Regra geral: as mensagens dele se acumulam na fila durável, os outros seguem, e ao voltar ele consome
tudo. O que estava esperando por ele expira e é compensado pela rotina de timeout.

## Dados

**Banco por serviço: por que um Postgres por serviço local e um RDS só na AWS?** [ADR-003](adr/ADR-003-postgres-database-por-servico.md)
Local não custa nada ter 6. Na AWS, custo: um RDS com **database e usuário isolados por serviço**, e cada
serviço só tem permissão de ler o **próprio** segredo. Nenhum serviço consegue acessar o banco de outro.

**Como o front mostra os chamados se eles estão no banco do ticket-service?**
O ticket-service expõe a própria API de leitura (`GET /tickets`). O front não junta dados de bancos: cada
serviço responde pelo que é dele, e o gateway roteia por caminho.

## Nuvem, segurança e operação

**Por que esses serviços da AWS?** [ADR-001](adr/ADR-001-nuvem-ministack-para-aws.md), [ADR-005](adr/ADR-005-front-estatico-s3-cloudfront.md)
S3 para áudio (binário fora do banco, lifecycle), Secrets Manager (nenhuma senha no código), Amazon MQ e
RDS gerenciados, ECS Fargate (sem servidor para administrar), CloudFront para o front (HTTPS de graça,
cache na borda).

**Como é a segurança?** [security-scalability.md](security-scalability.md#segurança)
Uma permissão IAM por serviço (só o próprio segredo e só o acesso ao S3 que precisa), banco e broker
em rede privada, S3 privado/criptografado/só HTTPS, CI sem chave da AWS (OIDC), scan de vulnerabilidade
das imagens e do Terraform.

**Como recriam o ambiente do zero?**
Tudo é Terraform + Terragrunt, com os mesmos módulos local e na AWS. Local: `make up`. AWS: workflow
`infra-up` e `infra-destroy`. Nada é criado à mão no console.

**Como sabem o que está acontecendo?**
OpenTelemetry nos 3 runtimes → Grafana: trace de um pedido atravessando os serviços (procura pelo
requestId), métricas (filas, DLQ, outbox, créditos) e logs com `trace_id`.
[observability/README.md](../observability/README.md)

## Perguntas "pegadinha"

- **"E se o mesmo áudio for enviado duas vezes pelo cliente?"** São dois pedidos (dois `requestId`), e cada
  um consome crédito. Para deduplicar no envio: chave de idempotência no header do `POST`; fica como
  evolução.
- **"O timeout pode compensar um pedido que ia dar certo?"** Pode, e é o F7. Quando o resultado atrasado
  chega, o pedido já está `EXPIRED`: o orquestrador descarta o resultado (`TranscriptDiscardRequested`)
  em vez de abrir chamado. O crédito foi devolvido uma vez só.
- **"E se o relay do outbox publicar e cair antes de marcar `sent_at`?"** Publica de novo ao voltar: o
  consumidor recebe uma duplicata e o `processed_messages` descarta. É por isso que a entrega é
  at-least-once.
- **"Por que 202 e não 201?"** O recurso ainda não está pronto: o pedido foi **aceito** para processamento
  assíncrono. 201 seria "criado e concluído".

## Limites conhecidos

- **Sem autenticação na API.** De propósito: o foco do trabalho é o sistema distribuído. O `tenantId` vem
  no formulário e o `/tenants` é aberto. Em produção seria login (Cognito/JWT) com o cliente dentro do token
  e o `/tenants` só para administrador.
- **Categorização por palavras-chave.** É um exemplo: o que importa é o passo da saga, não o classificador.
