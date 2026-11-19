# Cenários de falha F1–F8

Um script por cenário. Cada um **provoca a falha, confere o resultado com ✅/❌ e devolve o sistema ao
normal**. Todos usam um cliente novo a cada execução, então dá para rodar quantas vezes quiser.

```bash
make up          # sistema inteiro no ar
make f5          # roda um cenário (f1 … f8)
```

| Script | Cenário | O que confere |
|---|---|---|
| `F1-compensacao.sh` | transcrição falha 100% | pedido FAILED, reserva RELEASED, crédito devolvido, notificação REQUEST_FAILED, áudio em `failed/` |
| `F2-servico-morre.sh` | `docker kill` na réplica que transcreve | outra réplica conclui, 1 transcrição, 1 chamado |
| `F3-duplicada.sh` | mesmo `AudioReceived` (mesmo `messageId`) 5× | `used` = 1, 1 reserva, 4 duplicatas descartadas no log |
| `F4-venenosa.sh` | payload fora do contrato | vai para `quota-service.dlq`; a mensagem válida seguinte é processada |
| `F5-corrida.sh` | 100 POSTs para 10 créditos | todos 202, `used` = 10, 10 reservas, 90 REJECTED |
| `F6-broker-fora.sh` | RabbitMQ parado 30 s | API segue com 202, outbox acumula e drena, todos reconectam, pedidos concluem |
| `F7-resposta-tardia.sh` | transcrição 20 s × timeout 10 s | EXPIRED, crédito devolvido 1×, transcrição DISCARDED, 0 chamados |
| `F8-escala.sh` | 3 réplicas, 30 áudios | 3 consumidores, 30 transcrições sem duplicata, carga em ≥ 2 réplicas |

Dependências: `bash`, `curl`, `jq`, `docker compose`. O áudio de teste (`lib/sample.ogg`) é fala real em
português, porque o worker transcreve com Whisper.

Tabelas e logs que os scripts consultam (se mudarem num serviço, atualizar aqui):

| Banco | Tabela / log |
|---|---|
| requests | `requests(id, tenant_id, status, …)`, `outbox(sent_at)` |
| quota | `tenant_quota(tenant_id, quota_limit, used)`, `reservations(request_id, tenant_id, status)`, `processed_messages(message_id)`; log `quota event processed: duplicate_message` |
| transcription | `transcriptions(request_id, status, processed_by)`; log `processing <requestId>` |
| ticket | `tickets(request_id)` |
| notification | `notifications(request_id, kind)` |
