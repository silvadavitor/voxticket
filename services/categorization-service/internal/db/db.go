// Package db cuida do banco próprio do serviço: credenciais, pool e migração no start.
// Nunca derruba o processo se o banco estiver fora (R6): tenta de novo com backoff.
package db

import (
	"context"
	_ "embed"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schema string

// Credentials devolve usuário, senha e database (do Secrets Manager ou do ambiente).
type Credentials func(ctx context.Context) (user, password, dbname string, err error)

type DB struct {
	pool  atomic.Pointer[pgxpool.Pool]
	ready chan struct{}
	once  sync.Once
}

func New() *DB { return &DB{ready: make(chan struct{})} }

// Ready fecha quando o banco está conectado e migrado.
func (d *DB) Ready() <-chan struct{} { return d.ready }

func (d *DB) Pool() *pgxpool.Pool { return d.pool.Load() }

func (d *DB) Up(ctx context.Context) bool {
	p := d.pool.Load()
	if p == nil {
		return false
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return p.Ping(ctx) == nil
}

func (d *DB) Close() {
	if p := d.pool.Load(); p != nil {
		p.Close()
	}
}

// Run conecta e migra, repetindo com backoff até conseguir (ou o contexto acabar).
func (d *DB) Run(ctx context.Context, host string, port int, sslmode string, creds Credentials, log *slog.Logger) {
	delay := time.Second
	for d.pool.Load() == nil {
		pool, err := d.connect(ctx, host, port, sslmode, creds)
		if err == nil {
			d.pool.Store(pool)
			d.once.Do(func() { close(d.ready) })
			log.Info("banco pronto")
			return
		}
		log.Warn("banco indisponível, tentando de novo", "em", delay.String(), "erro", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		delay = min(delay*2, 30*time.Second)
	}
}

func (d *DB) connect(ctx context.Context, host string, port int, sslmode string, creds Credentials) (*pgxpool.Pool, error) {
	user, password, dbname, err := creds(ctx)
	if err != nil {
		return nil, err
	}
	dsn := (&url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(user, password),
		Host:     net.JoinHostPort(host, strconv.Itoa(port)),
		Path:     "/" + dbname,
		RawQuery: "sslmode=" + url.QueryEscape(sslmode) + "&pool_max_conns=5",
	}).String()

	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("dsn: %w", err)
	}
	cfg.ConnConfig.Tracer = otelpgx.NewTracer() // queries viram spans no trace

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

func migrate(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // após Commit é no-op
	// várias réplicas subindo juntas não brigam pela migração
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext('categorization-schema'))"); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, schema); err != nil {
		return fmt.Errorf("migração: %w", err)
	}
	return tx.Commit(ctx)
}
