using System.Diagnostics;
using System.Diagnostics.Metrics;
using RequestService.Configuration;

namespace RequestService.Observability;

public static class Tracing
{
    public const string Name = "voxticket";
    public static readonly ActivitySource Source = new(Name);
    public static readonly Meter Meter = new(Name);

    public static bool IsExportEnabled =>
        EnvironmentVariables.Optional("OTEL_EXPORTER_OTLP_ENDPOINT") is not null
        && EnvironmentVariables.Optional("OTEL_SDK_DISABLED") != "true";

    public static ActivityContext ParentFrom(string? traceparent) =>
        traceparent is not null && ActivityContext.TryParse(traceparent, null, out var context) ? context : default;
}
