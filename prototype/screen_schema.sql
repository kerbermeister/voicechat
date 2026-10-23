BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS screen_schema (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    version INTEGER NOT NULL CHECK (version = 1)
);

CREATE TABLE IF NOT EXISTS screen_bindings (
    id TEXT PRIMARY KEY,
    room_id TEXT NOT NULL,
    call_session TEXT NOT NULL,
    transport TEXT NOT NULL CHECK (transport IN ('direct', 'group')),
    state TEXT NOT NULL CHECK (state IN ('pending', 'open', 'ended')),
    created_at INTEGER NOT NULL,
    ended_at INTEGER,
    UNIQUE (room_id, call_session, transport),
    CHECK ((state = 'ended') = (ended_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS screen_participants (
    binding_id TEXT NOT NULL REFERENCES screen_bindings(id),
    identity TEXT NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    curve TEXT NOT NULL,
    ed TEXT NOT NULL,
    lease_id TEXT NOT NULL UNIQUE,
    call_lease_id TEXT,
    confirmed INTEGER NOT NULL CHECK (confirmed IN (0, 1)),
    expires INTEGER NOT NULL,
    PRIMARY KEY (binding_id, identity),
    UNIQUE (binding_id, user_id),
    UNIQUE (binding_id, identity, lease_id)
);

CREATE INDEX IF NOT EXISTS screen_participants_expiry ON screen_participants(expires);

CREATE TABLE IF NOT EXISTS screen_sessions (
    binding_id TEXT PRIMARY KEY REFERENCES screen_bindings(id),
    revision INTEGER NOT NULL DEFAULT 0 CHECK (typeof(revision) = 'integer' AND revision >= 0),
    state TEXT NOT NULL DEFAULT 'idle' CHECK (state IN ('idle', 'switching', 'active', 'unavailable', 'ended')),
    owner_identity TEXT,
    owner_lease_id TEXT,
    generation TEXT UNIQUE,
    roster_version INTEGER NOT NULL DEFAULT 0 CHECK (typeof(roster_version) = 'integer' AND roster_version >= 0),
    operation_id TEXT,
    deadline INTEGER,
    FOREIGN KEY (binding_id, owner_identity, owner_lease_id)
        REFERENCES screen_participants(binding_id, identity, lease_id),
    CHECK ((owner_identity IS NULL) = (owner_lease_id IS NULL)),
    CHECK (state != 'active' OR (owner_identity IS NOT NULL AND generation IS NOT NULL)),
    CHECK (state NOT IN ('idle', 'ended') OR (owner_identity IS NULL AND generation IS NULL)),
    CHECK ((operation_id IS NULL) = (deadline IS NULL)),
    CHECK ((state = 'switching') = (operation_id IS NOT NULL AND deadline IS NOT NULL))
);

CREATE TRIGGER IF NOT EXISTS screen_binding_terminal
BEFORE UPDATE OF state ON screen_bindings
WHEN OLD.state = 'ended' AND NEW.state != 'ended'
BEGIN
    SELECT RAISE(ABORT, 'screen_binding_ended');
END;

CREATE TRIGGER IF NOT EXISTS screen_session_terminal
BEFORE UPDATE OF state ON screen_sessions
WHEN OLD.state = 'ended' AND NEW.state != 'ended'
BEGIN
    SELECT RAISE(ABORT, 'screen_session_ended');
END;

CREATE TABLE IF NOT EXISTS screen_commands (
    binding_id TEXT NOT NULL REFERENCES screen_bindings(id),
    actor_identity TEXT NOT NULL,
    request_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('claim', 'stop', 'unbind')),
    fingerprint TEXT NOT NULL,
    expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
    status TEXT NOT NULL CHECK (status IN ('pending', 'succeeded', 'failed')),
    result_revision INTEGER,
    error_code TEXT,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (binding_id, actor_identity, request_id)
);

CREATE INDEX IF NOT EXISTS screen_commands_cleanup ON screen_commands(created_at);

CREATE TABLE IF NOT EXISTS screen_retired (
    generation TEXT PRIMARY KEY,
    binding_id TEXT NOT NULL REFERENCES screen_bindings(id),
    retired_revision INTEGER NOT NULL CHECK (retired_revision >= 0)
);

INSERT OR IGNORE INTO screen_schema VALUES (1, 1);

COMMIT;
