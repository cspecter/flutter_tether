import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/utils/logger.dart';

/// Generates Dart files for initializing a sqlite_async database with platform-conditional support,
/// including migration logic using SQL strings imported from generated Dart files.
class SqliteDatabaseGenerator {
  final SupabaseGenConfig config;
  final Logger _logger;

  // File names
  static const String _interfaceFileName = 'database_interface.dart';
  static const String _nativeFileName = 'database_native.dart';
  static const String _webFileName = 'database_web.dart';
  static const String _mainDbFileName = 'database.dart'; // Main entry point

  // Class names
  static const String _interfaceClassName = 'AppDatabase';
  static const String _nativeClassName = 'NativeSqliteDb';
  static const String _webClassName = 'WebSqliteDb';

  // Regex to match migration files like:
  // migration_v0001.dart
  // migration_v0000_core_feed.dart
  static final RegExp _migrationFileRegex = RegExp(
    r'^migration_v(\d{4,})(?:_([a-zA-Z0-9_]+))?\.dart$',
  );

  SqliteDatabaseGenerator({required this.config, Logger? logger})
    : _logger = logger ?? Logger('SqliteDatabaseGenerator');

  Future<void> generate() async {
    final outputDir = config.outputDirectory;
    final dbFileName = config.databaseName;

    final List<_MigrationInfo> foundMigrations = [];
    final fullMigrationsPath = p.join(
      outputDir,
      config.sqliteMigrationsSubDir,
    ); // Corrected
    final migrationsDir = Directory(fullMigrationsPath);

    if (await migrationsDir.exists()) {
      try {
        final entities = await migrationsDir.list().toList();
        for (final entity in entities) {
          if (entity is File) {
            final filename = p.basename(entity.path);
            final match = _migrationFileRegex.firstMatch(filename);
            if (match != null) {
              final versionStr = match.group(1)!; // e.g., "0000"
              final suffixIdentifier = match.group(
                2,
              ); // e.g., "core_feed" or null
              try {
                final version = int.parse(versionStr);
                foundMigrations.add(
                  _MigrationInfo(
                    version: version,
                    versionPadded: versionStr,
                    suffixIdentifier: suffixIdentifier,
                    fileNameWithExtension: filename,
                  ),
                );
              } catch (e) {
                _logger.warning(
                  'Could not parse version from migration filename: $filename',
                );
              }
            }
          }
        }
        foundMigrations.sort(); // Sort by version
        if (foundMigrations.isNotEmpty) {
          _logger.info(
            'Found ${foundMigrations.length} migrations. Latest version: ${foundMigrations.last.version}',
          );
        } else {
          _logger.info('No migrations found in ${migrationsDir.path}.');
        }
      } catch (e) {
        _logger.severe(
          'Error scanning migrations directory ${migrationsDir.path}: $e',
        );
      }
    } else {
      _logger.warning(
        'Migrations directory ${migrationsDir.path} not found. Assuming no migrations.',
      );
    }

    final int latestNumericVersion =
        foundMigrations.isNotEmpty ? foundMigrations.last.version : 0;

    final interfaceContent = _generateInterfaceFileContent();
    final nativeContent = _generateNativeFileContent(
      dbFileName,
      foundMigrations,
      config.sqliteMigrationsSubDir,
    ); // Corrected
    final webContent = _generateWebFileContent(
      dbFileName,
      foundMigrations,
      config.sqliteMigrationsSubDir,
    ); // Corrected
    final mainDbContent = _generateMainDatabaseFileContent(
      latestNumericVersion,
    ); // Pass latestNumericVersion if needed by sqflite_common_ffi_web

    await _writeFile(
      p.join(outputDir, _interfaceFileName),
      interfaceContent,
      'Interface',
    );
    await _writeFile(
      p.join(outputDir, _nativeFileName),
      nativeContent,
      'Native DB',
    );
    await _writeFile(p.join(outputDir, _webFileName), webContent, 'Web DB');
    await _writeFile(
      p.join(outputDir, _mainDbFileName),
      mainDbContent,
      'Main DB',
    );

    _logger.info(
      'Database files generated successfully in directory: $outputDir',
    );
  }

  Future<void> _writeFile(
    String filePath,
    String content,
    String fileType,
  ) async {
    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      _logger.info('Generated $fileType file: $filePath');
    } catch (e) {
      _logger.severe('Error writing $fileType file $filePath: $e');
    }
  }

  String _generateInterfaceFileContent() {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: constant_identifier_names');
    buffer.writeln();
    buffer.writeln("import 'package:sqlite_async/sqlite3_common.dart';");
    buffer.writeln(
      '/// Abstract interface for database operations, allowing for different',
    );
    buffer.writeln('/// implementations on native and web platforms.');
    buffer.writeln('abstract class $_interfaceClassName {');
    buffer.writeln('  /// Initializes the database.');
    buffer.writeln('  Future<void> initialize();');
    buffer.writeln();
    buffer.writeln('  /// Closes the database connection.');
    buffer.writeln('  Future<void> close();');
    buffer.writeln();
    buffer.writeln('  /// Provides access to the underlying database object.');
    buffer.writeln(
      '  /// The type of this object will vary depending on the platform implementation.',
    );
    buffer.writeln('  dynamic get db;');
    buffer.writeln();
    buffer.writeln('  // Common database methods');
    buffer.writeln(
      '  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]);',
    );
    buffer.writeln(
      '  Future<ResultSet> rawExecute(String sql, [List<Object?>? arguments]);',
    );
    buffer.writeln(
      '  Future<T> transaction<T>(Future<T> Function(dynamic tx) action); // tx type is dynamic due to platform differences',
    );
    buffer.writeln('}');
    return buffer.toString();
  }

  String _generateNativeFileContent(
    String dbFileName,
    List<_MigrationInfo> migrationsList,
    String migrationsImportSubDir,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln(
      '// ignore_for_file: constant_identifier_names, avoid_print',
    );
    buffer.writeln();
    buffer.writeln("import 'dart:io';");
    buffer.writeln("import 'package:path/path.dart' as p;");
    buffer.writeln("import 'package:path_provider/path_provider.dart';");
    buffer.writeln("import 'package:sqlite_async/sqlite_async.dart';");
    buffer.writeln("import 'package:sqlite_async/sqlite3_common.dart';");
    buffer.writeln(
      "import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';",
    );
    buffer.writeln();
    buffer.writeln("import './$_interfaceFileName';");
    buffer.writeln();
    buffer.writeln('// Import generated migration SQL strings');
    if (migrationsList.isNotEmpty) {
      for (final migration in migrationsList) {
        final importPath = p
            .join(migrationsImportSubDir, migration.fileNameWithExtension)
            .replaceAll(r'\', '/');
        buffer.writeln("import '$importPath' as ${migration.importAlias};");
      }
    } else {
      buffer.writeln('// No migrations found or generated.');
    }
    buffer.writeln();
    buffer.writeln(
      '/// Native SQLite implementation using sqlite_async for $_interfaceClassName.',
    );
    buffer.writeln('class $_nativeClassName implements $_interfaceClassName {');
    buffer.writeln("  static const String _dbFileName = '$dbFileName';");
    buffer.writeln('  SqliteDatabase? _db;');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  dynamic get db {');
    buffer.writeln(
      '    if (_db == null) throw StateError("Native database not initialized.");',
    );
    buffer.writeln('    return _db!;');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  Future<void> initialize() async {');
    buffer.writeln('    if (_db != null) return; // Already initialized');
    buffer.writeln();
    buffer.writeln('    // --- Platform Specific Setup ---');
    buffer.writeln('    if (Platform.isAndroid) {');
    buffer.writeln(
      '      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();',
    );
    buffer.writeln('    }');
    buffer.writeln();
    buffer.writeln('    // --- Determine Database Path ---');
    buffer.writeln(
      '    final documentsDir = await getApplicationDocumentsDirectory();',
    );
    buffer.writeln(
      '    final dbPath = p.join(documentsDir.path, _dbFileName);',
    );
    buffer.writeln();
    buffer.writeln('    // --- Migration Setup ---');
    buffer.writeln('    final migrations = SqliteMigrations();');
    if (migrationsList.isNotEmpty) {
      for (final migration in migrationsList) {
        buffer.writeln(
          '    migrations.add(SqliteMigration(${migration.version + 1}, (tx) async {',
        );
        // Iterate and execute each statement
        buffer.writeln(
          '      for (final statement in ${migration.importAlias}.${migration.variableName}) {',
        );
        buffer.writeln(
          '        if (statement.trim().startsWith("--")) continue; // Skip comments',
        );
        buffer.writeln('        await tx.execute(statement);');
        buffer.writeln('      }');
        buffer.writeln('    }));');
      }
    }
    buffer.writeln();
    buffer.writeln('    // --- Open Database ---');
    buffer.writeln(
      '    final newDb = SqliteDatabase(path: dbPath, options: const SqliteOptions());',
    );
    buffer.writeln('    await migrations.migrate(newDb);');
    buffer.writeln('    _db = newDb;');
    buffer.writeln(
      '    print("INFO: Native database initialized at \$dbPath");',
    );
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  Future<void> close() async {');
    buffer.writeln('    await _db?.close();');
    buffer.writeln('    _db = null;');
    buffer.writeln('    print("INFO: Native database closed.");');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln(
      '  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {',
    );
    buffer.writeln(
      '    if (_db == null) throw StateError("Native database not initialized for rawQuery.");',
    );
    buffer.writeln('    return _db!.getAll(sql, arguments ?? []);');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln(
      '  Future<ResultSet> rawExecute(String sql, [List<Object?>? arguments]) async {',
    );
    buffer.writeln(
      '    if (_db == null) throw StateError("Native database not initialized for rawExecute.");',
    );
    buffer.writeln('    return _db!.execute(sql, arguments ?? []);');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln(
      '  Future<T> transaction<T>(Future<T> Function(dynamic tx) action) async {',
    );
    buffer.writeln(
      '    if (_db == null) throw StateError("Native database not initialized for transaction.");',
    );
    buffer.writeln(
      '    // Cast tx to SqliteWriteContext for sqlite_async specific operations if needed inside action',
    );
    buffer.writeln(
      '    return _db!.writeTransaction(action as Future<T> Function(SqliteWriteContext tx));',
    );
    buffer.writeln('  }');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln(
      '/// Factory function to get the native database implementation.',
    );
    buffer.writeln(
      '$_interfaceClassName getDatabase() => $_nativeClassName();',
    );
    return buffer.toString();
  }

  String _generateWebFileContent(
    String dbFileName,
    List<_MigrationInfo> migrationsList,
    String migrationsImportSubDir,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln(
      '// ignore_for_file: constant_identifier_names, avoid_print',
    );
    buffer.writeln();
    buffer.writeln("import 'package:sqlite_async/sqlite_async.dart';");
    buffer.writeln("import 'package:sqlite_async/sqlite3_common.dart';");
    buffer.writeln(
      "import 'package:path/path.dart' as p;",
    ); // For migration import paths
    buffer.writeln();
    buffer.writeln("import './$_interfaceFileName';");
    buffer.writeln();
    buffer.writeln('// Import generated migration SQL strings');
    if (migrationsList.isNotEmpty) {
      for (final migration in migrationsList) {
        final importPath = p
            .join(migrationsImportSubDir, migration.fileNameWithExtension)
            .replaceAll(r'\', '/'); // Ensure forward slashes for import paths
        buffer.writeln("import '$importPath' as ${migration.importAlias};");
      }
    } else {
      buffer.writeln('// No migrations found or generated.');
    }
    buffer.writeln();
    buffer.writeln(
      '/// Web SQLite implementation using sqlite_async for $_interfaceClassName.',
    );
    buffer.writeln('class $_webClassName implements $_interfaceClassName {');
    buffer.writeln(
      "  static const String _dbFileName = '${dbFileName}_web.sqlite'; // Filename for sqlite_async on web (uses VFS)",
    );
    buffer.writeln('  SqliteDatabase? _db;');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  dynamic get db {');
    buffer.writeln(
      '    if (_db == null) throw StateError("Web sqlite_async database not initialized.");',
    );
    buffer.writeln('    return _db!;');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  Future<void> initialize() async {');
    buffer.writeln('    if (_db != null) return; // Already initialized');
    buffer.writeln();
    buffer.writeln(
      '    print("INFO: Initializing sqlite_async database for web...");',
    );
    buffer.writeln(
      '    // Ensure sqlite3.wasm is available in your web/ directory and loaded.',
    );
    buffer.writeln(
      '    // This setup is usually done in main.dart for web projects.',
    );
    buffer.writeln();
    buffer.writeln('    // --- Migration Setup ---');
    buffer.writeln('    final migrations = SqliteMigrations();');
    if (migrationsList.isNotEmpty) {
      for (final migration in migrationsList) {
        buffer.writeln(
          '    migrations.add(SqliteMigration(${migration.version + 1}, (tx) async {',
        );
        // Iterate and execute each statement
        buffer.writeln(
          '      for (final statement in ${migration.importAlias}.${migration.variableName}) {',
        );
        buffer.writeln(
          '        if (statement.trim().startsWith("--")) continue; // Skip comments',
        );
        buffer.writeln('        await tx.execute(statement);');
        buffer.writeln('      }');
        buffer.writeln('    }));');
      }
    }
    buffer.writeln();
    buffer.writeln('    // --- Open Database ---');
    buffer.writeln(
      '    // For web, sqlite_async uses a virtual file system (e.g., IndexedDB).',
    );
    buffer.writeln(
      '    // The path provided is typically used as a name/key for the database.',
    );
    buffer.writeln('    _db = SqliteDatabase(path: _dbFileName);');
    buffer.writeln('    await migrations.migrate(_db!);');
    buffer.writeln(
      '    print("INFO: Web sqlite_async database initialized: \$_dbFileName");',
    );
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  Future<void> close() async {');
    buffer.writeln('    await _db?.close();');
    buffer.writeln('    _db = null;');
    buffer.writeln('    print("INFO: Web sqlite_async database closed.");');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln(
      '  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {',
    );
    buffer.writeln(
      '    if (_db == null) throw StateError("Web sqlite_async database not initialized for rawQuery.");',
    );
    buffer.writeln('    return _db!.getAll(sql, arguments ?? []);');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln(
      '  Future<ResultSet> rawExecute(String sql, [List<Object?>? arguments]) async {',
    );
    buffer.writeln(
      '    if (_db == null) throw StateError("Web sqlite_async database not initialized for rawExecute.");',
    );
    buffer.writeln('    return _db!.execute(sql, arguments ?? []);');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln(
      '  Future<T> transaction<T>(Future<T> Function(dynamic tx) action) async {',
    );
    buffer.writeln(
      '    if (_db == null) throw StateError("Web sqlite_async database not initialized for transaction.");',
    );
    buffer.writeln(
      '    // Cast tx to SqliteWriteContext for sqlite_async specific operations if needed inside action',
    );
    buffer.writeln(
      '    return _db!.writeTransaction(action as Future<T> Function(SqliteWriteContext tx));',
    );
    buffer.writeln('  }');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln(
      '/// Factory function to get the web database implementation using sqlite_async.',
    );
    buffer.writeln('$_interfaceClassName getDatabase() => $_webClassName();');
    return buffer.toString();
  }

  String _generateMainDatabaseFileContent(int latestNumericVersion) {
    // Added latestNumericVersion parameter
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln(
      '// ignore_for_file: constant_identifier_names, avoid_print',
    );
    buffer.writeln();
    if (config.useRiverpod) {
      buffer.writeln(
        "import 'package:flutter_riverpod/flutter_riverpod.dart';",
      );
    } else {
      buffer.writeln(
        "// import 'package:provider/provider.dart'; // Or your chosen state management",
      );
    }
    buffer.writeln();
    buffer.writeln("import './$_interfaceFileName';");
    buffer.writeln(
      "import './$_nativeFileName' if (dart.library.html) './$_webFileName' as platform_db;",
    );
    buffer.writeln();
    buffer.writeln('/// Initializes the platform-specific database instance.');
    buffer.writeln('/// This should be called once at application startup, before the app is run.');
    buffer.writeln('///');
    buffer.writeln('/// The returned [$_interfaceClassName] instance should then be passed into a `ProviderScope`');
    buffer.writeln('/// override to make the database available to the rest of the application.');
    buffer.writeln('///');
    buffer.writeln('/// ### Example (`main.dart`):');
    buffer.writeln('/// ```dart');
    buffer.writeln('/// Future<void> main() async {');
    buffer.writeln('///   WidgetsFlutterBinding.ensureInitialized();');
    buffer.writeln('///');
    buffer.writeln('///   // Initialize the database');
    buffer.writeln('///   final db = await initializeDatabase();');
    buffer.writeln('///');
    buffer.writeln('///   runApp(');
    buffer.writeln('///     ProviderScope(');
    buffer.writeln('///       overrides: [');
    buffer.writeln('///         databaseProvider.overrideWithValue(db),');
    buffer.writeln('///       ],');
    buffer.writeln('///       child: const MyApp(),');
    buffer.writeln('///     ),');
    buffer.writeln('///   );');
    buffer.writeln('/// }');
    buffer.writeln('/// ```');
    buffer.writeln('Future<$_interfaceClassName> initializeDatabase() async {');
    buffer.writeln('  final dbInstance = platform_db.getDatabase();');
    buffer.writeln('  await dbInstance.initialize();');
    buffer.writeln('  return dbInstance;');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln(
      '/// Riverpod provider for accessing the application\'s database.',
    );
    buffer.writeln(
      '/// This provider must be overridden in a `ProviderScope` at the root of the app.',
    );
    buffer.writeln(
      '/// See [initializeDatabase] for a complete example.',
    );
    if (config.useRiverpod) {
      buffer.writeln(
        'final databaseProvider = Provider<$_interfaceClassName>((ref) {',
      );
      buffer.writeln(
        '  // This should not be reached. The provider is meant to be overridden.',
      );
      buffer.writeln(
        '  throw UnimplementedError(\'The databaseProvider must be overridden in the ProviderScope\');',
      );
      buffer.writeln('});');
    } else {
      // ... (non-Riverpod placeholder)
    }
    buffer.writeln();
    buffer.writeln(
      '// Optional: Helper to access the specific underlying database objects.',
    );
    buffer.writeln('/*');
    if (config.useRiverpod) {
      buffer.writeln(
        '// For native, if you need the raw sqlite_async.SqliteDatabase:',
      );
      buffer.writeln(
        '// final nativeSqliteDatabaseProvider = Provider<sqlite_async.SqliteDatabase?>((ref) {',
      );
      buffer.writeln(
        '//   final appDbAsyncValue = ref.watch(databaseProvider);',
      );
      buffer.writeln('//   final appDb = appDbAsyncValue.asData?.value;');
      buffer.writeln(
        '//   if (appDb != null && appDb.db is sqlite_async.SqliteDatabase) {',
      );
      buffer.writeln('//     return appDb.db as sqlite_async.SqliteDatabase;');
      buffer.writeln('//   }');
      buffer.writeln('//   return null;');
      buffer.writeln('// });');
      buffer.writeln(
        '// For web, if you need the raw sqflite_common Database:',
      );
      buffer.writeln(
        '// final webSqfliteDatabaseProvider = Provider<Database?>((ref) { // From sqflite_common.sqlite_api',
      );
      buffer.writeln(
        '//   final appDbAsyncValue = ref.watch(databaseProvider);',
      );
      buffer.writeln('//   final appDb = appDbAsyncValue.asData?.value;');
      buffer.writeln('//   if (appDb != null && appDb.db is Database) {');
      buffer.writeln('//     return appDb.db as Database;');
      buffer.writeln('//   }');
      buffer.writeln('//   return null;');
      buffer.writeln('// });');
    }
    buffer.writeln('*/');

    return buffer.toString();
  }
}

class _MigrationInfo implements Comparable<_MigrationInfo> {
  final int version;
  final String versionPadded;
  final String? suffixIdentifier; // e.g., "core_feed"
  final String fileNameWithExtension; // e.g., "migration_v0000_core_feed.dart"

  _MigrationInfo({
    required this.version,
    required this.versionPadded,
    this.suffixIdentifier,
    required this.fileNameWithExtension,
  });

  String get importAlias {
    return 'mig_v$versionPadded${suffixIdentifier != null ? '_${suffixIdentifier!.toLowerCase().replaceAllMapped(RegExp(r'_([a-z])'), (match) => match.group(1)!.toUpperCase())}' : ''}';
  }

  String get variableName {
    // Adjusted to reflect the new List<String> variable naming convention
    final baseName = 'migrationSqlStatementsV';
    if (suffixIdentifier != null) {
      return '$baseName$versionPadded\_$suffixIdentifier';
    } else {
      return '$baseName$version';
    }
  }

  @override
  int compareTo(_MigrationInfo other) {
    return version.compareTo(other.version);
  }

  @override
  String toString() {
    return 'MigrationInfo(version: $version, file: $fileNameWithExtension, alias: $importAlias, var: $variableName)';
  }
}
