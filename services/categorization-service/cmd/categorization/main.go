// categorization-service: consome CategorizationRequested e publica AudioCategorized.
//
// Sobe mesmo com banco ou broker fora (R6): as conexões são tentadas em background e o /health
// mostra o estado de cada dependência. `categorization -healthcheck` é usado pelo HEALTHCHECK do Docker.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"github.com/silvadavitor/voxticket/services/categorization-service/internal/awsx"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/broker"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/config"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/consumer"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/db"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/envelope"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/handler"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/outbox"
	"github.com/silvadavitor/voxticket/services/categorization-service/internal/telemetry"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		slog.Error("encerrando", "erro", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load()
	if err != nil {
		return err // configuração errada é erro de deploy, não de infraestrutura
	}
	log, shutdownTelemetry := telemetry.Setup(ctx, cfg.ServiceName)
	defer func() {
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdownTelemetry(c)
	}()

	clients, err := awsx.New(ctx, cfg.AWSRegion)
	if err != nil {
		return err
	}
	validator, err := envelope.NewValidator()
	if err != nil {
		return err
	}

	database := db.New()
	defer database.Close()
	brk := broker.New(cfg.BrokerURLWithCredentials(), cfg.ServiceName, log)
	ob := outbox.New(validator)
	categorization := &handler.Categorization{AWS: clients, Bucket: cfg.S3Bucket, Outbox: ob, Log: log}

	creds := func(ctx context.Context) (string, string, string, error) {
		if cfg.DBSecretID == "" { // modo dev, fora do compose
			return cfg.DBUser, cfg.DBPassword, cfg.DBName, nil
		}
		s, err := clients.Secret(ctx, cfg.DBSecretID)
		if err != nil {
			return "", "", "", err
		}
		return s["username"], s["password"], s["dbname"], nil
	}

	go database.Run(ctx, cfg.DBHost, cfg.DBPort, cfg.DBSSLMode, creds, log)
	go brk.Run(ctx)
	go (&consumer.Consumer{
		DB: database, Broker: brk, Validator: validator, Queue: cfg.BrokerQueue, Prefetch: cfg.BrokerPrefetch, Log: log,
		Handlers: map[string]consumer.Handler{
			"CategorizationRequested": categorization.OnCategorizationRequested,
		},
	}).Run(ctx)
	go ob.RunRelay(ctx, database, brk, cfg.BrokerExchange, log)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           routes(cfg.ServiceName, brk, database),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		c, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(c)
	}()

	log.Info("iniciado", "fila", cfg.BrokerQueue, "http", cfg.HTTPAddr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	log.Info("desligado")
	return nil
}

type dependency interface{ Up() bool }

type dbDependency interface{ Up(context.Context) bool }

func routes(service string, brk dependency, database dbDependency) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		status := func(up bool) string {
			if up {
				return "up"
			}
			return "down"
		}
		w.Header().Set("Content-Type", "application/json")
		// 200 sempre: o processo está vivo; dependência fora não derruba o serviço (R6)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"status":  "ok",
			"service": service,
			"broker":  status(brk.Up()),
			"db":      status(database.Up(r.Context())),
		})
	})
	return otelhttp.NewHandler(mux, "http",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/health" }))
}

func healthcheck() int {
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get("http://127.0.0.1:8080/health")
	if err != nil || resp.StatusCode != http.StatusOK {
		return 1
	}
	_ = resp.Body.Close()
	return 0
}
