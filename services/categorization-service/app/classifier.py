"""Classificação por palavras-chave: categoria, prioridade e confiança.

Simples de propósito: a nota do trabalho está na arquitetura. Para trocar por um modelo, basta manter
a assinatura de `classify`.
"""

import re
import unicodedata
from dataclasses import dataclass

CATEGORIES: dict[str, tuple[str, ...]] = {
    "FINANCEIRO": ("boleto", "fatura", "cobranca", "cobrado", "pagamento", "pagar", "reembolso", "estorno", "nota fiscal", "cartao"),
    "TECNICO": ("erro", "bug", "sistema", "travou", "travando", "lento", "senha", "login", "acesso", "aplicativo", "app", "site", "fora do ar"),
    "ENTREGA": ("entrega", "entregue", "pedido", "atraso", "atrasado", "rastreio", "rastreamento", "frete", "transportadora"),
    "CANCELAMENTO": ("cancelar", "cancelamento", "desistir", "encerrar", "rescindir"),
    "COMERCIAL": ("plano", "preco", "orcamento", "proposta", "contratar", "upgrade", "desconto"),
}

PRIORITY_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("CRITICAL", ("urgente", "parado", "fora do ar", "nao funciona", "prejuizo", "emergencia")),
    ("HIGH", ("erro", "nao consigo", "atraso", "atrasado", "cobrado duas vezes", "bloqueado")),
    ("LOW", ("duvida", "informacao", "sugestao", "elogio", "curiosidade")),
)


@dataclass(frozen=True)
class Classification:
    category: str
    priority: str
    confidence: float


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", text)


def _count(text: str, words: tuple[str, ...]) -> int:
    return sum(len(re.findall(rf"\b{re.escape(w)}\b", text)) for w in words)


def classify(text: str) -> Classification:
    normalized = _normalize(text)
    scores = {cat: _count(normalized, words) for cat, words in CATEGORIES.items()}
    total = sum(scores.values())

    if total == 0:
        category, confidence = "OUTROS", 0.0
    else:
        category = max(scores, key=lambda c: scores[c])
        confidence = round(scores[category] / total, 3)

    priority = "MEDIUM"
    for level, words in PRIORITY_RULES:
        if _count(normalized, words):
            priority = level
            break

    return Classification(category=category, priority=priority, confidence=confidence)
