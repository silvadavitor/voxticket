using System.Text.Json;
using System.Text.Json.Nodes;

namespace RequestService.Messaging;

/// <summary>Envelope obrigatório de toda mensagem (contracts/envelope.schema.json).</summary>
public sealed record Envelope(Guid MessageId, Guid CorrelationId, string Type, int Version, string OccurredAt, JsonObject Payload)
{
    public static Envelope Create(string type, Guid correlationId, object payload) => new(
        Guid.NewGuid(),
        correlationId,
        type,
        Version: 1,
        DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"),
        JsonSerializer.SerializeToNode(payload, JsonDefaults.Options)!.AsObject());

    public static Envelope FromJson(JsonObject json) => new(
        Guid.Parse(json["messageId"]!.GetValue<string>()),
        Guid.Parse(json["correlationId"]!.GetValue<string>()),
        json["type"]!.GetValue<string>(),
        json["version"]!.GetValue<int>(),
        json["occurredAt"]!.GetValue<string>(),
        json["payload"]!.AsObject());

    public Guid RequestId => Guid.Parse(PayloadValue("requestId"));

    public string PayloadValue(string key) => OptionalPayloadValue(key) ?? "";

    public string? OptionalPayloadValue(string key) => Payload[key]?.GetValue<string>();

    public JsonObject ToJson() => new()
    {
        ["messageId"] = MessageId.ToString(),
        ["correlationId"] = CorrelationId.ToString(),
        ["type"] = Type,
        ["version"] = Version,
        ["occurredAt"] = OccurredAt,
        ["payload"] = Payload.DeepClone(),
    };
}
