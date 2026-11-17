# ADR-002 — RabbitMQ (container local / Amazon MQ na AWS)

**Status:** aceito · 17/11/2026

## Decisão
RabbitMQ com exchange topic `events`, filas **quorum** por consumidor, `x-delivery-limit=3`, DLX e DLQ
por fila. Local: container com volume persistente. AWS: **Amazon MQ for RabbitMQ** (gerenciado).
A topologia é aplicada pelo `rabbitmq-init`, que faz `POST /api/definitions` na API de management.
Funciona igual no container e no Amazon MQ, que não aceita `load_definitions` no boot.

## Por quê
- **F6** (broker fora por 30 s): filas quorum, mensagens persistentes e volume garantem que nada se
  perde. O comportamento é previsível e testável localmente.
- DLQ, `x-delivery-limit` e fanout (`TicketOpened` para 3 filas) são nativos.
- Clientes maduros com reconexão automática nas 3 linguagens (R6).
- Mesmo protocolo (AMQP) local e na AWS: nenhum código muda.

## Alternativas
- **SNS + SQS:** gerenciado e barato, mas no MiniStack a persistência varia por serviço (as filas
  podem voltar vazias no F6), a visibility timeout precisa ser maior que a latência do F7, e o
  código usaria outra API.
- **Kafka:** é log particionado e não fila de trabalho. DLQ e reentrega por mensagem precisam ser
  feitas à mão, e operar Kafka é pesado demais para o escopo.
