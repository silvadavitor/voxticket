using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Logging.Console;
using NotificationService.Configuration;
using NotificationService.Messaging;

namespace NotificationService.Observability;

/// <summary>Uma linha JSON por log, com service, hostname, os campos de escopo (correlationId...) e o trace.</summary>
public sealed class JsonLogFormatter() : ConsoleFormatter(FormatterName)
{
    public const string FormatterName = "jsonline";

    public override void Write<TState>(in LogEntry<TState> entry, IExternalScopeProvider? scopes, TextWriter writer)
    {
        var fields = new Dictionary<string, object?>
        {
            ["ts"] = DateTime.UtcNow.ToString("O"),
            ["level"] = entry.LogLevel.ToString(),
            ["service"] = EnvironmentVariables.ServiceName,
            ["hostname"] = EnvironmentVariables.HostName,
            ["logger"] = entry.Category,
            ["msg"] = entry.Formatter(entry.State, entry.Exception),
        };
        scopes?.ForEachScope((scope, target) => AddFields(scope, target), fields);
        AddFields(entry.State, fields);
        if (Activity.Current is { } activity)
        {
            fields["trace_id"] = activity.TraceId.ToString();
            fields["span_id"] = activity.SpanId.ToString();
        }
        if (entry.Exception is not null) fields["exc"] = entry.Exception.ToString();
        writer.WriteLine(JsonSerializer.Serialize(fields, JsonDefaults.Options));
    }

    static void AddFields(object? source, Dictionary<string, object?> target)
    {
        if (source is not IEnumerable<KeyValuePair<string, object?>> pairs) return;
        foreach (var (key, value) in pairs)
            if (key != "{OriginalFormat}") target[key] = ToSimpleValue(value);
    }

    static object? ToSimpleValue(object? value) =>
        value is null or string or bool or int or long or double or decimal or Guid or DateTime ? value : value.ToString();
}
