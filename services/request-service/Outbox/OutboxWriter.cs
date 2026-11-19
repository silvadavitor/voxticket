using System.Diagnostics;
using Dapper;
using Npgsql;
using RequestService.Messaging;

namespace RequestService.Outbox;

/// <summary>Grava eventos no outbox NA MESMA transação do efeito de negócio (transactional outbox).</summary>
public sealed class OutboxWriter(ContractValidator contracts)
{
    public async Task AddAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        var json = message.ToJson();
        contracts.Validate(json); // contrato quebrado é bug nosso: falha antes de gravar
        await connection.ExecuteAsync(
            "INSERT INTO outbox(message_id, type, body, traceparent) VALUES (@MessageId, @Type, @Body::jsonb, @Traceparent)",
            new
            {
                message.MessageId,
                message.Type,
                Body = json.ToJsonString(JsonDefaults.Options),
                Traceparent = Activity.Current?.Id,
            },
            transaction);
    }
}
