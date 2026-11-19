package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

type fake bool

func (f fake) Up() bool { return bool(f) }

type fakeDB bool

func (f fakeDB) Up(context.Context) bool { return bool(f) }

// O /health responde 200 mesmo sem banco e sem broker (R6), mostrando o que está fora.
func TestHealthSemInfra(t *testing.T) {
	rec := httptest.NewRecorder()
	routes("categorization-service", fake(false), fakeDB(false)).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	var body map[string]string
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body["broker"] != "down" || body["db"] != "down" || body["status"] != "ok" {
		t.Fatalf("corpo inesperado: %v", body)
	}
}
