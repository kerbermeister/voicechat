BEGIN IMMEDIATE;

ALTER TABLE screen_participants ADD COLUMN peer_identity TEXT;

DROP TABLE screen_schema;

CREATE TABLE screen_schema (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    version INTEGER NOT NULL CHECK (version >= 1)
);

INSERT INTO screen_schema VALUES (1, 2);

COMMIT;
