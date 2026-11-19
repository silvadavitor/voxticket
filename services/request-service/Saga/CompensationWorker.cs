using RequestService.Persistence;
using RequestService.Storage;

namespace RequestService.Saga;

/// <summary>
/// Termina as compensações: move o áudio para failed/ e marca FAILED. Fica fora da transação do consumidor
/// porque o S3 não é transacional; se o processo cair no meio, a próxima rodada termina o trabalho.
/// </summary>
public sealed class CompensationWorker(
    Database database, AudioRequestRepository requests, AudioStorage storage, ILogger<CompensationWorker> log) : BackgroundService
{
    static readonly TimeSpan Interval = TimeSpan.FromSeconds(2);

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        await database.Ready.WaitAsync(ct);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await FinishCompensationsAsync(ct);
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                log.LogWarning("compensation failed, retrying: {error}", ex.Message);
            }
            await Task.Delay(Interval, ct);
        }
    }

    async Task FinishCompensationsAsync(CancellationToken ct)
    {
        await using var connection = await database.OpenConnectionAsync(ct);
        foreach (var request in await requests.ListCompensatingAsync(connection))
        {
            using var scope = log.BeginScope(new Dictionary<string, object?> { ["correlationId"] = request.Id });
            await storage.MoveToFailedAsync(request.AudioKey, ct);
            await requests.MarkFailedAsync(connection, request.Id);
            log.LogInformation("audio moved to failed/, {from} -> {to}", RequestStatus.Compensating, RequestStatus.Failed);
        }
    }
}
