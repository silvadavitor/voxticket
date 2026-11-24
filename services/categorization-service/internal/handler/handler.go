// Package handler tem a regra de negócio do serviço. Roda DENTRO da transação do consumidor (R1).
package handler

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"

	"github.com/jackc/pgx/v5"

	"github.com/silvadavitor/voxticket/services/categorization-service/internal/awsx"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/classifier"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/envelope"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/outbox"
)

type Categorization struct {
	AWS    *awsx.Clients
	Bucket string
	Outbox *outbox.Outbox
	Log    *slog.Logger
}

// Transcript é o formato de transcripts/{requestId}.json, escrito pelo transcription-worker.
type Transcript struct {
	RequestID string  `json:"requestId"`
	Text      *string `json:"text"`
}

// OnCategorizationRequested: lê a transcrição no S3 → classifica → publica AudioCategorized.
func (h *Categorization) OnCategorizationRequested(ctx context.Context, tx pgx.Tx, env envelope.Envelope) error {
	var p struct {
		RequestID     string `json:"requestId"`
		TranscriptKey string `json:"transcriptKey"`
	}
	if err := json.Unmarshal(env.Payload, &p); err != nil {
		return envelope.Invalid("payload: %v", err)
	}

	var t Transcript
	if err := h.AWS.GetJSON(ctx, h.Bucket, p.TranscriptKey, &t); err != nil {
		if errors.Is(err, awsx.ErrNotFound) {
			return envelope.Invalid("transcrição %s não existe", p.TranscriptKey)
		}
		return err // erro de infraestrutura → retry no consumidor
	}
	if t.Text == nil {
		return envelope.Invalid("transcrição %s sem campo text", p.TranscriptKey)
	}

	r := classifier.Classify(*t.Text)

	// efeito idempotente por request_id (mesmo se vier outra mensagem com messageId diferente)
	tag, err := tx.Exec(ctx,
		`INSERT INTO categorizations (request_id, category, priority, confidence)
		 VALUES ($1, $2, $3, $4) ON CONFLICT (request_id) DO NOTHING`,
		p.RequestID, r.Category, r.Priority, r.Confidence)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		h.Log.InfoContext(ctx, "pedido já categorizado, nada a publicar", "correlationId", env.CorrelationID)
		return nil
	}

	if err := h.Outbox.Enqueue(ctx, tx, "AudioCategorized", env.CorrelationID, map[string]any{
		"requestId":  p.RequestID,
		"category":   r.Category,
		"priority":   r.Priority,
		"confidence": r.Confidence,
	}); err != nil {
		return err
	}
	h.Log.InfoContext(ctx, "categorizado", "correlationId", env.CorrelationID,
		"category", r.Category, "priority", r.Priority, "confidence", r.Confidence)
	return nil
}
