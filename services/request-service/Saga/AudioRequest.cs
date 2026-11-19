namespace RequestService.Saga;

/// <summary>Um pedido de transcrição (linha da tabela requests).</summary>
public sealed class AudioRequest
{
    public Guid Id { get; init; }
    public string TenantId { get; init; } = "";
    public string Status { get; init; } = "";
    public string AudioKey { get; init; } = "";
    public string? TranscriptKey { get; init; }
    public string? Category { get; init; }
    public string? Priority { get; init; }
    public string? TicketId { get; init; }
    public string? FailureReason { get; init; }
    public DateTime? Deadline { get; init; }
    public DateTime CreatedAt { get; init; }
    public DateTime UpdatedAt { get; init; }
}
