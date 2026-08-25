CREATE TABLE IF NOT EXISTS conferences (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organizer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  livekit_room VARCHAR(160) NOT NULL UNIQUE,
  title VARCHAR(120) NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'ended')),
  allow_guests BOOLEAN NOT NULL DEFAULT TRUE,
  locked BOOLEAN NOT NULL DEFAULT FALSE,
  invite_token VARCHAR(100) UNIQUE,
  invite_token_hash CHAR(64) NOT NULL UNIQUE,
  invite_expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at TIMESTAMPTZ
);

ALTER TABLE conferences ADD COLUMN IF NOT EXISTS invite_token VARCHAR(100);
ALTER TABLE conferences ALTER COLUMN invite_expires_at DROP NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS conferences_invite_token_idx
  ON conferences (invite_token) WHERE invite_token IS NOT NULL;

CREATE TABLE IF NOT EXISTS conference_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conference_id UUID NOT NULL REFERENCES conferences(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  identity VARCHAR(180) NOT NULL,
  display_name VARCHAR(120) NOT NULL,
  role VARCHAR(16) NOT NULL CHECK (role IN ('organizer', 'participant', 'guest')),
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  removed_at TIMESTAMPTZ,
  UNIQUE (conference_id, identity)
);

CREATE INDEX IF NOT EXISTS conference_members_conference_idx
  ON conference_members (conference_id, removed_at);
