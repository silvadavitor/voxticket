using RequestService.Persistence;

namespace RequestService.Saga;

/// <summary>A cada 2 s: pedidos em TRANSCRIBING com prazo vencido ⇒ EXPIRED + libera crédito + avisa o cliente.</summary>
public sealed class SagaTimeoutWorker(
    Database database, AudioRequestRepository requests, RequestSaga saga, ILogger<SagaTimeoutWorker> log) : BackgroundService
{
    static readonly TimeSpan Interval = TimeSpan.FromSeconds(2);

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        await database.Ready.WaitAsync(ct);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await ExpireOverdueAsync(ct);
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                log.LogWarning("timeout check failed, retrying: {error}", ex.Message);
            }
            await Task.Delay(Interval, ct);
        }
    }

    Task ExpireOverdueAsync(CancellationToken ct) => database.InTransactionAsync(async (connection, transaction) =>
    {
        foreach (var request in await requests.ExpireOverdueAsync(connection, transaction))
        {
            using var scope = log.BeginScope(new Dictionary<string, object?> { ["correlationId"] = request.Id });
            log.LogWarning("saga timeout: {from} -> {to}", RequestStatus.Transcribing, RequestStatus.Expired);
            await saga.OnExpiredAsync(connection, transaction, request);
        }
        return true;
    }, ct);
}
