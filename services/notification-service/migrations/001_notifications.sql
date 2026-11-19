CREATE TABLE IF NOT EXISTS processed_messages (
    message_id   uuid        PRIMARY KEY,
    processed_at timestamptz NOT NULL DEFAULT now()
);

-- e-mail simulado: uma notificação por pedido e tipo
CREATE TABLE IF NOT EXISTS notifications (
    id         bigserial   PRIMARY KEY,
    request_id uuid        NOT NULL,
    tenant_id  text        NOT NULL,
    kind       text        NOT NULL,
    message    text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (request_id, kind)
);
