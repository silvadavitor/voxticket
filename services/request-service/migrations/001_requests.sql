CREATE TABLE IF NOT EXISTS processed_messages (
    message_id   uuid        PRIMARY KEY,
    processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox (
    id          bigserial   PRIMARY KEY,
    message_id  uuid        NOT NULL UNIQUE,
    type        text        NOT NULL,
    body        jsonb       NOT NULL,
    traceparent text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    sent_at     timestamptz
);
CREATE INDEX IF NOT EXISTS outbox_pending_idx ON outbox (id) WHERE sent_at IS NULL;

-- estado da saga de cada pedido
CREATE TABLE IF NOT EXISTS requests (
    id             uuid        PRIMARY KEY,
    tenant_id      text        NOT NULL,
    status         text        NOT NULL,
    audio_key      text        NOT NULL,
    transcript_key text,
    category       text,
    priority       text,
    ticket_id      text,
    failure_reason text,
    deadline       timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS requests_status_idx ON requests (status);
