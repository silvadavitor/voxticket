namespace RequestService.Infrastructure;

public static class Retry
{
    static readonly TimeSpan MaxDelay = TimeSpan.FromSeconds(30);

    /// <summary>Repete com backoff exponencial (1 s → 30 s) enquanto o erro for transitório.</summary>
    public static async Task ForeverAsync(
        Func<Task> action, string operation, ILogger log, CancellationToken ct, Func<Exception, bool>? isRetryable = null)
    {
        isRetryable ??= TransientErrors.IsTransient;
        var delay = TimeSpan.FromSeconds(1);
        while (true)
        {
            try
            {
                await action();
                return;
            }
            catch (Exception ex) when (isRetryable(ex) && !ct.IsCancellationRequested)
            {
                log.LogWarning("{operation} falhou ({error}); nova tentativa em {delay}s", operation, ex.Message, delay.TotalSeconds);
                await Task.Delay(delay, ct);
                delay = NextDelay(delay);
            }
        }
    }

    public static TimeSpan NextDelay(TimeSpan current) =>
        TimeSpan.FromSeconds(Math.Min(current.TotalSeconds * 2, MaxDelay.TotalSeconds));
}
