CREATE TABLE IF NOT EXISTS tenant_quota (
  tenant_id   varchar(255) PRIMARY KEY,
  quota_limit integer      NOT NULL CHECK (quota_limit >= 0),
  used        integer      NOT NULL DEFAULT 0 CHECK (used >= 0 AND used <= quota_limit)
);

CREATE TABLE IF NOT EXISTS reservations (
  request_id     uuid         PRIMARY KEY,
  tenant_id      varchar(255) NOT NULL,
  reservation_id uuid         NOT NULL,
  status         varchar(20)  NOT NULL CHECK (status IN ('RESERVED', 'CONSUMED', 'RELEASED')),
  created_at     timestamptz  NOT NULL DEFAULT now(),
  updated_at     timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS processed_messages (
  message_id   uuid        PRIMARY KEY,
  processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox (
  id             uuid        PRIMARY KEY,
  type           text        NOT NULL,
  correlation_id uuid        NOT NULL,
  envelope       jsonb       NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  sent_at        timestamptz,
  traceparent    text
);

CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;
