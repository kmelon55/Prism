CREATE TABLE IF NOT EXISTS devices (id text PRIMARY KEY, owner text NOT NULL, name text NOT NULL, platform text NOT NULL, token_hash text NOT NULL UNIQUE, revoked timestamptz);
CREATE TABLE IF NOT EXISTS records (owner text NOT NULL, key text NOT NULL, revision integer NOT NULL, ciphertext text NOT NULL, device_id text NOT NULL, updated timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(owner,key));
CREATE TABLE IF NOT EXISTS clips (owner text NOT NULL, id text NOT NULL, device_id text NOT NULL, ciphertext text NOT NULL, created timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(owner,id));
CREATE INDEX IF NOT EXISTS clips_owner_created ON clips(owner,created DESC);
