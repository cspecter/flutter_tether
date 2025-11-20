import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/utils/logger.dart';

class UserPreferencesManagerGenerator {
  final SupabaseGenConfig config;
  final Logger _logger;

  UserPreferencesManagerGenerator({required this.config, Logger? logger})
    : _logger = logger ?? Logger('UserPreferencesManagerGenerator');

  Future<void> generate() async {
    // Consider adding a specific flag in SupabaseGenConfig if needed,
    // e.g., config.generateUserPreferencesManager
    // For now, generating if this method is called.

    final managersDir = p.join(config.outputDirectory, 'managers');
    final fileName = 'user_preferences_manager.g.dart';
    final filePath = p.join(managersDir, fileName);

    final buffer = StringBuffer();

    buffer.writeln("""
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database.dart'; // Assuming database.dart is at the root of outputDirectory

/// Defines the valid types for user preferences.
enum UserPreferenceValueType {
  text,
  integer,
  number,
  boolean,
  datetime,
  stringList,
  integerArray,
  numberArray,
  jsonObject,
  jsonArray,
}

/// Utility to convert UserPreferenceValueType enum to its string representation for storage.
String userPreferenceValueTypeToString(UserPreferenceValueType type) {
  switch (type) {
    case UserPreferenceValueType.text:
      return 'text';
    case UserPreferenceValueType.integer:
      return 'integer';
    case UserPreferenceValueType.number:
      return 'number';
    case UserPreferenceValueType.boolean:
      return 'boolean';
    case UserPreferenceValueType.datetime:
      return 'datetime';
    case UserPreferenceValueType.stringList:
      return 'stringList';
    case UserPreferenceValueType.integerArray:
      return 'integerArray';
    case UserPreferenceValueType.numberArray:
      return 'numberArray';
    case UserPreferenceValueType.jsonObject:
      return 'jsonObject';
    case UserPreferenceValueType.jsonArray:
      return 'jsonArray';
  }
}

/// Utility to convert a string representation from storage back to UserPreferenceValueType enum.
UserPreferenceValueType? userPreferenceValueTypeFromString(String? typeString) {
  if (typeString == null) return null;
  switch (typeString) {
    case 'text':
      return UserPreferenceValueType.text;
    case 'integer':
      return UserPreferenceValueType.integer;
    case 'number':
      return UserPreferenceValueType.number;
    case 'boolean':
      return UserPreferenceValueType.boolean;
    case 'datetime':
      return UserPreferenceValueType.datetime;
    case 'stringList':
      return UserPreferenceValueType.stringList;
    case 'integerArray':
      return UserPreferenceValueType.integerArray;
    case 'numberArray':
      return UserPreferenceValueType.numberArray;
    case 'jsonObject':
      return UserPreferenceValueType.jsonObject;
    case 'jsonArray':
      return UserPreferenceValueType.jsonArray;
    default:
      // Optionally, log or throw an error for unknown types
      print('Warning: Unknown UserPreferenceValueType string: \$typeString');
      return null;
  }
}


/// Manages storing, retrieving, and streaming user preferences from the SQLite database.
class UserPreferencesManager {
  final SqliteDatabase db;
  static const String _tableName = 'user_preferences';

  UserPreferencesManager(this.db);

  /// Sets or updates a user preference.
  /// [key]: The unique key for the preference.
  /// [value]: The value to store. It will be JSON encoded.
  /// [valueType]: The type of the value, used as a hint for deserialization.
  Future<void> setPreference<T>(
    String key,
    T value, {
    required UserPreferenceValueType valueType,
  }) async {
    final String jsonValue = jsonEncode(value);
    final String valueTypeString = userPreferenceValueTypeToString(valueType);
    await db.execute(
      '''INSERT INTO \$_tableName (preference_key, preference_value, value_type)
         VALUES (?, ?, ?)
         ON CONFLICT(preference_key) DO UPDATE SET
           preference_value = excluded.preference_value,
           value_type = excluded.value_type;''',
      [key, jsonValue, valueTypeString],
    );
  }

  /// Retrieves a user preference and deserializes its JSON value.
  /// Returns `null` if the key is not found or if deserialization fails.
  /// [key]: The key of the preference to retrieve.
  /// [fromJson]: A function to convert the decoded JSON (dynamic) to type [T].
  Future<T?> getPreference<T>(
    String key, {
    required T Function(dynamic jsonData) fromJson,
  }) async {
    final row = await db.get(
      'SELECT preference_value FROM \$_tableName WHERE preference_key = ?',
      [key],
    );
    // If row is null, the key doesn't exist.
    if (row == null) return null; 
    final rawValue = row['preference_value'] as String?;
    if (rawValue == null) {
      try {
        // Allow fromJson to handle null if it's designed to (e.g. for nullable types)
        return fromJson(null);
      } catch (_) {
        // If fromJson(null) throws, return null or handle as appropriate
        return null;
      }
    }
    try {
      final jsonData = jsonDecode(rawValue);
      return fromJson(jsonData);
    } catch (e, s) {
      print('Error decoding preference for key "\$key": \$e\$s');
      return null;
    }
  }

  /// Watches for changes to a specific user preference and streams its deserialized JSON value.
  /// Emits `null` if the key is not found, deleted, or if deserialization fails.
  /// [key]: The key of the preference to watch.
  /// [fromJson]: A function to convert the decoded JSON (dynamic) to type [T].
  Stream<T?> watchPreference<T>(
    String key, {
    required T Function(dynamic jsonData) fromJson,
  }) {
    return db
        .watch(
          'SELECT preference_value FROM \$_tableName WHERE preference_key = ?',
          parameters: [key],
        )
        .map((result) {
          if (result.isEmpty) return null; // No rows found
          final row = result.first;
          final rawValue = row['preference_value'] as String?;
          if (rawValue == null) {
            try {
              return fromJson(null);
            } catch (_) {
              return null;
            }
          }
          try {
            final jsonData = jsonDecode(rawValue);
            return fromJson(jsonData);
          } catch (e, s) {
            print('Error decoding preference for key "\$key" in stream: \$e\$s');
            return null;
          }
        });
  }

  /// Retrieves the raw preference data (key, JSON value, value_type) as a map.
  /// Returns `null` if the key is not found.
  Future<Map<String, dynamic>?> getRawPreference(String key) async {
    final row = await db.get(
      'SELECT preference_key, preference_value, value_type FROM \$_tableName WHERE preference_key = ?',
      [key],
    );
    if (row == null) return null;
    return {
      'preference_key': row['preference_key'],
      'preference_value': row['preference_value'],
      'value_type': row['value_type'],
    };
  }

  /// Watches for changes to a specific user preference and streams its raw data as a map.
  /// Emits `null` if the key is not found or deleted.
  Stream<Map<String, dynamic>?> watchRawPreference(String key) {
    return db
        .watch(
          'SELECT preference_key, preference_value, value_type FROM \$_tableName WHERE preference_key = ?',
          parameters: [key],
        )
        .map((result) {
          if (result.isEmpty) return null; // No rows found
          final row = result.first;
          return {
            'preference_key': row['preference_key'],
            'preference_value': row['preference_value'],
            'value_type': row['value_type'],
          };
        });
  }

  /// Deletes a user preference by its key.
  Future<void> deletePreference(String key) async {
    await db.execute('DELETE FROM \$_tableName WHERE preference_key = ?', [key]);
  }

  /// Ensures that a set of default preferences are set if they don't already exist.
  /// [defaultSettings]: A map where keys are preference keys and values are records
  /// containing the default `value` and `valueType`.
  Future<void> ensureDefaultPreferences(
    Map<String, ({Object value, UserPreferenceValueType valueType})> defaultSettings,
  ) async {
    for (final entry in defaultSettings.entries) {
      final key = entry.key;
      final defaultValue = entry.value.value;
      final valueType = entry.value.valueType;

      final existing = await getRawPreference(key);
      if (existing == null) {
        // Key does not exist, set the default
        await setPreference<dynamic>(key, defaultValue, valueType: valueType);
        print('Set default preference for key "\$key"');
      }
    }
  }
}

""");

    // --- Riverpod Provider ---
    if (config.useRiverpod) {
      buffer.writeln(
        'final userPreferencesManagerProvider = Provider<UserPreferencesManager>((ref) {',
      );
      buffer.writeln('  final database = ref.watch(databaseProvider);');
      buffer.writeln('  return UserPreferencesManager(database.db);');
      buffer.writeln('});');
    }

    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(buffer.toString());
      _logger.info('Generated User Preferences Manager: $filePath');
    } catch (e) {
      _logger.severe(
        'Error writing User Preferences Manager file $filePath: $e',
      );
    }
  }
}
