CREATE TABLE IF NOT EXISTS collections (
 owner text NOT NULL,
 scope text NOT NULL,
 key text NOT NULL,
 revision integer NOT NULL,
 ciphertext text NOT NULL,
 device_id text NOT NULL,
 updated timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(owner,scope,key)
);
