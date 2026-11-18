package classifier

import "testing"

func TestCategoriaEPrioridade(t *testing.T) {
	casos := []struct{ texto, categoria, prioridade string }{
		{"Fui cobrado duas vezes no boleto deste mês", "FINANCEIRO", "HIGH"},
		{"O sistema está fora do ar, é urgente!", "TECNICO", "CRITICAL"},
		{"Meu pedido está atrasado e o rastreio não atualiza", "ENTREGA", "HIGH"},
		{"Quero cancelar o meu plano", "CANCELAMENTO", "MEDIUM"},
		{"Tenho uma dúvida sobre o preço do plano", "COMERCIAL", "LOW"},
		{"Bom dia, tudo bem?", "OUTROS", "MEDIUM"},
	}
	for _, c := range casos {
		r := Classify(c.texto)
		if r.Category != c.categoria || r.Priority != c.prioridade {
			t.Errorf("%q: obtido %s/%s, esperado %s/%s", c.texto, r.Category, r.Priority, c.categoria, c.prioridade)
		}
	}
}

func TestAcentosEMaiusculasNaoImportam(t *testing.T) {
	a, b := Classify("COBRANÇA indevida"), Classify("cobranca indevida")
	if a.Category != "FINANCEIRO" || a != b {
		t.Errorf("normalização falhou: %+v x %+v", a, b)
	}
}

func TestConfiancaEntre0e1(t *testing.T) {
	for _, txt := range []string{"boleto erro entrega", "", "pagamento pagamento fatura"} {
		if c := Classify(txt).Confidence; c < 0 || c > 1 {
			t.Errorf("%q: confiança %v fora de [0,1]", txt, c)
		}
	}
}
