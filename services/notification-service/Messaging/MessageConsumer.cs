using System.Diagnostics;
using System.Text;
using Dapper;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using NotificationService.Configuration;
using NotificationService.Infrastructure;
using NotificationService.Observability;
using NotificationService.Persistence;

namespace NotificationService.Messaging;

/// <summary>
/// Consumidor idempotente (R1). Para cada mensagem, numa transação: INSERT processed_messages
/// (0 linhas = duplicada) + efeito do handler; ACK só depois do COMMIT.
/// Inválida ⇒ nack ⇒ DLQ após 3 entregas. Banco fora ⇒ tenta de novo segurando a mensagem.
/// </summary>
public sealed class MessageConsumer(Database database, ContractValidator contracts, ILogger<MessageConsumer> log)
{
    readonly string _queue = EnvironmentVariables.Required("BROKER_QUEUE");
    readonly ushort _prefetch = (ushort)EnvironmentVariables.Integer("BROKER_PREFETCH", 1);

    public async Task StartAsync(IConnection connection, IMessageHandlers handlers, CancellationToken ct)
    {
        await Retry.ForeverAsync(async () =>
        {
            var channel = await connection.CreateChannelAsync(cancellationToken: ct);
            await channel.BasicQosAsync(0, _prefetch, false, ct);
            await channel.QueueDeclarePassiveAsync(_queue, ct); // a fila vem do rabbitmq/definitions.json
            var consumer = new AsyncEventingBasicConsumer(channel);
            consumer.ReceivedAsync += (_, delivery) => HandleDeliveryAsync(channel, delivery, handlers, ct);
            await channel.BasicConsumeAsync(_queue, autoAck: false, consumer, ct);
        }, $"consume {_queue}", log, ct, isRetryable: _ => true);
        log.LogInformation("consuming {queue}", _queue);
    }

    async Task HandleDeliveryAsync(IChannel channel, BasicDeliverEventArgs delivery, IMessageHandlers handlers, CancellationToken ct)
    {
        Envelope message;
        MessageHandler handler;
        try
        {
            message = contracts.Parse(delivery.Body.ToArray());
            handler = handlers.ByType.GetValueOrDefault(message.Type)
                ?? throw new InvalidMessageException($"nenhum handler para {message.Type}");
        }
        catch (InvalidMessageException ex)
        {
            log.LogError("invalid message, nack (DLQ after delivery limit): {error} messageId={messageId}", ex.Message, delivery.BasicProperties.MessageId);
            await RejectAsync(channel, delivery, ct);
            return;
        }

        using var activity = StartConsumerActivity(delivery, message);
        using var scope = log.BeginScope(new Dictionary<string, object?>
        {
            ["correlationId"] = message.CorrelationId,
            ["messageId"] = message.MessageId,
            ["type"] = message.Type,
        });
        log.LogInformation("received");
        await ProcessAsync(channel, delivery, message, handler, ct);
    }

    async Task ProcessAsync(IChannel channel, BasicDeliverEventArgs delivery, Envelope message, MessageHandler handler, CancellationToken ct)
    {
        var delay = TimeSpan.FromSeconds(1);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var applied = await database.InTransactionAsync(async (connection, transaction) =>
                {
                    var inserted = await connection.ExecuteAsync(
                        "INSERT INTO processed_messages(message_id) VALUES (@MessageId) ON CONFLICT DO NOTHING",
                        new { message.MessageId }, transaction);
                    if (inserted == 0) return false;
                    await handler(connection, transaction, message);
                    return true;
                }, ct);
                if (!applied) log.LogInformation("duplicate, skipped");
                await AcknowledgeAsync(channel, delivery, ct);
                return;
            }
            catch (InvalidMessageException ex)
            {
                log.LogError("invalid payload, nack: {error}", ex.Message);
                await RejectAsync(channel, delivery, ct);
                return;
            }
            catch (Exception ex) when (TransientErrors.IsTransient(ex))
            {
                if (!channel.IsOpen) return; // o broker reentrega; a duplicata é descartada pelo processed_messages
                log.LogWarning("infra unavailable, holding the message and retrying in {delay}s: {error}", delay.TotalSeconds, ex.Message);
                await Task.Delay(delay, ct);
                delay = Retry.NextDelay(delay);
            }
            catch (Exception ex)
            {
                log.LogError(ex, "handler failed, nack");
                await RejectAsync(channel, delivery, ct);
                return;
            }
        }
    }

    static Activity? StartConsumerActivity(BasicDeliverEventArgs delivery, Envelope message)
    {
        var traceparent = delivery.BasicProperties.Headers?.TryGetValue("traceparent", out var header) == true && header is byte[] bytes
            ? Encoding.UTF8.GetString(bytes)
            : null;
        return Tracing.Source.StartActivity($"{message.Type} process", ActivityKind.Consumer, Tracing.ParentFrom(traceparent))
            ?.SetTag("messaging.message.id", message.MessageId)
            .SetTag("messaging.message.conversation_id", message.CorrelationId)
            .SetTag("app.event_type", message.Type);
    }

    Task AcknowledgeAsync(IChannel channel, BasicDeliverEventArgs delivery, CancellationToken ct) =>
        IgnoreClosedChannelAsync(() => channel.BasicAckAsync(delivery.DeliveryTag, false, ct).AsTask());

    // requeue=true conta uma entrega; a fila quorum manda para a DLQ após x-delivery-limit
    Task RejectAsync(IChannel channel, BasicDeliverEventArgs delivery, CancellationToken ct) =>
        IgnoreClosedChannelAsync(() => channel.BasicNackAsync(delivery.DeliveryTag, false, requeue: true, ct).AsTask());

    async Task IgnoreClosedChannelAsync(Func<Task> operation)
    {
        try { await operation(); }
        catch (Exception ex) { log.LogWarning("ack/nack failed, the message will be redelivered: {error}", ex.Message); }
    }
}
