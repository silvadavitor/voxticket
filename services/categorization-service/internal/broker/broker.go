// Package broker mantém a conexão com o RabbitMQ viva (R6).
//
// O amqp091-go não reconecta sozinho: este pacote escuta NotifyClose e refaz a conexão com
// backoff, sem nunca derrubar o processo. Consumidor e relay pedem a conexão atual com Wait.
package broker

import (
	"context"
	"log/slog"
	"sync"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

type Broker struct {
	url  string
	name string
	log  *slog.Logger

	mu        sync.RWMutex
	conn      *amqp.Connection
	connected chan struct{} // fechado enquanto há conexão; recriado a cada queda
}

func New(url, connectionName string, log *slog.Logger) *Broker {
	return &Broker{url: url, name: connectionName, log: log, connected: make(chan struct{})}
}

// Up informa se há conexão aberta agora (para o /health).
func (b *Broker) Up() bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.conn != nil && !b.conn.IsClosed()
}

// Wait bloqueia até existir conexão e a devolve.
func (b *Broker) Wait(ctx context.Context) (*amqp.Connection, error) {
	for {
		b.mu.RLock()
		conn, ch := b.conn, b.connected
		b.mu.RUnlock()
		if conn != nil && !conn.IsClosed() {
			return conn, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ch:
			// canal "conectado" ainda fechado de uma conexão que acabou de cair:
			// espera o Run trocar o estado em vez de girar em falso
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(100 * time.Millisecond):
			}
		}
	}
}

// Run conecta e reconecta para sempre (até o contexto acabar).
func (b *Broker) Run(ctx context.Context) {
	delay := time.Second
	for ctx.Err() == nil {
		conn, err := amqp.DialConfig(b.url, amqp.Config{
			Properties: amqp.Table{"connection_name": b.name},
			Heartbeat:  10 * time.Second,
		})
		if err != nil {
			b.log.Warn("broker indisponível, tentando de novo", "em", delay.String(), "erro", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}
			delay = min(delay*2, 30*time.Second)
			continue
		}

		delay = time.Second
		closed := conn.NotifyClose(make(chan *amqp.Error, 1))
		b.mu.Lock()
		b.conn = conn
		close(b.connected)
		b.mu.Unlock()
		b.log.Info("broker conectado")

		select {
		case <-ctx.Done():
			_ = conn.Close()
			return
		case reason := <-closed:
			b.log.Warn("conexão com o broker caiu, reconectando", "motivo", reason)
			b.mu.Lock()
			b.conn = nil
			b.connected = make(chan struct{})
			b.mu.Unlock()
		}
	}
}
