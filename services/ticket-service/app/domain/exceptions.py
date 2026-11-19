class DomainError(Exception):
    """Erro base de regra de negócio."""


class TicketRejectedError(DomainError):
    """O chamado não pode ser aberto; gera ``TicketRejected``."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason
