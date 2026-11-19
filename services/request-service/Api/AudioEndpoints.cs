using System.Text.RegularExpressions;
using RequestService.Infrastructure;
using RequestService.Messaging;
using RequestService.Outbox;
using RequestService.Persistence;
using RequestService.Saga;
using RequestService.Storage;

namespace RequestService.Api;

public static partial class AudioEndpoints
{
    public static void MapAudioEndpoints(this WebApplication app)
    {
        app.MapPost("/audios", ReceiveAudioAsync).DisableAntiforgery();
        app.MapGet("/audios", ListAsync);
        app.MapGet("/audios/{id:guid}", GetStatusAsync);
    }

    /// <summary>
    /// 202 + statusUrl (R3). Grava no S3 primeiro (S3 fora ⇒ 503 e nada criado); depois, numa transação,
    /// o pedido RECEIVED + AudioReceived no outbox. Com o broker fora o relay publica depois (F6).
    /// </summary>
    static async Task<IResult> ReceiveAudioAsync(
        HttpRequest http, Database database, AudioRequestRepository requests, AudioStorage storage, OutboxWriter outbox,
        ILogger<AudioRequest> log, CancellationToken ct)
    {
        if (!http.HasFormContentType) return Results.BadRequest(new { error = "envie multipart/form-data com tenantId e file" });

        var form = await http.ReadFormAsync(ct);
        var tenantId = form["tenantId"].ToString();
        var file = form.Files["file"];
        if (!TenantIdPattern().IsMatch(tenantId) || file is null || file.Length == 0)
            return Results.BadRequest(new { error = "tenantId (letras, números, _ ou -) e file são obrigatórios" });

        var requestId = Guid.NewGuid();
        var audioKey = AudioStorage.KeyFor(tenantId, requestId, file.FileName);
        using var scope = log.BeginScope(new Dictionary<string, object?> { ["correlationId"] = requestId, ["tenantId"] = tenantId });
        try
        {
            await using (var content = file.OpenReadStream())
                await storage.UploadAsync(audioKey, content, file.ContentType, ct);

            await database.InTransactionAsync(async (connection, transaction) =>
            {
                await requests.InsertAsync(connection, transaction, requestId, tenantId, audioKey);
                await outbox.AddAsync(connection, transaction,
                    Envelope.Create("AudioReceived", requestId, new { requestId, tenantId, audioKey }));
                return true;
            }, ct);
        }
        catch (Exception ex) when (TransientErrors.IsTransient(ex))
        {
            log.LogWarning("POST /audios unavailable: {error}", ex.Message);
            return Results.Json(new { error = "armazenamento indisponível, tente de novo" }, statusCode: StatusCodes.Status503ServiceUnavailable);
        }

        log.LogInformation("{status} {audioKey}", RequestStatus.Received, audioKey);
        var statusUrl = $"/audios/{requestId}";
        return Results.Accepted(statusUrl, new { requestId, statusUrl });
    }

    static async Task<IResult> GetStatusAsync(Guid id, Database database, AudioRequestRepository requests)
    {
        await using var connection = await database.OpenConnectionAsync();
        var request = await requests.FindAsync(connection, id);
        return request is null ? Results.NotFound() : Results.Ok(ToDto(request));
    }

    /// <summary>Lista para o front (aba Pedidos): mais novos primeiro, ?tenantId= opcional, ?limit= 1..200.</summary>
    static async Task<IResult> ListAsync(string? tenantId, int? limit, Database database, AudioRequestRepository requests)
    {
        var size = Math.Clamp(limit ?? 50, 1, 200);
        await using var connection = await database.OpenConnectionAsync();
        var list = await requests.ListAsync(connection, string.IsNullOrWhiteSpace(tenantId) ? null : tenantId, size);
        return Results.Ok(list.Select(ToDto));
    }

    static object ToDto(AudioRequest request) => new
    {
        requestId = request.Id,
        request.TenantId,
        request.Status,
        request.Category,
        request.Priority,
        request.TicketId,
        request.FailureReason,
        request.CreatedAt,
        request.UpdatedAt,
    };

    [GeneratedRegex("^[A-Za-z0-9_-]{1,64}$")]
    private static partial Regex TenantIdPattern();
}
