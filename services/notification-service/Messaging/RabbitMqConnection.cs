using System.Text;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using RabbitMQ.Client.Exceptions;
using NotificationService.Configuration;
using NotificationService.Infrastructure;

namespace NotificationService.Messaging;

/// <summary>Conexão com o RabbitMQ (container local ou cluster na AWS): retry na subida e reconexão automática depois (R6).</summary>
public sealed class RabbitMqConnection(ILogger<RabbitMqConnection> log)
{
    readonly string _exchange = EnvironmentVariables.Required("BROKER_EXCHANGE");
    readonly SemaphoreSlim _publishLock = new(1, 1);
    IConnection? _connection;
    IChannel? _publishChannel;

    public bool IsOpen => _connection is { IsOpen: true };

    public async Task<IConnection> ConnectAsync(CancellationToken ct)
    {
        var factory = CreateFactory();
        var delay = TimeSpan.FromSeconds(1);
        while (true)
        {
            try
            {
                var connection = await factory.CreateConnectionAsync(ct);
                connection.ConnectionShutdownAsync += (_, args) => LogAsync(LogLevel.Warning, $"broker connection lost: {args.ReplyText}");
                connection.RecoverySucceededAsync += (_, _) => LogAsync(LogLevel.Information, "broker reconnected");
                _publishChannel = await connection.CreateChannelAsync(
                    new CreateChannelOptions(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true), ct);
                await _publishChannel.ExchangeDeclarePassiveAsync(_exchange, ct); // a topologia vem do definitions.json
                _connection = connection;
                log.LogInformation("broker connected");
                return connection;
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                log.LogWarning("broker unavailable ({error}); retrying in {delay}s", ex.Message, delay.TotalSeconds);
                await Task.Delay(delay, ct);
                delay = Retry.NextDelay(delay);
            }
        }
    }

    /// <summary>Mensagem persistente, routing key = tipo do evento; espera o publisher confirm.</summary>
    public async Task PublishAsync(string type, Guid messageId, Guid correlationId, string body, string? traceparent, CancellationToken ct)
    {
        if (_publishChannel is null || !IsOpen)
            throw new AlreadyClosedException(new ShutdownEventArgs(ShutdownInitiator.Application, 0, "broker down"));

        var properties = new BasicProperties
        {
            Persistent = true,
            ContentType = "application/json",
            Type = type,
            AppId = EnvironmentVariables.ServiceName,
            MessageId = messageId.ToString(),
            CorrelationId = correlationId.ToString(),
            Headers = new Dictionary<string, object?>(),
        };
        if (traceparent is not null) properties.Headers["traceparent"] = traceparent;

        await _publishLock.WaitAsync(ct);
        try
        {
            await _publishChannel.BasicPublishAsync(_exchange, type, mandatory: false, properties, Encoding.UTF8.GetBytes(body), ct);
        }
        finally
        {
            _publishLock.Release();
        }
    }

    static ConnectionFactory CreateFactory()
    {
        var factory = new ConnectionFactory
        {
            Uri = new Uri(EnvironmentVariables.Required("BROKER_URL")),
            AutomaticRecoveryEnabled = true,
            TopologyRecoveryEnabled = true,
            NetworkRecoveryInterval = TimeSpan.FromSeconds(5),
            ClientProvidedName = $"{EnvironmentVariables.ServiceName}@{EnvironmentVariables.HostName}",
        };
        // na AWS as credenciais vêm do Secrets Manager e têm precedência sobre a URL
        if (EnvironmentVariables.Optional("BROKER_USERNAME") is { } user)
        {
            factory.UserName = user;
            factory.Password = EnvironmentVariables.Optional("BROKER_PASSWORD") ?? "";
        }
        return factory;
    }

    Task LogAsync(LogLevel level, string message)
    {
        log.Log(level, "{message}", message);
        return Task.CompletedTask;
    }
}
