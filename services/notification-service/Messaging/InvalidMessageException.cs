namespace NotificationService.Messaging;

/// <summary>Mensagem que nunca vai dar certo (JSON, schema, tipo): nack ⇒ DLQ após 3 entregas.</summary>
public sealed class InvalidMessageException(string message) : Exception(message);
