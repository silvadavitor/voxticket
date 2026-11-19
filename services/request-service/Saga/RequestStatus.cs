namespace RequestService.Saga;

/// <summary>Estados da saga. Caminho feliz de cima para baixo; os quatro últimos são finais alternativos.</summary>
public static class RequestStatus
{
    public const string Received = "RECEIVED";
    public const string Transcribing = "TRANSCRIBING";
    public const string Categorizing = "CATEGORIZING";
    public const string TicketRequested = "TICKET_REQUESTED";
    public const string TicketOpened = "TICKET_OPENED";

    public const string Rejected = "REJECTED";
    public const string Expired = "EXPIRED";
    public const string Compensating = "COMPENSATING";
    public const string Failed = "FAILED";
}
