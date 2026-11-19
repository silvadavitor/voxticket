// Package awsx cria os clientes AWS. Com AWS_ENDPOINT_URL (lido pelo próprio SDK) eles falam com o
// MiniStack; sem ele, com a AWS real. O mesmo binário roda nos dois ambientes.
package awsx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/smithy-go"
	"go.opentelemetry.io/contrib/instrumentation/github.com/aws/aws-sdk-go-v2/otelaws"
)

// ErrNotFound indica que o objeto não existe no S3 (erro de dado, não de infraestrutura).
var ErrNotFound = errors.New("objeto não encontrado")

type Clients struct {
	S3      *s3.Client
	Secrets *secretsmanager.Client
}

func New(ctx context.Context, region string) (*Clients, error) {
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("config AWS: %w", err)
	}
	otelaws.AppendMiddlewares(&cfg.APIOptions) // cada chamada ao S3/Secrets vira span no trace
	pathStyle := os.Getenv("AWS_ENDPOINT_URL") != ""
	return &Clients{
		S3:      s3.NewFromConfig(cfg, func(o *s3.Options) { o.UsePathStyle = pathStyle }),
		Secrets: secretsmanager.NewFromConfig(cfg),
	}, nil
}

// Secret lê um segredo JSON ({"username":..., "password":..., "dbname":...}).
func (c *Clients) Secret(ctx context.Context, id string) (map[string]string, error) {
	out, err := c.Secrets.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: aws.String(id)})
	if err != nil {
		return nil, fmt.Errorf("segredo %s: %w", id, err)
	}
	var m map[string]string
	if err := json.Unmarshal([]byte(aws.ToString(out.SecretString)), &m); err != nil {
		return nil, fmt.Errorf("segredo %s não é JSON: %w", id, err)
	}
	return m, nil
}

// GetJSON baixa um objeto do S3 e decodifica o JSON em v.
func (c *Clients) GetJSON(ctx context.Context, bucket, key string, v any) error {
	out, err := c.S3.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		var apiErr smithy.APIError
		if errors.As(err, &apiErr) && (apiErr.ErrorCode() == "NoSuchKey" || apiErr.ErrorCode() == "NotFound") {
			return fmt.Errorf("%w: s3://%s/%s", ErrNotFound, bucket, key)
		}
		return fmt.Errorf("s3 get %s: %w", key, err)
	}
	defer out.Body.Close()
	if err := json.NewDecoder(out.Body).Decode(v); err != nil {
		return fmt.Errorf("s3 %s não é JSON: %w", key, err)
	}
	return nil
}
