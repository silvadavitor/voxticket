using Dapper;
using Npgsql;

namespace NotificationService.Notifications;

public sealed class NotificationRepository
{
    /// <summary>Uma notificação por pedido e tipo. False ⇒ já existia (nada a enviar).</summary>
    public async Task<bool> TryInsertAsync(
        NpgsqlConnection connection, NpgsqlTransaction transaction, Guid requestId, string tenantId, string kind, string message) =>
        await connection.ExecuteAsync(
            """
            INSERT INTO notifications(request_id, tenant_id, kind, message) VALUES (@requestId, @tenantId, @kind, @message)
            ON CONFLICT (request_id, kind) DO NOTHING
            """,
            new { requestId, tenantId, kind, message }, transaction) == 1;
}
