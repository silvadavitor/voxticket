package envelope

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"
)

func msg(t *testing.T, override map[string]any) []byte {
	t.Helper()
	req := uuid.NewString()
	env := map[string]any{
		"messageId":     uuid.NewString(),
		"correlationId": req,
		"type":          "CategorizationRequested",
		"version":       1,
		"occurredAt":    "2026-11-20T14:00:00Z",
		"payload":       map[string]any{"requestId": req, "tenantId": "tenant-demo", "transcriptKey": "transcripts/" + req + ".json"},
	}
	for k, v := range override {
		env[k] = v
	}
	b, _ := json.Marshal(env)
	return b
}

func validator(t *testing.T) *Validator {
	t.Helper()
	v, err := NewValidator()
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestMensagemValida(t *testing.T) {
	env, err := validator(t).Parse(msg(t, nil))
	if err != nil || env.Type != "CategorizationRequested" {
		t.Fatalf("esperava válida: %v", err)
	}
}

func TestMensagemInvalidaVaiParaDLQ(t *testing.T) {
	v := validator(t)
	casos := map[string][]byte{
		"não é JSON":           []byte("isso nao e json"),
		"não é objeto":         []byte("[1,2,3]"),
		"payload fora (F4)":    msg(t, map[string]any{"payload": map[string]any{"requestId": "nao-e-uuid"}}),
		"messageId não é uuid": msg(t, map[string]any{"messageId": "123"}),
		"occurredAt inválido":  msg(t, map[string]any{"occurredAt": "ontem"}),
		"faltam campos":        []byte(`{"type":"CategorizationRequested","version":1}`),
	}
	for nome, body := range casos {
		if _, err := v.Parse(body); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: esperava ErrInvalid, obtido %v", nome, err)
		}
	}
}

func TestTipoDesconhecidoValidaSoOEnvelope(t *testing.T) {
	if _, err := validator(t).Parse(msg(t, map[string]any{"type": "AudioReceived", "payload": map[string]any{"x": 1}})); err != nil {
		t.Fatal(err)
	}
}

func TestEventoPublicadoRespeitaOContrato(t *testing.T) {
	req := uuid.NewString()
	v := validator(t)
	if _, _, err := v.New("AudioCategorized", req, map[string]any{"requestId": req, "category": "TECNICO", "priority": "HIGH", "confidence": 0.8}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := v.New("AudioCategorized", req, map[string]any{"requestId": req, "category": "TECNICO", "priority": "ALTISSIMA"}); err == nil {
		t.Fatal("prioridade fora do enum deveria falhar")
	}
}
