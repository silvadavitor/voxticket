class DomainError(Exception):
    """Erro base de regra de negócio."""


class CreditRejectedError(DomainError):
    """Crédito indisponível para o cliente; gera ``CreditRejected``."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason
