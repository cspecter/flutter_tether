import 'dart:io';
import 'package:inflection3/inflection3.dart';
import 'package:recase/recase.dart';
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/utils/string_utils.dart';
import 'package:path/path.dart' as p; // Import the path package

Future<void> generateClientManagers({
  required String outputDirectory,
  required List<SupabaseTableInfo> tables,
  required SupabaseGenConfig config,
}) async {
  if (!config.generateClientManagers) {
    print('ClientManager generation is disabled in the config. Skipping.');
    return;
  }

  for (final table in tables) {
    // Use the same logic as ModelGenerator to get the Dart class name
    final modelClassName = _getDartClassName(table, config);
    final className =
        '${StringUtils.capitalize(table.localName.camelCase)}Manager';
    final providerName = '${table.localName.camelCase}ManagerProvider';

    final buffer = StringBuffer();

    // Get the basename of the schema file for relative import
    final schemaFileName = p.basename(
      config.generatedSupabaseSchemaDartFilePath,
    );

    // Generate the ClientManager class
    buffer.writeln('''
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: constant_identifier_names

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tether_libs/client_manager/client_manager.dart';
import '../${config.modelsFileName}'; // Assumes models.dart is in outputDirectory
import '../database.dart'; // Assumes database.dart is in outputDirectory
import '../$schemaFileName'; // Corrected relative import for schema file
''');

    if (config.useRiverpod) {
      buffer.writeln('''
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/feed_provider.dart';
''');
    } else {
      buffer.writeln('''
import 'package:provider/provider.dart';
''');
    }

    // Class definition
    buffer.writeln('''
class $className extends ClientManager<$modelClassName> {
  $className({
    required super.localDb,
    required super.client,
    required super.tableSchemas,
    required super.fromJsonFactory,
    required super.fromSqliteFactory,
  }) : super(
          tableName: '${table.originalName}',
          localTableName: '${table.localName}',
        );
}
''');

    // Generate the Provider or Riverpod Provider
    if (config.useRiverpod) {
      buffer.writeln('''
final $providerName = Provider<$className>((ref) {
  final database = ref.watch(databaseProvider);

  return $className(
    localDb: database.db,
    client: Supabase.instance.client,
    tableSchemas: globalSupabaseSchema,
    fromJsonFactory: (json) => $modelClassName.fromJson(json),
    fromSqliteFactory: (json) => $modelClassName.fromSqlite(json),
  );
});

final ${table.localName.camelCase}FeedProvider = StreamNotifierProvider.autoDispose.family<
  FeedStreamNotifier<$modelClassName>, // NotifierT: Your notifier class
  FeedStreamState<$modelClassName>, // StateT: The type of data the stream emits (updated to use FeedStreamState)
  FeedStreamNotifierSettings<
    $modelClassName
  > // ArgT: The type of the settings argument
>(FeedStreamNotifier.new);
''');
    } else {
      buffer.writeln('''
final $providerName = ChangeNotifierProvider<$className>((context) {
  return $className(
    localDb: Provider.of<SqliteDatabase>(context, listen: false),
    client: Supabase.instance.client,
    schemaPath: '${config.generatedSupabaseSchemaDartFilePath}', // Updated to use schemaFilePath
  );
});
''');
    }

    // Write the generated code to a file
    final file = File(
      '$outputDirectory/managers/${table.localName.snakeCase}_client_manager.g.dart',
    );
    final parentDir = file.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }
    file.writeAsStringSync(buffer.toString());
  }
}

/// Generates the Dart class name for a table, consistent with ModelGenerator.
String _getDartClassName(SupabaseTableInfo table, SupabaseGenConfig config) {
  // Use the safe local name (already handles Dart keywords/built-ins)
  // Apply prefix and suffix from config
  final prefix = config.modelPrefix ?? '';
  final suffix = config.modelSuffix ?? ''; // Default suffix if not provided
  // Ensure PascalCase for the base name before adding prefix/suffix
  return '$prefix${singularize(table.localName.pascalCase)}$suffix';
}
