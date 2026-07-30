ALTER TABLE users
    ADD COLUMN IF NOT EXISTS auth_source VARCHAR(16) NOT NULL DEFAULT 'local';

CREATE INDEX IF NOT EXISTS users_auth_source_idx
    ON users (auth_source, is_active);
