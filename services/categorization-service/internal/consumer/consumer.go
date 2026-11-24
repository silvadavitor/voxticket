// Package consumer implementa o consumidor idempotente (R1): processed_messages, efeito e outbox numa
// transação, ACK só depois do COMMIT. Payload inválido vai para a DLQ; erro de infraestrutura é retry.
package consumer

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"github.com/silvadavitor/voxticket/services/categorization-service/internal/broker"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/db"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/envelope"
)

// Handler aplica o efeito de um tipo de evento DENTRO da transação do consumidor.
type Handler func(ctx context.Context, tx pgx.Tx, env envelope.Envelope) error

type Consumer struct {
	DB        *db.DB
	Broker    *broker.Broker
	Validator *envelope.Validator
	Queue     string
	Prefetch  int
	Handlers  map[string]Handler
	Log       *slog.Logger
}

var tracer = otel.Tracer("VoxTicket")

// Run consome para sempre; se o canal cair, espera a reconexão e volta a consumir (R6).
func (c *Consumer) Run(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-c.DB.Ready():
	}
	for ctx.Err() == nil {
		if err := c.consume(ctx); err != nil && ctx.Err() == nil {
			c.Log.Warn("consumidor reiniciando em 5s", "erro", err)
			select {
			case <-ctx.Done():
			case <-time.After(5 * time.Second):
			}
		}
	}
}

func (c *Consumer) consume(ctx context.Context) error {
	conn, err := c.Broker.Wait(ctx)
	if err != nil {
		return err
	}
	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()
	if err := ch.Qos(c.Prefetch, 0, false); err != nil {
		return err
	}
	if _, err := ch.QueueDeclarePassive(c.Queue, true, false, false, false, nil); err != nil {
		return err
	}
	deliveries, err := ch.Consume(c.Queue, "", false, false, false, false, nil)
	if err != nil {
		return err
	}
	c.Log.Info("consumindo", "fila", c.Queue)

	for {
		select {
		case <-ctx.Done():
			return nil
		case d, ok := <-deliveries:
			if !ok {
				return errors.New("canal fechado")
			}
			c.process(ctx, d)
		}
	}
}

func (c *Consumer) process(ctx context.Context, d amqp.Delivery) {
	// continua o trace de quem publicou (header traceparent)
	ctx = otel.GetTextMapPropagator().Extract(ctx, headerCarrier(d.Headers))

	env, err := c.Validator.Parse(d.Body)
	if err != nil {
		c.Log.Error("mensagem fora do contrato, nack", "erro", err, "messageId", d.MessageId)
		_ = d.Nack(false, true)
		return
	}

	ctx, span := tracer.Start(ctx, "process "+env.Type, trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithAttributes(
			attribute.String("messaging.system", "rabbitmq"),
			attribute.String("messaging.destination.name", c.Queue),
			attribute.String("messaging.message.id", env.MessageID),
			attribute.String("messaging.message.conversation_id", env.CorrelationID),
			attribute.String("app.event_type", env.Type),
		))
	defer span.End()
	log := c.Log.With("messageId", env.MessageID, "correlationId", env.CorrelationID, "type", env.Type)

	handler, ok := c.Handlers[env.Type]
	if !ok {
		log.InfoContext(ctx, "tipo sem handler neste serviço, ignorado")
		_ = d.Ack(false)
		return
	}

	delay := time.Second
	for {
		duplicate, err := c.apply(ctx, handler, env)
		switch {
		case err == nil:
			if duplicate {
				log.InfoContext(ctx, "duplicate, skipped")
			}
			_ = d.Ack(false) // só depois do COMMIT
			log.InfoContext(ctx, "mensagem processada")
			return
		case errors.Is(err, envelope.ErrInvalid):
			log.ErrorContext(ctx, "payload inválido no handler, nack", "erro", err)
			span.SetStatus(codes.Error, err.Error())
			_ = d.Nack(false, true)
			return
		case ctx.Err() != nil:
			return // desligando: sem ACK, a mensagem volta para a fila
		default:
			log.WarnContext(ctx, "infraestrutura indisponível, tentando de novo", "em", delay.String(), "erro", err)
			span.AddEvent("retry", trace.WithAttributes(attribute.String("erro", err.Error())))
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}
			delay = min(delay*2, 30*time.Second)
		}
	}
}

// apply: processed_messages + efeito + outbox numa transação só.
func (c *Consumer) apply(ctx context.Context, handler Handler, env envelope.Envelope) (duplicate bool, err error) {
	tx, err := c.DB.Pool().Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	tag, err := tx.Exec(ctx, `INSERT INTO processed_messages (message_id) VALUES ($1) ON CONFLICT DO NOTHING`, env.MessageID)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() == 0 {
		return true, tx.Commit(ctx)
	}
	if err := handler(ctx, tx, env); err != nil {
		return false, err
	}
	return false, tx.Commit(ctx)
}

// headerCarrier adapta os headers AMQP para o propagador W3C do OpenTelemetry.
type headerCarrier amqp.Table

func (h headerCarrier) Get(key string) string {
	if v, ok := h[key].(string); ok {
		return v
	}
	if v, ok := h[key].([]byte); ok {
		return string(v)
	}
	return ""
}

func (h headerCarrier) Set(key, value string) { h[key] = value }

func (h headerCarrier) Keys() []string {
	keys := make([]string, 0, len(h))
	for k := range h {
		keys = append(keys, k)
	}
	return keys
}
