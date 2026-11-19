-- listagem da API: mais novos primeiro, com ou sem filtro por cliente
CREATE INDEX IF NOT EXISTS tickets_created_at ON tickets (created_at DESC);
CREATE INDEX IF NOT EXISTS tickets_tenant_created_at ON tickets (tenant_id, created_at DESC);
