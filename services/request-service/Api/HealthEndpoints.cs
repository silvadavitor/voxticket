using RequestService.Messaging;
using RequestService.Outbox;
using RequestService.Persistence;

namespace RequestService.Api;

public static class HealthEndpoints
{
    /// <summary>Sempre 200: broker ou banco fora deixam o serviço "degraded", mas ele segue de pé (R6).</summary>
    public static void MapHealthEndpoints(this WebApplication app) =>
        app.MapGet("/health", async (Database database, RabbitMqConnection broker, OutboxRelay outbox) =>
        {
            var databaseUp = await database.IsHealthyAsync();
            return Results.Ok(new
            {
                status = databaseUp && broker.IsOpen ? "ok" : "degraded",
                broker = broker.IsOpen ? "up" : "down",
                db = databaseUp ? "up" : "down",
                outboxPending = outbox.PendingCount,
            });
        });
}
