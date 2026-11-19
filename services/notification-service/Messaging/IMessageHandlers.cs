using Npgsql;

namespace NotificationService.Messaging;

/// <summary>Efeito de um evento. Roda DENTRO da transação do consumidor (junto com processed_messages).</summary>
public delegate Task MessageHandler(NpgsqlConnection connection, NpgsqlTransaction transaction, Envelope message);

public interface IMessageHandlers
{
    IReadOnlyDictionary<string, MessageHandler> ByType { get; }
}
