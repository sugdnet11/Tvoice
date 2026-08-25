ALTER TABLE conversation_members
    ADD COLUMN IF NOT EXISTS last_delivered_at TIMESTAMPTZ;
