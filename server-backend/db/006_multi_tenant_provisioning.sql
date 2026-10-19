CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(40) NOT NULL UNIQUE,
    slug VARCHAR(80) NOT NULL UNIQUE,
    name VARCHAR(120) NOT NULL,
    logo_url TEXT,
    primary_color VARCHAR(9) NOT NULL DEFAULT '#0A84FF',
    sip_host VARCHAR(255) NOT NULL,
    sip_port INTEGER NOT NULL DEFAULT 5060 CHECK (sip_port BETWEEN 1 AND 65535),
    sip_transport VARCHAR(8) NOT NULL DEFAULT 'udp'
        CHECK (sip_transport IN ('udp', 'tcp', 'tls')),
    outbound_proxy VARCHAR(255),
    auth_type VARCHAR(16) NOT NULL
        CHECK (auth_type IN ('freepbx', 'webhook', 'local')),
    auth_url TEXT,
    auth_secret_encrypted TEXT,
    partner_key_hash CHAR(64),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO tenants (
    id, code, slug, name, sip_host, sip_port, sip_transport, auth_type
) VALUES (
    '00000000-0000-0000-0000-000000000001',
    'TOJIKTELECOM',
    'tojiktelecom',
    'Tojiktelecom',
    '185.177.2.115',
    5060,
    'udp',
    'freepbx'
) ON CONFLICT (id) DO NOTHING;

ALTER TABLE users ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES tenants(id);
UPDATE users
SET tenant_id = '00000000-0000-0000-0000-000000000001'
WHERE tenant_id IS NULL;
ALTER TABLE users ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE users ALTER COLUMN tenant_id
    SET DEFAULT '00000000-0000-0000-0000-000000000001';
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_sip_number_key;
CREATE UNIQUE INDEX IF NOT EXISTS users_tenant_sip_number_idx
    ON users (tenant_id, sip_number);
CREATE INDEX IF NOT EXISTS users_tenant_active_idx
    ON users (tenant_id, is_active);

ALTER TABLE conversations
    ADD COLUMN IF NOT EXISTS tenant_id UUID REFERENCES tenants(id);
UPDATE conversations
SET tenant_id = '00000000-0000-0000-0000-000000000001'
WHERE tenant_id IS NULL;
ALTER TABLE conversations ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE conversations ALTER COLUMN tenant_id
    SET DEFAULT '00000000-0000-0000-0000-000000000001';
