using Dapper;
using Npgsql;

namespace RequestService.Saga;

/// <summary>Campos que uma transição pode preencher; null = mantém o valor atual.</summary>
public sealed record RequestChanges(
    DateTime? Deadline = null,
    string? TranscriptKey = null,
    string? Category = null,
    string? Priority = null,
    string? TicketId = null,
    string? FailureReason = null);

/// <summary>Todo o SQL da tabela requests.</summary>
public sealed class AudioRequestRepository
{
    public Task InsertAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid id, string tenantId, string audioKey) =>
        connection.ExecuteAsync(
            "INSERT INTO requests(id, tenant_id, status, audio_key) VALUES (@id, @tenantId, @status, @audioKey)",
            new { id, tenantId, status = RequestStatus.Received, audioKey }, transaction);

    public Task<AudioRequest?> FindAsync(NpgsqlConnection connection, Guid id) =>
        connection.QuerySingleOrDefaultAsync<AudioRequest>("SELECT * FROM requests WHERE id=@id", new { id });

    /// <summary>Pedidos mais novos primeiro (GET /audios), opcionalmente de um cliente só.</summary>
    public Task<IEnumerable<AudioRequest>> ListAsync(NpgsqlConnection connection, string? tenantId, int limit) =>
        connection.QueryAsync<AudioRequest>(
            "SELECT * FROM requests WHERE (@tenantId::text IS NULL OR tenant_id = @tenantId) ORDER BY created_at DESC LIMIT @limit",
            new { tenantId, limit });

    /// <summary>Lê com FOR UPDATE: duas mensagens do mesmo pedido não mudam o estado ao mesmo tempo.</summary>
    public Task<AudioRequest?> LockAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid id) =>
        connection.QuerySingleOrDefaultAsync<AudioRequest>("SELECT * FROM requests WHERE id=@id FOR UPDATE", new { id }, transaction);

    public Task UpdateStatusAsync(
        NpgsqlConnection connection, NpgsqlTransaction transaction, Guid id, string status, RequestChanges? changes = null)
    {
        changes ??= new RequestChanges();
        return connection.ExecuteAsync(
            """
            UPDATE requests SET
                status         = @status,
                deadline       = COALESCE(@Deadline, deadline),
                transcript_key = COALESCE(@TranscriptKey, transcript_key),
                category       = COALESCE(@Category, category),
                priority       = COALESCE(@Priority, priority),
                ticket_id      = COALESCE(@TicketId, ticket_id),
                failure_reason = COALESCE(@FailureReason, failure_reason),
                updated_at     = now()
            WHERE id = @id
            """,
            new { id, status, changes.Deadline, changes.TranscriptKey, changes.Category, changes.Priority, changes.TicketId, changes.FailureReason },
            transaction);
    }

    /// <summary>TRANSCRIBING com prazo vencido ⇒ EXPIRED. SKIP LOCKED: seguro com várias réplicas.</summary>
    public Task<IEnumerable<AudioRequest>> ExpireOverdueAsync(NpgsqlConnection connection, NpgsqlTransaction transaction) =>
        connection.QueryAsync<AudioRequest>(
            """
            UPDATE requests SET status = @expired, failure_reason = 'TIMEOUT', updated_at = now()
            WHERE id IN (SELECT id FROM requests WHERE status = @transcribing AND deadline < now() LIMIT 50 FOR UPDATE SKIP LOCKED)
            RETURNING *
            """,
            new { expired = RequestStatus.Expired, transcribing = RequestStatus.Transcribing }, transaction);

    public Task<IEnumerable<AudioRequest>> ListCompensatingAsync(NpgsqlConnection connection) =>
        connection.QueryAsync<AudioRequest>("SELECT * FROM requests WHERE status = @status LIMIT 20", new { status = RequestStatus.Compensating });

    public Task MarkFailedAsync(NpgsqlConnection connection, Guid id) =>
        connection.ExecuteAsync(
            "UPDATE requests SET status = @failed, updated_at = now() WHERE id = @id AND status = @compensating",
            new { id, failed = RequestStatus.Failed, compensating = RequestStatus.Compensating });
}
