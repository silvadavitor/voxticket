using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Logging.Console;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using RequestService.Configuration;
using RequestService.Messaging;
using RequestService.Observability;
using RequestService.Outbox;
using RequestService.Persistence;
using RequestService.Saga;
using RequestService.Storage;

namespace RequestService.Hosting;

public static class ServiceRegistration
{
    public static WebApplicationBuilder AddRequestService(this WebApplicationBuilder builder)
    {
        builder.ConfigureHttp();
        builder.Logging.AddJsonConsole();
        builder.Services.AddTelemetry();
        builder.Services
            .AddSingleton(new ContractValidator(Path.Combine(AppContext.BaseDirectory, "contracts")))
            .AddSingleton<Database>()
            .AddSingleton<DatabaseMigrator>()
            .AddSingleton<RabbitMqConnection>()
            .AddSingleton<MessageConsumer>()
            .AddSingleton<AudioStorage>()
            .AddSingleton<AudioRequestRepository>()
            .AddSingleton<OutboxWriter>()
            .AddSingleton<RequestSaga>()
            .AddSingleton<IMessageHandlers>(services => services.GetRequiredService<RequestSaga>())
            .AddSingleton<OutboxRelay>()
            .AddHostedService(services => services.GetRequiredService<OutboxRelay>())
            .AddHostedService<MessagingStartup>()
            .AddHostedService<SagaTimeoutWorker>()
            .AddHostedService<CompensationWorker>();
        return builder;
    }

    static void ConfigureHttp(this WebApplicationBuilder builder)
    {
        var maxUploadBytes = EnvironmentVariables.Integer("MAX_UPLOAD_MB", 100) * 1024L * 1024L;
        builder.WebHost.UseUrls($"http://0.0.0.0:{EnvironmentVariables.Integer("HTTP_PORT", 8080)}");
        builder.WebHost.ConfigureKestrel(kestrel => kestrel.Limits.MaxRequestBodySize = maxUploadBytes);
        builder.Services.Configure<FormOptions>(form => form.MultipartBodyLengthLimit = maxUploadBytes);
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
        services.AddOpenTelemetry()
            .WithTracing(tracing => tracing.AddSource(Tracing.Name).AddAspNetCoreInstrumentation().AddOtlpExporter())
            .WithMetrics(metrics => metrics.AddMeter(Tracing.Name).AddOtlpExporter());
    }

    /// <summary>Gauge voxticket.outbox.pending, lido do relay.</summary>
    public static WebApplication UseOutboxMetrics(this WebApplication app)
    {
        var relay = app.Services.GetRequiredService<OutboxRelay>();
        Tracing.Meter.CreateObservableGauge("voxticket.outbox.pending", () => relay.PendingCount);
        return app;
    }
}
