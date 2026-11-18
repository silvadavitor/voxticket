import pytest

from app.classifier import classify


@pytest.mark.parametrize(
    ("texto", "categoria", "prioridade"),
    [
        ("Fui cobrado duas vezes no boleto deste mês", "FINANCEIRO", "HIGH"),
        ("O sistema está fora do ar, é urgente!", "TECNICO", "CRITICAL"),
        ("Meu pedido está atrasado e o rastreio não atualiza", "ENTREGA", "HIGH"),
        ("Quero cancelar o meu plano", "CANCELAMENTO", "MEDIUM"),
        ("Tenho uma dúvida sobre o preço do plano", "COMERCIAL", "LOW"),
        ("Bom dia, tudo bem?", "OUTROS", "MEDIUM"),
    ],
)
def test_categoria_e_prioridade(texto, categoria, prioridade):
    r = classify(texto)
    assert r.category == categoria
    assert r.priority == prioridade


def test_acentos_e_maiusculas_nao_importam():
    assert classify("COBRANÇA indevida").category == classify("cobranca indevida").category == "FINANCEIRO"


def test_confianca_entre_0_e_1():
    for texto in ("boleto erro entrega", "", "pagamento pagamento fatura"):
        assert 0.0 <= classify(texto).confidence <= 1.0
