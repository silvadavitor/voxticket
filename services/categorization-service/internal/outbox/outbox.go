// Package outbox grava eventos na mesma transação do efeito e um relay publica depois, com
// confirmação do broker. Se o broker cair, os eventos esperam no banco (F6) e nada se perde.
package outbox

import (
	"context"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"

	"github.com/silvadavitor/voxticket/services/categorization-service/internal/broker"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/db"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/envelope"
)

type Outbox struct {
	validator *envelope.Validator
	pending   atomic.Int64
}

func New(v *envelope.Validator) *Outbox {
	o := &Outbox{validator: v}
	_, _ = otel.Meter("VoxTicket").Int64ObservableGauge(
		"voxticket.outbox.pending",
		metric.WithDescription("Eventos no outbox ainda não publicados"),
		metric.WithInt64Callback(func(_ context.Context, obs metric.Int64Observer) error {
			obs.Observe(o.pending.Load())
			return nil
		}),
	)
	return o
}

// Enqueue grava o evento no outbox. Chame DENTRO da transação do efeito (padrão R1).
func (o *Outbox) Enqueue(ctx context.Context, tx pgx.Tx, typ, correlationID string, payload any) error {
	env, raw, err := o.validator.New(typ, correlationID, payload)
	if err != nil {
		return err
	}
	// o publish acontece depois, em outra goroutine: guarda o contexto do trace para continuar dele
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	var traceparent *string
	if tp := carrier.Get("traceparent"); tp != "" {
		traceparent = &tp
	}
	_, err = tx.Exec(ctx,
		`INSERT INTO outbox (id, type, correlation_id, envelope, traceparent) VALUES ($1, $2, $3, $4, $5)`,
		env.MessageID, typ, correlationID, raw, traceparent)
	return err
}

type row struct {
	id, typ, correlationID string
	envelope               []byte
	traceparent            *string
}

// RunRelay publica o que está pendente, para sempre. Erro de infraestrutura = espera e tenta de novo.
func (o *Outbox) RunRelay(ctx context.Context, database *db.DB, brk *broker.Broker, exchange string, log *slog.Logger) {
	select {
	case <-ctx.Done():
		return
	case <-database.Ready():
	}

	var ch *amqp.Channel
	for ctx.Err() == nil {
		if ch == nil || ch.IsClosed() {
			conn, err := brk.Wait(ctx)
			if err != nil {
				return
			}
			if ch, err = conn.Channel(); err == nil {
				err = ch.Confirm(false) // publisher confirms: só marca sent_at depois do ack do broker
			}
			if err != nil {
				log.Warn("relay do outbox sem canal, tentando de novo", "erro", err)
				ch = nil
				sleep(ctx, 5*time.Second)
				continue
			}
		}

		if err := o.relayBatch(ctx, database, ch, exchange, log); err != nil {
			log.Warn("relay do outbox aguardando infraestrutura", "erro", err)
			if ch != nil {
				_ = ch.Close()
			}
			ch = nil
			sleep(ctx, 5*time.Second)
			continue
		}
		sleep(ctx, time.Second)
	}
}

func (o *Outbox) relayBatch(ctx context.Context, database *db.DB, ch *amqp.Channel, exchange string, log *slog.Logger) error {
	tx, err := database.Pool().Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	rows, err := tx.Query(ctx, `SELECT id::text, type, correlation_id::text, envelope::text, traceparent
	                            FROM outbox WHERE sent_at IS NULL ORDER BY created_at LIMIT 50
	                            FOR UPDATE SKIP LOCKED`)
	if err != nil {
		return err
	}
	var batch []row
	for rows.Next() {
		var r row
		var env string
		if err := rows.Scan(&r.id, &r.typ, &r.correlationID, &env, &r.traceparent); err != nil {
			rows.Close()
			return err
		}
		r.envelope = []byte(env)
		batch = append(batch, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, r := range batch {
		headers := amqp.Table{}
		if r.traceparent != nil {
			headers["traceparent"] = *r.traceparent
		}
		confirm, err := ch.PublishWithDeferredConfirmWithContext(ctx, exchange, r.typ, false, false, amqp.Publishing{
			ContentType:   "application/json",
			DeliveryMode:  amqp.Persistent,
			MessageId:     r.id,
			CorrelationId: r.correlationID,
			Type:          r.typ,
			Timestamp:     time.Now(),
			Headers:       headers,
			Body:          r.envelope,
		})
		if err != nil {
			return fmt.Errorf("publish %s: %w", r.id, err)
		}
		acked, err := confirm.WaitContext(ctx)
		if err != nil || !acked {
			return fmt.Errorf("broker não confirmou %s: %v", r.id, err)
		}
		if _, err := tx.Exec(ctx, `UPDATE outbox SET sent_at = now() WHERE id = $1`, r.id); err != nil {
			return err
		}
		lctx := ctx
		if r.traceparent != nil {
			lctx = otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier{"traceparent": *r.traceparent})
		}
		log.InfoContext(lctx, "evento publicado", "type", r.typ, "correlationId", r.correlationID)
	}

	var pending int64
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM outbox WHERE sent_at IS NULL`).Scan(&pending); err == nil {
		o.pending.Store(pending)
	}
	return tx.Commit(ctx)
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
