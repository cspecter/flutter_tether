// GENERATED CODE - DO NOT MODIFY BY HAND
// Core Migration: Core Features (Feed, User Preferences, Background Jobs)
// Migration version: 0000
// Generated on 2025-06-12T21:37:49.875856

const List<String> migrationSqlStatementsV0000_core_features = [
  '''-- Core Feed Item References Table (Version 0000)''',
  '''-- Generated on 2025-06-12T21:37:49.875856''',
  r'''
CREATE TABLE IF NOT EXISTS feed_item_references (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    feed_key TEXT NOT NULL,
    item_source_table TEXT NOT NULL,
    item_source_id TEXT NOT NULL,
    display_order INTEGER NOT NULL,
    CONSTRAINT uq_feed_item_uniqueness UNIQUE (feed_key, item_source_table, item_source_id),
    CONSTRAINT uq_feed_item_order UNIQUE (feed_key, display_order)
);
''',
  r'''
CREATE INDEX IF NOT EXISTS idx_feed_items_by_feed_key_and_order ON feed_item_references (feed_key, display_order);
''',
  r'''
CREATE TABLE IF NOT EXISTS user_preferences (
    preference_key TEXT PRIMARY KEY NOT NULL,
    preference_value TEXT, -- Stored as JSON string
    value_type TEXT NOT NULL CHECK(value_type IN ('text', 'integer', 'number', 'boolean', 'datetime', 'stringList', 'integerArray', 'numberArray', 'jsonObject', 'jsonArray')) -- Type hint for deserialization
);
''',
  r'''
CREATE INDEX IF NOT EXISTS idx_user_preferences_key ON user_preferences (preference_key);
''',
  '''-- Core Background Service Job Queue Table (Version 0000)''',
  '''-- Generated on 2025-06-12T21:37:49.875856''',
  r'''
CREATE TABLE IF NOT EXISTS background_service_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_key TEXT NOT NULL,                      -- Identifier for the function/task to execute
    payload TEXT,                               -- JSON string containing arguments for the job
    status TEXT NOT NULL DEFAULT 'PENDING'      -- PENDING, RUNNING, COMPLETED, FAILED
        CHECK(status IN ('PENDING', 'RUNNING', 'COMPLETED', 'FAILED')),
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,    -- Max number of retries
    last_attempt_at TEXT,                       -- ISO8601 timestamp
    last_error TEXT,                            -- Store error message if failed
    priority INTEGER NOT NULL DEFAULT 0,        -- For future use (0 = normal)
    created_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW')), -- ISO8601 timestamp UTC
    updated_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW'))  -- ISO8601 timestamp UTC
);
''',
  r'''
CREATE INDEX IF NOT EXISTS idx_background_jobs_status_priority ON background_service_jobs (status, priority, created_at);
''',
  r'''
CREATE TRIGGER IF NOT EXISTS trg_background_service_jobs_updated_at
AFTER UPDATE ON background_service_jobs
FOR EACH ROW
BEGIN
    UPDATE background_service_jobs SET updated_at = STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW') WHERE id = OLD.id;
END;
''',
];
