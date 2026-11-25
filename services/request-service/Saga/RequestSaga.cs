using System.Diagnostics.Metrics;
using Npgsql;
using RequestService.Configuration;
using RequestService.Messaging;
using RequestService.Observability;
using RequestService.Outbox;

namespace RequestService.Saga;

/// <summary>
/// Orquestrador da saga: um handler por evento. Cada handler confere o estado atual e ignora
/// transições fora de ordem (loga e dá ACK). Tudo roda na transação do consumidor.
/// </summary>
public sealed class RequestSaga : IMessageHandlers
{
    static readonly TimeSpan TranscriptionTimeout = TimeSpan.FromMilliseconds(EnvironmentVariables.Integer("SAGA_TIMEOUT_MS", 60000));
    static readonly Counter<long> Completed = Tracing.Meter.CreateCounter<long>("voxticket.saga.completed");
    static readonly Counter<long> Compensated = Tracing.Meter.CreateCounter<long>("voxticket.saga.compensated");
    static readonly string[] KnownReasons = ["TIMEOUT", "TRANSCRIPTION_FAILED", "TICKET_REJECTED"];

    // Cria as séries valendo 0 já no start. Sem isso a série só nasce na 1ª compensação e, se várias vêm
    // juntas (ex.: 23 timeouts entre dois envios), aparece direto com 23 e o increase() do painel conta 0.
    static RequestSaga()
    {
        Completed.Add(0);
        foreach (var reason in KnownReasons) Compensated.Add(0, ReasonTag(reason));
    }

    // Só o código do motivo vira label ("TRANSCRIPTION_FAILED: InvalidDataError..." → "TRANSCRIPTION_FAILED"):
    // texto livre no label cria uma série nova por mensagem de erro.
    static KeyValuePair<string, object?> ReasonTag(string reason) =>
        new("reason", reason.Split(':', 2)[0].Trim() is { Length: > 0 and <= 64 } code ? code : "OTHER");

    readonly AudioRequestRepository _requests;
    readonly OutboxWriter _outbox;
    readonly ILogger<RequestSaga> _log;

    public RequestSaga(AudioRequestRepository requests, OutboxWriter outbox, ILogger<RequestSaga> log)
    {
        _requests = requests;
        _outbox = outbox;
        _log = log;
        ByType = new Dictionary<string, MessageHandler>
        {
            ["CreditReserved"] = OnCreditReservedAsync,
            ["CreditRejected"] = OnCreditRejectedAsync,
            ["AudioTranscribed"] = OnAudioTranscribedAsync,
            ["TranscriptionFailed"] = OnTranscriptionFailedAsync,
            ["AudioCategorized"] = OnAudioCategorizedAsync,
            ["TicketOpened"] = OnTicketOpenedAsync,
            ["TicketRejected"] = OnTicketRejectedAsync,
        };
    }

    public IReadOnlyDictionary<string, MessageHandler> ByType { get; }

    async Task OnCreditReservedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        if (await LockInStatusAsync(connection, transaction, message, RequestStatus.Received) is not { } request) return;

        var deadline = DateTime.UtcNow + TranscriptionTimeout;
        await TransitionAsync(connection, transaction, request, RequestStatus.Transcribing, new RequestChanges(Deadline: deadline));
        await PublishAsync(connection, transaction, "TranscriptionRequested", request, new
        {
            requestId = request.Id,
            tenantId = request.TenantId,
            audioKey = request.AudioKey,
            deadline = deadline.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"),
        });
    }

    async Task OnCreditRejectedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        if (await LockInStatusAsync(connection, transaction, message, RequestStatus.Received) is not { } request) return;

        const string reason = "NO_QUOTA";
        await TransitionAsync(connection, transaction, request, RequestStatus.Rejected, new RequestChanges(FailureReason: reason));
        await PublishRequestFailedAsync(connection, transaction, request, RequestStatus.Rejected, reason);
    }

    async Task OnAudioTranscribedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        var request = await LockInStatusAsync(connection, transaction, message, RequestStatus.Transcribing, RequestStatus.Expired);
        if (request is null) return;

        var transcriptKey = message.PayloadValue("transcriptKey");
        if (request.Status == RequestStatus.Expired)
        {
            // resultado atrasado (F7): nunca abre chamado; pede o descarte da transcrição
            _log.LogInformation("late transcription for an expired request, requesting discard");
            await PublishAsync(connection, transaction, "TranscriptDiscardRequested", request, new { requestId = request.Id, transcriptKey });
            return;
        }

        await TransitionAsync(connection, transaction, request, RequestStatus.Categorizing, new RequestChanges(TranscriptKey: transcriptKey));
        await PublishAsync(connection, transaction, "CategorizationRequested", request,
            new { requestId = request.Id, tenantId = request.TenantId, transcriptKey });
    }

    async Task OnTranscriptionFailedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        if (await LockInStatusAsync(connection, transaction, message, RequestStatus.Transcribing) is not { } request) return;
        await CompensateAsync(connection, transaction, request, message.OptionalPayloadValue("reason") ?? "TRANSCRIPTION_FAILED");
    }

    async Task OnAudioCategorizedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        if (await LockInStatusAsync(connection, transaction, message, RequestStatus.Categorizing) is not { } request) return;

        var category = message.PayloadValue("category");
        var priority = message.OptionalPayloadValue("priority");
        await TransitionAsync(connection, transaction, request, RequestStatus.TicketRequested,
            new RequestChanges(Category: category, Priority: priority));
        await PublishAsync(connection, transaction, "TicketRequested", request, new
        {
            requestId = request.Id,
            tenantId = request.TenantId,
            category,
            priority,
            transcriptKey = request.TranscriptKey,
        });
    }

    async Task OnTicketOpenedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        if (await LockInStatusAsync(connection, transaction, message, RequestStatus.TicketRequested) is not { } request) return;

        await TransitionAsync(connection, transaction, request, RequestStatus.TicketOpened,
            new RequestChanges(TicketId: message.PayloadValue("ticketId")));
        Completed.Add(1);
    }

    async Task OnTicketRejectedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message)
    {
        if (await LockInStatusAsync(connection, transaction, message, RequestStatus.TicketRequested) is not { } request) return;
        await CompensateAsync(connection, transaction, request, message.OptionalPayloadValue("reason") ?? "TICKET_REJECTED");
    }

    /// <summary>
    /// Compensação: libera o crédito e avisa o cliente. Mover o áudio para failed/ e marcar FAILED fica com o
    /// CompensationWorker, porque o S3 não participa da transação.
    /// </summary>
    async Task CompensateAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, AudioRequest request, string reason)
    {
        await TransitionAsync(connection, transaction, request, RequestStatus.Compensating, new RequestChanges(FailureReason: reason));
        await PublishCreditReleaseAsync(connection, transaction, request, reason);
        await PublishRequestFailedAsync(connection, transaction, request, RequestStatus.Failed, reason);
        Compensated.Add(1, ReasonTag(reason));
    }

    /// <summary>Chamado pelo SagaTimeoutWorker depois de marcar o pedido como EXPIRED.</summary>
    public async Task OnExpiredAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, AudioRequest request)
    {
        const string reason = "TIMEOUT";
        await PublishCreditReleaseAsync(connection, transaction, request, reason);
        await PublishRequestFailedAsync(connection, transaction, request, RequestStatus.Expired, reason);
        Compensated.Add(1, ReasonTag(reason));
    }

    async Task<AudioRequest?> LockInStatusAsync(
        NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message, params string[] expectedStatuses)
    {
        var request = await _requests.LockAsync(connection, transaction, message.RequestId);
        if (request is null)
        {
            _log.LogWarning("unknown request, ignored");
            return null;
        }
        if (expectedStatuses.Contains(request.Status)) return request;

        _log.LogInformation("out of order: request is {status}, {type} ignored", request.Status, message.Type);
        return null;
    }

    async Task TransitionAsync(
        NpgsqlConnection connection, NpgsqlTransaction transaction, AudioRequest request, string status, RequestChanges changes)
    {
        await _requests.UpdateStatusAsync(connection, transaction, request.Id, status, changes);
        _log.LogInformation("{from} -> {to}", request.Status, status);
    }

    Task PublishCreditReleaseAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, AudioRequest request, string reason) =>
        PublishAsync(connection, transaction, "CreditReleaseRequested", request,
            new { requestId = request.Id, tenantId = request.TenantId, reason });

    Task PublishRequestFailedAsync(
        NpgsqlConnection connection, NpgsqlTransaction transaction, AudioRequest request, string finalStatus, string reason) =>
        PublishAsync(connection, transaction, "RequestFailed", request,
            new { requestId = request.Id, tenantId = request.TenantId, finalStatus, reason });

    Task PublishAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string type, AudioRequest request, object payload) =>
        _outbox.AddAsync(connection, transaction, Envelope.Create(type, request.Id, payload));
}
