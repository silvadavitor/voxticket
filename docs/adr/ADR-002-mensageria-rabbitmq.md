# ADR-002 — RabbitMQ (container local / cluster em EC2 na AWS)

**Status:** aceito · 17/11/2026 · revisto em 23/11/2026 (Amazon MQ → cluster próprio em EC2)

## Decisão
RabbitMQ com exchange topic `events`, filas **quorum** por consumidor, `x-delivery-limit=3`, DLX e DLQ
por fila. A topologia é aplicada pelo `rabbitmq-init`, que faz `POST /api/definitions` na API de
management, igual nos dois ambientes.

- **Local:** um container (`rabbitmq:4.1-management`) com volume persistente.
- **AWS:** **cluster de 3 nós, um por EC2, uma EC2 por zona de disponibilidade**, a mesma imagem do local,
  atrás de um **NLB interno** (os serviços usam um endereço só). Cada nó tem um **EBS próprio** para
  `/var/lib/rabbitmq`, IP privado fixo e nome fixo (`rabbit@rabbitmq-0..2`); o cookie do cluster e a
  senha vêm do Secrets Manager. `cluster_partition_handling = pause_minority`. O `rabbitmq-init` espera os
  3 nós antes de criar as filas, para a fila quorum nascer com réplica nos 3.

## Por quê
- **F6** (broker fora por 30 s): filas quorum e mensagens persistentes em disco garantem que nada se perde.
- **Alta disponibilidade:** a fila quorum replica entre os nós e funciona com a maioria (2 de 3); uma zona
  inteira pode cair. Por isso o número de nós é ímpar.
- DLQ, `x-delivery-limit` e fanout (`TicketOpened` para 3 filas) são nativos.
- Clientes maduros com reconexão automática nas 3 linguagens (R6).
- Mesmo protocolo e mesma imagem local e na AWS: nenhum código nem configuração muda.
- **Autoescala:** cada nó publica a profundidade das filas no CloudWatch a cada minuto; o worker escala por
  mensagens na fila ÷ tasks (ver `infra/modules/ecs-services`).

## Alternativas
- **Amazon MQ for RabbitMQ:** é o mesmo RabbitMQ gerenciado e foi a primeira escolha. Trocamos para ter a
  mesma imagem e configuração do ambiente local e controle do cluster (nós, disco, partição), que é
  justamente o assunto da disciplina. Custo: nós cuidamos das máquinas (patch, troca de nó).
- **RabbitMQ no ECS Fargate:** descartado. O disco do Fargate é temporário: ao reiniciar a task, a fila
  perderia as mensagens, o oposto do F6.
- **SNS + SQS:** gerenciado e barato, mas no MiniStack a persistência varia por serviço (as filas podem
  voltar vazias no F6), a visibility timeout precisa ser maior que a latência do F7, e o código usaria outra API.
- **Kafka:** é log particionado e não fila de trabalho. DLQ e reentrega por mensagem precisam ser feitas à
  mão, e operar Kafka é pesado demais para o escopo.
