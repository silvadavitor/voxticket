// Package config lê a configuração só de variáveis de ambiente (nada fixo no código).
package config

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
)

type Config struct {
	ServiceName string
	Environment string
	HTTPAddr    string

	BrokerURL      string
	BrokerExchange string
	BrokerQueue    string
	BrokerPrefetch int

	DBHost     string
	DBPort     int
	DBSSLMode  string
	DBSecretID string
	// alternativa para rodar fora do compose, sem Secrets Manager
	DBUser     string
	DBPassword string
	DBName     string

	// AWS_ENDPOINT_URL (MiniStack) é lido direto pelo SDK da AWS
	AWSRegion string
	S3Bucket  string
}

func env(name, def string) string {
	if v, ok := os.LookupEnv(name); ok && v != "" {
		return v
	}
	return def
}

func envInt(name string, def int) (int, error) {
	v := env(name, strconv.Itoa(def))
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s inválido (%q): %w", name, v, err)
	}
	return n, nil
}

func Load() (Config, error) {
	c := Config{
		ServiceName:    env("SERVICE_NAME", "categorization-service"),
		Environment:    env("ENVIRONMENT", "local"),
		HTTPAddr:       env("HTTP_ADDR", ":8080"),
		BrokerURL:      env("BROKER_URL", "amqp://guest:guest@localhost:5672/"),
		BrokerExchange: env("BROKER_EXCHANGE", "events"),
		BrokerQueue:    env("BROKER_QUEUE", "categorization-service.q"),
		DBHost:         env("DB_HOST", "localhost"),
		DBSSLMode:      env("DB_SSLMODE", "prefer"), // local sem TLS; RDS exige TLS e "prefer" negocia
		DBSecretID:     env("DB_SECRET_ID", ""),
		DBUser:         env("DB_USER", ""),
		DBPassword:     env("DB_PASSWORD", ""),
		DBName:         env("DB_NAME", ""),
		AWSRegion:      env("AWS_REGION", "us-east-1"),
		S3Bucket:       env("S3_BUCKET", "voxticket-local-audios"),
	}
	var err error
	if c.BrokerPrefetch, err = envInt("BROKER_PREFETCH", 10); err != nil {
		return c, err
	}
	if c.DBPort, err = envInt("DB_PORT", 5432); err != nil {
		return c, err
	}
	return c, nil
}

// BrokerURLWithCredentials aplica BROKER_USERNAME/BROKER_PASSWORD (na AWS vêm do Secrets Manager)
// sobre a BROKER_URL, que lá não carrega credencial.
func (c Config) BrokerURLWithCredentials() string {
	user := os.Getenv("BROKER_USERNAME")
	if user == "" {
		return c.BrokerURL
	}
	u, err := url.Parse(c.BrokerURL)
	if err != nil {
		return c.BrokerURL
	}
	u.User = url.UserPassword(user, os.Getenv("BROKER_PASSWORD"))
	return u.String()
}
