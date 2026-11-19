-- listagem da API (GET /audios): mais novos primeiro, com ou sem filtro por cliente
CREATE INDEX IF NOT EXISTS requests_created_at ON requests (created_at DESC);
CREATE INDEX IF NOT EXISTS requests_tenant_created_at ON requests (tenant_id, created_at DESC);
