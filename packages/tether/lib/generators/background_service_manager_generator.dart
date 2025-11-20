import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_tether/config/config_model.dart'; // Assuming SupabaseGenConfig is here

/// Generates a Riverpod provider for the BackgroundJobManager.
Future<void> generateBackgroundJobManagerProviderFile({
  required SupabaseGenConfig config,
  // Logger? logger, // Optional: if you want to integrate logging
}) async {
  print('Generating BackgroundJobManager Riverpod provider...');
  final buffer = StringBuffer();
  final providersDir = config.providersDirectoryPath; // Use the helper getter
  final fileName = 'background_job_manager_provider.g.dart';

  // Calculate the relative path to database.dart from the providers directory
  final databaseProviderFileName =
      'database.dart'; // Assuming this is the standard name
  final databaseProviderPath = p
      .relative(
        p.join(config.outputDirectory, databaseProviderFileName),
        from: providersDir,
      )
      .replaceAll(r'\', '/');

  buffer.writeln('''
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: unused_import, unnecessary_import, lines_longer_than_80_chars

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite_async/sqlite_async.dart'; // For SqliteConnection type
import 'package:tether_libs/background_service/background_service_manager.dart';
import '$databaseProviderPath'; // Provides 'databaseProvider'

/// Riverpod provider for accessing the [BackgroundJobManager].
///
/// This manager is used to interact with the `background_service_jobs` table
/// from the main UI isolate (e.g., for enqueuing jobs or querying their status).
///
/// It requires an active [SqliteConnection] for the UI isolate, which is
/// obtained from the `databaseProvider`.
final backgroundJobManagerProvider = Provider<BackgroundJobManager>((ref) {
  // Assuming 'databaseProvider' is a Provider<YourAppDbClass>
  // and YourAppDbClass has a 'db' getter of type SqliteConnection.
  final appDatabase = ref.watch(databaseProvider);
  final dbConnection = appDatabase.db;
  return BackgroundJobManager(db: dbConnection);
});

/// StreamProvider to watch all background jobs from the local database,
/// sorted by their creation date in descending order (newest first).
final watchBackgroundJobsProvider = StreamProvider((ref) {
  final manager = ref.watch(backgroundJobManagerProvider);
  return manager.watchAllJobs();
});
''');

  final file = File(p.join(providersDir, fileName));
  final parentDir = file.parent;
  if (!await parentDir.exists()) {
    await parentDir.create(recursive: true);
  }
  await file.writeAsString(buffer.toString());
  print('Generated BackgroundJobManager Riverpod provider at ${file.path}');
  print(
    'INFO: The generated provider now imports the main database provider. Ensure that the database provider is correctly set up and provides an initialized SqliteConnection.',
  );
}
