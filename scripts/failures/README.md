# Cenários de falha F1–F8

Um script por cenário: provoca a falha e já imprime as consultas SQL de verificação.

```bash
docker compose --profile apps up -d
scripts/failures/F5-corrida.sh
```

| Script | Cenário |
|---|---|
| `F1-compensacao.sh` | dependência 100% falha → compensação |
| `F2-servico-morre.sh` | `docker kill` na réplica que processa |
| `F3-duplicada.sh` | mesmo `messageId` 5× |
| `F4-venenosa.sh` | payload inválido → DLQ |
| `F5-corrida.sh` | 100 POSTs para 10 créditos |
| `F6-broker-fora.sh` | RabbitMQ parado 30 s |
| `F7-resposta-tardia.sh` | latência 20 s > timeout 10 s |
| `F8-escala.sh` | 3 réplicas, 30 áudios |

> **Atenção, donos dos serviços:** os scripts assumem estes nomes de tabela/coluna. Se mudarem,
> atualizem aqui também.
>
> | database | tabela | colunas usadas |
> |---|---|---|
> | requests | `requests` | `id`, `tenant_id`, `status`, `failure_reason` |
> | requests | `outbox` | `sent_at` |
> | quota | `tenant_quota` | `tenant_id` (PK), `quota_limit`, `used` |
> | quota | `reservations` | `request_id`, `tenant_id`, `status` |
> | quota | `processed_messages` | `message_id` |
> | transcription | `transcriptions` | `request_id`, `processed_by`, `status` |
> | ticket | `tickets` | `request_id` |
> | notification | `notifications` | `request_id`, `kind`, `created_at` |
>
> Logs esperados: worker loga `processing <requestId>`; consumidores logam `duplicate, skipped`.
