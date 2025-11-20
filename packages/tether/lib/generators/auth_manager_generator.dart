import 'dart:io';
import 'package:inflection3/inflection3.dart';
import 'package:recase/recase.dart';
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:path/path.dart' as p;

Future<void> generateAuthManagerFiles({
  required SupabaseGenConfig config,
  required List<SupabaseTableInfo> allTables,
}) async {
  if (!config.generateAuthentication) {
    print('AuthManager generation is disabled in the config. Skipping.');
    return;
  }

  final profileTableInfo = allTables.firstWhere(
    (t) => t.originalName == config.authProfileTableName,
    orElse: () {
      print(
        'Error: Profile table "${config.authProfileTableName}" not found in allTables. Cannot generate AuthManager.',
      );
      // Return a dummy SupabaseTableInfo to prevent null errors if we were to proceed,
      // but ideally, we should throw or handle this more gracefully.
      // For now, we'll just print and exit this function.
      return SupabaseTableInfo(
        name: '',
        originalName: '',
        localName: '',
        schema: '',
        columns: [],
        foreignKeys: [],
        indexes: [],
        reverseRelations: [],
        comment: '',
      );
    },
  );

  if (profileTableInfo.originalName.isEmpty) {
    // Error already printed
    return;
  }

  final profileModelClassName = _getDartClassName(profileTableInfo, config);
  // Assuming local profile table name is the same as the Supabase one for simplicity.
  // This could be made configurable if needed.
  final localProfileTableName = profileTableInfo.localName;

  await _generateAuthProvidersFile(
    config: config,
    profileModelClassName: profileModelClassName,
    supabaseProfileTableName: config.authProfileTableName,
    localProfileTableName: localProfileTableName,
  );
}

Future<void> _generateAuthProvidersFile({
  required SupabaseGenConfig config,
  required String profileModelClassName,
  required String supabaseProfileTableName,
  required String localProfileTableName,
}) async {
  final buffer = StringBuffer();
  final providersDir = config.providersDirectoryPath; // Use the helper getter

  // Calculate relative paths
  final authManagerPath = p
      .relative(
        p.join(config.outputDirectory, 'managers', 'auth_manager.g.dart'),
        from: providersDir,
      )
      .replaceAll(r'\', '/');
  final modelsFilePath = p
      .relative(config.modelsFilePath, from: providersDir)
      .replaceAll(r'\', '/');
  final schemaFilePath = p
      .relative(config.generatedSupabaseSchemaDartFilePath, from: providersDir)
      .replaceAll(r'\', '/');
  // Assuming database_provider.dart and supabase_client_provider.dart are accessible from providersDir
  // These might need to be configurable if their locations vary greatly.
  // For now, let's assume they are in a way that `../database/database_provider.dart` or similar works.
  // A common pattern is to have a central `database.dart` in `outputDirectory` that exports the provider.
  final databaseProviderPath = p
      .relative(
        p.join(config.outputDirectory, 'database.dart'),
        from: providersDir,
      )
      .replaceAll(r'\', '/');

  buffer.writeln('''
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'; // For User
import 'package:tether_libs/auth_manager/auth_manager.dart';
import '$modelsFilePath';
import '$schemaFilePath';

import '$databaseProviderPath'; // Provides 'databaseProvider'

final authManagerProvider = Provider<AuthManager<$profileModelClassName>>((ref) {
  final supabaseClient = Supabase.instance.client;
  final localDb = ref.watch(databaseProvider).db; 
  final tableSchemas = globalSupabaseSchema; // Assumes globalSupabaseSchema is directly available via schemaFilePath import

  final manager = AuthManager<$profileModelClassName>(
    supabaseClient: supabaseClient,
    localDb: localDb,
    supabaseProfileTableName: '$supabaseProfileTableName',
    localProfileTableName: '$localProfileTableName',
    profileFromJsonFactory: (json) => $profileModelClassName.fromJson(json),
    profileFromSqliteFactory: (row) => $profileModelClassName.fromSqlite(row),
    tableSchemas: tableSchemas,
  );

  ref.onDispose(() => manager.dispose());
  return manager;
});

final currentUserProvider = StreamProvider<User?>((ref) {
  final authManager = ref.watch(authManagerProvider);
  // Use ValueNotifier directly for simpler StreamProvider
  return authManager.currentUserNotifier.stream;
});

final currentProfileProvider = StreamProvider<$profileModelClassName?>((ref) {
  final authManager = ref.watch(authManagerProvider);
  // Use ValueNotifier directly for simpler StreamProvider
  return authManager.currentProfileNotifier.stream;
});

// Extension to convert ValueNotifier to Stream for StreamProvider
extension _ValueNotifierStream<T> on ValueNotifier<T> {
  Stream<T> get stream {
    final controller = StreamController<T>();
    controller.add(value); // Add current value immediately
    void listener() {
      if (!controller.isClosed) {
        controller.add(value);
      }
    }
    addListener(listener);
    controller.onCancel = () {
      removeListener(listener);
      // Do not close the controller here if it's meant to be long-lived
      // and potentially re-listened to, or if the ValueNotifier itself is not disposed.
      // However, for a typical StreamProvider usage, closing on cancel is fine.
    };
    // Closing the controller when the ValueNotifier is disposed is ideal,
    // but ValueNotifier doesn't have an onDispose callback.
    // The StreamProvider's autoDispose or manual ref.onDispose for the authManagerProvider
    // handles the lifecycle of the ValueNotifier itself.
    return controller.stream;
  }
}
''');

  final file = File(p.join(providersDir, 'auth_providers.g.dart'));
  final parentDir = file.parent;
  if (!await parentDir.exists()) {
    await parentDir.create(recursive: true);
  }
  await file.writeAsString(buffer.toString());
  print('Generated Auth providers at ${file.path}');
}

/// Generates the Dart class name for a table, consistent with ModelGenerator.
String _getDartClassName(SupabaseTableInfo table, SupabaseGenConfig config) {
  final prefix = config.modelPrefix ?? '';
  final suffix = config.modelSuffix ?? 'Model';
  return '$prefix${singularize(table.localName.pascalCase)}$suffix';
}
