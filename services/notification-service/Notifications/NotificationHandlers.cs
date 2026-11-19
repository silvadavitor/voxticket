using Npgsql;
using NotificationService.Messaging;

namespace NotificationService.Notifications;

/// <summary>Avisa o cliente. O "e-mail" é simulado: uma linha de log + uma linha na tabela notifications.</summary>
public sealed class NotificationHandlers : IMessageHandlers
{
    const string TicketOpenedKind = "TICKET_OPENED";
    const string RequestFailedKind = "REQUEST_FAILED";

    readonly NotificationRepository _notifications;
    readonly ILogger<NotificationHandlers> _log;

    public NotificationHandlers(NotificationRepository notifications, ILogger<NotificationHandlers> log)
    {
        _notifications = notifications;
        _log = log;
        ByType = new Dictionary<string, MessageHandler>
        {
            ["TicketOpened"] = OnTicketOpenedAsync,
            ["RequestFailed"] = OnRequestFailedAsync,
        };
    }

    public IReadOnlyDictionary<string, MessageHandler> ByType { get; }

    Task OnTicketOpenedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message) =>
        NotifyAsync(connection, transaction, message, TicketOpenedKind,
            $"Seu chamado {message.PayloadValue("ticketId")} foi aberto.");

    Task OnRequestFailedAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message) =>
        NotifyAsync(connection, transaction, message, RequestFailedKind,
            $"Seu pedido terminou como {message.PayloadValue("finalStatus")}: {message.OptionalPayloadValue("reason") ?? "sem motivo informado"}.");

    async Task NotifyAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message, string kind, string text)
    {
        var tenantId = message.PayloadValue("tenantId");
        if (await _notifications.TryInsertAsync(connection, transaction, message.RequestId, tenantId, kind, text))
            _log.LogInformation("e-mail (simulado) para {tenantId}: {message}", tenantId, text);
    }
}
