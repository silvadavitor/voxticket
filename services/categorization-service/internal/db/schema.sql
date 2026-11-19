-- Migração idempotente, aplicada no start (dentro de transação com advisory lock).

CREATE TABLE IF NOT EXISTS categorizations (
    request_id  uuid PRIMARY KEY,           -- uma categorização por pedido (idempotência do efeito)
    category    text NOT NULL,
    priority    text NOT NULL,
    confidence  numeric(4, 3) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- R1: mensagens já processadas (mesma transação do efeito)
CREATE TABLE IF NOT EXISTS processed_messages (
    message_id   uuid PRIMARY KEY,
    processed_at timestamptz NOT NULL DEFAULT now()
);

-- Outbox: eventos a publicar, gravados na mesma transação do efeito
CREATE TABLE IF NOT EXISTS outbox (
    id             uuid PRIMARY KEY,
    type           text NOT NULL,
    correlation_id uuid NOT NULL,
    envelope       jsonb NOT NULL,
    traceparent    text,                     -- W3C do span que gerou o evento (o relay propaga no header)
    created_at     timestamptz NOT NULL DEFAULT now(),
    sent_at        timestamptz
);
ALTER TABLE outbox ADD COLUMN IF NOT EXISTS traceparent text;
CREATE INDEX IF NOT EXISTS outbox_pending ON outbox (created_at) WHERE sent_at IS NULL;
