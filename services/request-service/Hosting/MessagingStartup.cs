using RequestService.Messaging;
using RequestService.Persistence;

namespace RequestService.Hosting;

/// <summary>Ordem de subida: credenciais → banco + migrations → broker → consumo. Nada aqui derruba o processo.</summary>
public sealed class MessagingStartup(
    Database database,
    DatabaseMigrator migrator,
    RabbitMqConnection broker,
    MessageConsumer consumer,
    IMessageHandlers handlers,
    ILogger<MessagingStartup> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        database.Configure(await DatabaseCredentials.LoadAsync(log, ct));
        await migrator.MigrateAsync(ct);
        database.MarkReady();

        var connection = await broker.ConnectAsync(ct);
        await consumer.StartAsync(connection, handlers, ct);
    }
}
