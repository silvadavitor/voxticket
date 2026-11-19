CREATE TABLE IF NOT EXISTS transcriptions (
    request_id     uuid        PRIMARY KEY,
    tenant_id      text,
    status         text        NOT NULL CHECK (status IN ('TRANSCRIBED', 'FAILED', 'DISCARDED')),
    transcript_key text,
    attempts       integer     NOT NULL DEFAULT 0,
    failure_reason text,
    processed_by   text,        -- hostname da réplica (F8)
    duration_ms    integer,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
