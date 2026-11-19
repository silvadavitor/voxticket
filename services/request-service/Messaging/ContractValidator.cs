using System.Text.Json;
using System.Text.Json.Nodes;
using Json.Schema;

namespace RequestService.Messaging;

/// <summary>Valida mensagens contra os JSON Schemas em contracts/ (cópia dos schemas do repo).</summary>
public sealed class ContractValidator
{
    const string EnvelopeSchema = "envelope";
    static readonly EvaluationOptions Options = new() { OutputFormat = OutputFormat.List, RequireFormatValidation = true };
    readonly Dictionary<string, JsonSchema> _schemas = new();

    public ContractValidator(string contractsDirectory)
    {
        foreach (var file in Directory.GetFiles(contractsDirectory, "*.schema.json"))
            _schemas[Path.GetFileName(file).Replace(".schema.json", "")] = LoadSchema(file);
    }

    public Envelope Parse(byte[] body)
    {
        JsonNode? node;
        try { node = JsonNode.Parse(body); }
        catch (JsonException ex) { throw new InvalidMessageException($"JSON inválido: {ex.Message}"); }

        if (node is not JsonObject json) throw new InvalidMessageException("a mensagem não é um objeto JSON");
        Validate(json);
        return Envelope.FromJson(json);
    }

    public void Validate(JsonObject message)
    {
        Evaluate(EnvelopeSchema, message);
        var schemaName = $"{message["type"]}.v{message["version"]}";
        if (!_schemas.ContainsKey(schemaName)) throw new InvalidMessageException($"schema desconhecido: {schemaName}");
        Evaluate(schemaName, message);
    }

    static JsonSchema LoadSchema(string file)
    {
        var json = JsonNode.Parse(File.ReadAllText(file))!.AsObject();
        // o envelope é validado à parte, então o "allOf: [$ref envelope]" não precisa ser resolvido
        json.Remove("$id");
        json.Remove("$schema");
        json.Remove("allOf");
        return JsonSchema.FromText(json.ToJsonString());
    }

    void Evaluate(string schemaName, JsonNode message)
    {
        var result = _schemas[schemaName].Evaluate(JsonSerializer.SerializeToElement(message), Options);
        if (result.IsValid) return;

        var errors = (result.Details ?? []).Prepend(result)
            .Where(detail => detail.Errors is { Count: > 0 })
            .SelectMany(detail => detail.Errors!.Select(error => $"{detail.InstanceLocation}: {error.Value}"))
            .Take(3);
        throw new InvalidMessageException($"schema {schemaName}: {string.Join("; ", errors)}");
    }
}
