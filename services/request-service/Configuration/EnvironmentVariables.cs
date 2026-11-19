namespace RequestService.Configuration;

/// <summary>Toda configuração vem de variáveis de ambiente; nada fixo no código.</summary>
public static class EnvironmentVariables
{
    public static string ServiceName { get; } = Optional("SERVICE_NAME") ?? "request-service";
    public static string HostName { get; } = Environment.MachineName;

    public static string Required(string name) =>
        Optional(name) ?? throw new InvalidOperationException($"variável de ambiente obrigatória ausente: {name}");

    public static string? Optional(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    public static int Integer(string name, int fallback) =>
        int.TryParse(Optional(name), out var value) ? value : fallback;
}
