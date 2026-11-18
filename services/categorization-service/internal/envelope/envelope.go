// Package envelope define o envelope comum a todas as mensagens e valida cada uma contra os
// JSON Schemas de contracts/ (embutidos no binário).
package envelope

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

//go:embed contracts/*.json
var contracts embed.FS

const baseURL = "https://voxticket.local/schemas/"

// ErrInvalid marca mensagem fora do contrato: vai para a DLQ após x-delivery-limit tentativas.
var ErrInvalid = errors.New("mensagem fora do contrato")

// Invalid cria um erro de contrato (envolve ErrInvalid).
func Invalid(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, args...))
}

type Envelope struct {
	MessageID     string          `json:"messageId"`
	CorrelationID string          `json:"correlationId"`
	Type          string          `json:"type"`
	Version       int             `json:"version"`
	OccurredAt    string          `json:"occurredAt"`
	Payload       json.RawMessage `json:"payload"`
}

type Validator struct {
	envelope *jsonschema.Schema
	events   map[string]*jsonschema.Schema // "Tipo.vN.schema.json" → schema
}

// NewValidator compila todos os schemas embutidos. format (uuid, date-time) é verificado:
// por padrão o JSON Schema só anota format, não valida.
func NewValidator() (*Validator, error) {
	c := jsonschema.NewCompiler()
	c.AssertFormat()

	files, err := fs.Glob(contracts, "contracts/*.json")
	if err != nil {
		return nil, err
	}
	for _, f := range files {
		raw, _ := contracts.ReadFile(f)
		doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		if err := c.AddResource(baseURL+path.Base(f), doc); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
	}

	v := &Validator{events: map[string]*jsonschema.Schema{}}
	for _, f := range files {
		name := path.Base(f)
		sch, err := c.Compile(baseURL + name)
		if err != nil {
			return nil, fmt.Errorf("compilar %s: %w", name, err)
		}
		if name == "envelope.schema.json" {
			v.envelope = sch
		} else {
			v.events[name] = sch
		}
	}
	return v, nil
}

func (v *Validator) schemaFor(typ string, version int) *jsonschema.Schema {
	if s, ok := v.events[fmt.Sprintf("%s.v%d.schema.json", typ, version)]; ok {
		return s
	}
	return v.envelope // tipo que este serviço não conhece: valida só o envelope
}

func validate(s *jsonschema.Schema, raw []byte) error {
	inst, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
	if err != nil {
		return Invalid("JSON inválido: %v", err)
	}
	if err := s.Validate(inst); err != nil {
		msg := strings.ReplaceAll(err.Error(), "\n", "; ")
		if len(msg) > 300 {
			msg = msg[:300] + "…"
		}
		return Invalid("%s", msg)
	}
	return nil
}

// Parse valida o corpo contra o contrato do tipo e decodifica o envelope.
func (v *Validator) Parse(body []byte) (Envelope, error) {
	var head struct {
		Type    string `json:"type"`
		Version int    `json:"version"`
	}
	if err := json.Unmarshal(body, &head); err != nil {
		return Envelope{}, Invalid("envelope ilegível: %v", err)
	}
	if err := validate(v.schemaFor(head.Type, head.Version), body); err != nil {
		return Envelope{}, err
	}
	var env Envelope
	if err := json.Unmarshal(body, &env); err != nil {
		return Envelope{}, Invalid("envelope: %v", err)
	}
	return env, nil
}

// New cria um envelope novo (para o outbox) e garante que ele respeita o contrato.
func (v *Validator) New(typ, correlationID string, payload any) (Envelope, []byte, error) {
	p, err := json.Marshal(payload)
	if err != nil {
		return Envelope{}, nil, err
	}
	env := Envelope{
		MessageID:     uuid.NewString(),
		CorrelationID: correlationID,
		Type:          typ,
		Version:       1,
		OccurredAt:    time.Now().UTC().Format(time.RFC3339Nano),
		Payload:       p,
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return Envelope{}, nil, err
	}
	if err := validate(v.schemaFor(typ, 1), raw); err != nil {
		return Envelope{}, nil, fmt.Errorf("evento %s gerado fora do contrato: %w", typ, err)
	}
	return env, raw, nil
}
