using Microsoft.Extensions.Logging.Console;
using OpenTelemetry.Trace;
using NotificationService.Configuration;
using NotificationService.Messaging;
using NotificationService.Notifications;
using NotificationService.Observability;
using NotificationService.Persistence;

namespace NotificationService.Hosting;

public static class ServiceRegistration
{
    public static WebApplicationBuilder AddNotificationService(this WebApplicationBuilder builder)
    {
        builder.WebHost.UseUrls($"http://0.0.0.0:{EnvironmentVariables.Integer("HTTP_PORT", 8080)}");
        builder.Logging.AddJsonConsole();
        builder.Services.AddTelemetry();
        builder.Services
            .AddSingleton(new ContractValidator(Path.Combine(AppContext.BaseDirectory, "contracts")))
            .AddSingleton<Database>()
            .AddSingleton<DatabaseMigrator>()
            .AddSingleton<RabbitMqConnection>()
            .AddSingleton<MessageConsumer>()
            .AddSingleton<NotificationRepository>()
            .AddSingleton<IMessageHandlers, NotificationHandlers>()
            .AddHostedService<MessagingStartup>();
        return builder;
    }

    static void AddJsonConsole(this ILoggingBuilder logging) => logging
        .ClearProviders()
        .AddConsole(console => console.FormatterName = JsonLogFormatter.FormatterName)
        .AddConsoleFormatter<JsonLogFormatter, ConsoleFormatterOptions>()
        .AddFilter("Microsoft", LogLevel.Warning)
        .AddFilter("System", LogLevel.Warning);

    static void AddTelemetry(this IServiceCollection services)
    {
        if (!Tracing.IsExportEnabled) return;
        services.AddOpenTelemetry().WithTracing(tracing => tracing.AddSource(Tracing.Name).AddOtlpExporter());
    }
}
