CREATE TABLE IF NOT EXISTS tickets (
  ticket_id      varchar(64)  PRIMARY KEY,
  request_id     uuid         NOT NULL,
  tenant_id      varchar(255) NOT NULL,
  category       varchar(255) NOT NULL,
  priority       varchar(50),
  transcript_key text,
  status         varchar(20)  NOT NULL CHECK (status IN ('OPEN')),
  created_at     timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT tickets_request_id_unique UNIQUE (request_id)
);

CREATE TABLE IF NOT EXISTS processed_messages (
  message_id   uuid PRIMARY KEY,
  processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox (
  id             uuid PRIMARY KEY,
  type           text NOT NULL,
  correlation_id uuid NOT NULL,
  envelope       jsonb NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  sent_at        timestamptz,
  traceparent    text
);

CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;
