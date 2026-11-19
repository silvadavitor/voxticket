using System.Diagnostics;
using Dapper;
using Npgsql;
using RequestService.Infrastructure;
using RequestService.Messaging;
using RequestService.Observability;
using RequestService.Persistence;

namespace RequestService.Outbox;

/// <summary>
/// Publica os eventos pendentes do outbox em ordem, com publisher confirm, e só então marca sent_at.
/// Broker fora ⇒ espera e tenta de novo (a API continua aceitando pedidos; F6).
/// </summary>
public sealed class OutboxRelay(Database database, RabbitMqConnection broker, ILogger<OutboxRelay> log) : BackgroundService
{
    const int BatchSize = 50;
    static readonly TimeSpan IdleDelay = TimeSpan.FromMilliseconds(500);

    public long PendingCount { get; private set; }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        await database.Ready.WaitAsync(ct);
        var errorDelay = TimeSpan.FromSeconds(1);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var published = broker.IsOpen ? await PublishPendingAsync(ct) : 0;
                errorDelay = TimeSpan.FromSeconds(1);
                if (published == 0) await Task.Delay(IdleDelay, ct);
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                log.LogWarning("outbox relay error, retrying in {delay}s: {error}", errorDelay.TotalSeconds, ex.Message);
                await Task.Delay(errorDelay, ct);
                errorDelay = Retry.NextDelay(errorDelay);
            }
        }
    }

    async Task<int> PublishPendingAsync(CancellationToken ct)
    {
        await using var connection = await database.OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        // SKIP LOCKED: várias réplicas não publicam a mesma linha
        var pending = await connection.QueryAsync<PendingEvent>(
            "SELECT id, message_id, type, body::text AS body, traceparent FROM outbox " +
            "WHERE sent_at IS NULL ORDER BY id LIMIT @BatchSize FOR UPDATE SKIP LOCKED",
            new { BatchSize }, transaction);

        var published = new List<long>();
        Exception? failure = null;
        foreach (var pendingEvent in pending)
        {
            try
            {
                await PublishAsync(pendingEvent, ct);
                published.Add(pendingEvent.Id);
            }
            catch (Exception ex)
            {
                failure = ex; // para no primeiro erro para manter a ordem
                break;
            }
        }

        await MarkSentAsync(connection, transaction, published);
        PendingCount = await connection.ExecuteScalarAsync<long>("SELECT count(*) FROM outbox WHERE sent_at IS NULL", transaction: transaction);
        await transaction.CommitAsync(ct);
        if (failure is not null) throw failure;
        return published.Count;
    }

    async Task PublishAsync(PendingEvent pendingEvent, CancellationToken ct)
    {
        using var activity = Tracing.Source.StartActivity(
            $"{pendingEvent.Type} publish", ActivityKind.Producer, Tracing.ParentFrom(pendingEvent.Traceparent));
        var correlationId = Envelope.FromJson(System.Text.Json.Nodes.JsonNode.Parse(pendingEvent.Body)!.AsObject()).CorrelationId;
        await broker.PublishAsync(pendingEvent.Type, pendingEvent.MessageId, correlationId, pendingEvent.Body,
            activity?.Id ?? pendingEvent.Traceparent, ct);
        log.LogInformation("published {type} correlationId={correlationId}", pendingEvent.Type, correlationId);
    }

    static Task MarkSentAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, List<long> ids) =>
        ids.Count == 0
            ? Task.CompletedTask
            : connection.ExecuteAsync("UPDATE outbox SET sent_at = now() WHERE id = ANY(@ids)", new { ids = ids.ToArray() }, transaction);

    sealed class PendingEvent
    {
        public long Id { get; init; }
        public Guid MessageId { get; init; }
        public string Type { get; init; } = "";
        public string Body { get; init; } = "";
        public string? Traceparent { get; init; }
    }
}
