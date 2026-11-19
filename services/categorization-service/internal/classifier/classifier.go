// Package classifier classifica o texto por palavras-chave em categoria, prioridade e confiança.
//
// Simples de propósito: a nota do trabalho está na arquitetura. Para trocar por um modelo, basta
// manter a assinatura de Classify.
package classifier

import (
	"math"
	"regexp"
	"strings"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"
)

type Result struct {
	Category   string  `json:"category"`
	Priority   string  `json:"priority"`
	Confidence float64 `json:"confidence"`
}

type rule struct {
	name  string
	words []*regexp.Regexp
}

func compile(name string, words ...string) rule {
	r := rule{name: name}
	for _, w := range words {
		r.words = append(r.words, regexp.MustCompile(`\b`+regexp.QuoteMeta(w)+`\b`))
	}
	return r
}

// ordem importa só no empate (vence a primeira)
var categories = []rule{
	compile("FINANCEIRO", "boleto", "fatura", "cobranca", "cobrado", "pagamento", "pagar", "reembolso", "estorno", "nota fiscal", "cartao"),
	compile("TECNICO", "erro", "bug", "sistema", "travou", "travando", "lento", "senha", "login", "acesso", "aplicativo", "app", "site", "fora do ar"),
	compile("ENTREGA", "entrega", "entregue", "pedido", "atraso", "atrasado", "rastreio", "rastreamento", "frete", "transportadora"),
	compile("CANCELAMENTO", "cancelar", "cancelamento", "desistir", "encerrar", "rescindir"),
	compile("COMERCIAL", "plano", "preco", "orcamento", "proposta", "contratar", "upgrade", "desconto"),
}

// a primeira regra que casar define a prioridade; sem casar, MEDIUM
var priorities = []rule{
	compile("CRITICAL", "urgente", "parado", "fora do ar", "nao funciona", "prejuizo", "emergencia"),
	compile("HIGH", "erro", "nao consigo", "atraso", "atrasado", "cobrado duas vezes", "bloqueado"),
	compile("LOW", "duvida", "informacao", "sugestao", "elogio", "curiosidade"),
}

var spaces = regexp.MustCompile(`\s+`)

// normalize: minúsculas, sem acento, espaços colapsados.
func normalize(text string) string {
	t := transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)
	out, _, err := transform.String(t, strings.ToLower(text))
	if err != nil {
		out = strings.ToLower(text)
	}
	return spaces.ReplaceAllString(out, " ")
}

func count(text string, r rule) int {
	n := 0
	for _, w := range r.words {
		n += len(w.FindAllStringIndex(text, -1))
	}
	return n
}

func Classify(text string) Result {
	t := normalize(text)

	best, bestScore, total := "OUTROS", 0, 0
	for _, c := range categories {
		s := count(t, c)
		total += s
		if s > bestScore {
			best, bestScore = c.name, s
		}
	}
	confidence := 0.0
	if total > 0 {
		confidence = math.Round(float64(bestScore)/float64(total)*1000) / 1000
	}

	priority := "MEDIUM"
	for _, p := range priorities {
		if count(t, p) > 0 {
			priority = p.name
			break
		}
	}
	return Result{Category: best, Priority: priority, Confidence: confidence}
}
