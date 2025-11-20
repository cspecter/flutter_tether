import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/utils/logger.dart'; // Assuming Logger exists

class CoreMigrationGenerator {
  final SupabaseGenConfig config;
  final Logger _logger;

  // Updated to List<String>
  static List<String> getCoreFeedMigrationSqlStatements(String generationDate) {
    return [
      "-- Core Feed Item References Table (Version 0000)",
      "-- Generated on $generationDate",
      """
CREATE TABLE IF NOT EXISTS feed_item_references (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    feed_key TEXT NOT NULL,
    item_source_table TEXT NOT NULL,
    item_source_id TEXT NOT NULL,
    display_order INTEGER NOT NULL,
    CONSTRAINT uq_feed_item_uniqueness UNIQUE (feed_key, item_source_table, item_source_id),
    CONSTRAINT uq_feed_item_order UNIQUE (feed_key, display_order)
);""",
      """
CREATE INDEX IF NOT EXISTS idx_feed_items_by_feed_key_and_order ON feed_item_references (feed_key, display_order);""",
      """
CREATE TABLE IF NOT EXISTS user_preferences (
    preference_key TEXT PRIMARY KEY NOT NULL,
    preference_value TEXT, -- Stored as JSON string
    value_type TEXT NOT NULL CHECK(value_type IN ('text', 'integer', 'number', 'boolean', 'datetime', 'stringList', 'integerArray', 'numberArray', 'jsonObject', 'jsonArray')) -- Type hint for deserialization
);""",
      """
CREATE INDEX IF NOT EXISTS idx_user_preferences_key ON user_preferences (preference_key);""",

      "-- Core Background Service Job Queue Table (Version 0000)",
      "-- Generated on $generationDate",
      """
CREATE TABLE IF NOT EXISTS background_service_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_key TEXT NOT NULL,                      -- Identifier for the function/task to execute
    payload TEXT,                               -- JSON string containing arguments for the job
    status TEXT NOT NULL DEFAULT 'PENDING'      -- PENDING, RUNNING, COMPLETED, FAILED
        CHECK(status IN ('PENDING', 'RUNNING', 'COMPLETED', 'FAILED')),
    message TEXT,                               -- Message to the front end.
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,    -- Max number of retries
    last_attempt_at TEXT,                       -- ISO8601 timestamp
    last_error TEXT,                            -- Store error message if failed
    priority INTEGER NOT NULL DEFAULT 0,        -- For future use (0 = normal)
    created_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW')), -- ISO8601 timestamp UTC
    updated_at TEXT NOT NULL DEFAULT (STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW'))  -- ISO8601 timestamp UTC
);""",
      """
CREATE INDEX IF NOT EXISTS idx_background_jobs_status_priority ON background_service_jobs (status, priority, created_at);""",
      """
CREATE TRIGGER IF NOT EXISTS trg_background_service_jobs_updated_at
AFTER UPDATE ON background_service_jobs
FOR EACH ROW
BEGIN
    UPDATE background_service_jobs SET updated_at = STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW') WHERE id = OLD.id;
END;""",
    ];
  }

  CoreMigrationGenerator({required this.config, Logger? logger})
    : _logger = logger ?? Logger('CoreMigrationGenerator');

  Future<void> generate() async {
    if (!config.generateSqliteMigrations) {
      _logger.info(
        'SQLite migration generation is disabled. Skipping core feed migration.',
      );
      return;
    }

    final outputDir = p.join(
      config.outputDirectory,
      config.sqliteMigrationsSubDir,
    );
    const String migrationVersionPadded = "0000";
    const String coreFeatureName =
        "core_features"; // Renamed for clarity as it includes more than just feed
    final String fileName =
        'migration_v${migrationVersionPadded}_$coreFeatureName.dart';
    final String filePath = p.join(outputDir, fileName);
    // Adjusted variable name for clarity
    final String variableName =
        'migrationSqlStatementsV${migrationVersionPadded}_$coreFeatureName';

    final String generationDate = DateTime.now().toIso8601String();
    final List<String> sqlStatements = getCoreFeedMigrationSqlStatements(
      generationDate,
    );

    // Build the Dart list string content
    final StringBuffer listContentBuffer = StringBuffer();
    for (final statement in sqlStatements) {
      // Comments don't need to be raw strings, but SQL statements do for safety
      if (statement.trim().startsWith('--')) {
        listContentBuffer.writeln("  '''$statement''',");
      } else {
        listContentBuffer.writeln("  r'''\n$statement\n''',");
      }
    }

    final String dartContent = '''
// GENERATED CODE - DO NOT MODIFY BY HAND
// Core Migration: Core Features (Feed, User Preferences, Background Jobs)
// Migration version: $migrationVersionPadded
// Generated on $generationDate

const List<String> $variableName = [
${listContentBuffer.toString().trimRight()}
];
''';

    try {
      final file = File(filePath);
      await file.parent.create(recursive: true); // Ensure directory exists
      await file.writeAsString(dartContent);
      _logger.info('Generated core migration: $filePath');
    } catch (e) {
      _logger.severe('Error writing core migration file $filePath: $e');
    }
  }
}
