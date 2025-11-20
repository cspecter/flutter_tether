import 'package:collection/collection.dart'; // Added import
import 'package:postgres/postgres.dart';
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/utils/logger.dart';
import 'package:tether_libs/utils/string_utils.dart';
// import 'package:tether_libs/utils/string_utils.dart'; // Already in table_info.dart, but ensure it's accessible or add here if needed for StringUtils.pluralize

class SchemaReader {
  /// The configuration settings for connecting to the database and filtering tables.
  final SupabaseGenConfig config;

  /// The active database connection. Null if not connected.
  Connection? _connection;

  /// Logger instance for this class.
  final Logger _logger = Logger('SchemaReader');

  /// Creates an instance of [SchemaReader].
  ///
  /// Requires the generator [config] settings.
  SchemaReader(this.config);

  /// Establishes a connection to the PostgreSQL database.
  ///
  /// Uses the connection details provided in the [config] object.
  /// Logs the connection attempt and success or failure.
  ///
  /// {@tool example}
  /// ```dart
  /// final config = SupabaseGenConfig(/*...*/);
  /// final reader = SchemaReader(config);
  /// try {
  ///   await reader.connect();
  ///   // Connection successful
  /// } catch (e) {
  ///   print('Failed to connect: $e');
  /// }
  /// ```
  /// {@end-tool}
  ///
  /// @return A [Future] that completes when the connection is established.
  /// @throws Exception if the connection fails (e.g., network error, authentication failure).
  Future<void> connect() async {
    _logger.info(
      'Connecting to database: ${config.username}@${config.host}:${config.port}/${config.database}',
    );

    try {
      _connection = await Connection.open(
        Endpoint(
          host: config.host,
          port: config.port,
          database: config.database,
          username: config.username,
          password: config.password,
        ),
        // Note: SSL mode is set to disable. This might need adjustment (e.g., to `require`)
        // for secure connections, especially to cloud databases.
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );
      _logger.info('Connected successfully');
    } catch (e) {
      _logger.severe('Connection failed: $e');
      // Rethrow the exception so the caller can handle connection failures.
      rethrow;
    }
  }

  /// Closes the active database connection.
  ///
  /// If no connection is active, this method does nothing gracefully.
  /// Sets the internal [_connection] reference to null.
  ///
  /// {@tool example}
  /// ```dart
  /// await reader.connect();
  /// // ... use reader ...
  /// await reader.disconnect();
  /// ```
  /// {@end-tool}
  ///
  /// @return A [Future] that completes when the connection is closed or if it was already closed.
  Future<void> disconnect() async {
    // Use `?.` for safe invocation if _connection is already null.
    await _connection?.close();
    _connection = null; // Ensure reference is cleared
    _logger.info('Disconnected from database');
  }

  /// Reads the schema information for tables in the connected database.
  ///
  /// Fetches base table information (schema, name, comment) and then concurrently
  /// fetches detailed column information via [_readTableColumns] and foreign key
  /// constraint information via [_readTableForeignKeys] for each eligible table.
  /// It applies filtering rules defined in the [config] (`includeTables`, `excludeTables`, `generateForAllTables`).
  /// Constructs and returns a list of [SupabaseTableInfo] objects.
  ///
  /// {@tool example}
  /// ```dart
  /// final reader = SchemaReader(config);
  /// await reader.connect();
  /// try {
  ///   List<TableInfo> tables = await reader.readTables();
  ///   for (var table in tables) {
  ///     print('Table: ${table.schema}.${table.name}');
  ///     print(' Columns: ${table.columns.map((c) => c.name).join(', ')}');
  ///     print(' Foreign Keys: ${table.foreignKeys.map((fk) => fk.constraintName).join(', ')}');
  ///   }
  /// } finally {
  ///   await reader.disconnect();
  /// }
  /// ```
  /// {@end-tool}
  ///
  /// @return A [Future] containing a list of [SupabaseTableInfo] objects, each representing
  ///         a table that matches the configuration rules. Includes detailed column
  ///         and foreign key information.
  ///         Example return structure:
  ///         ```json
  ///         [
  ///           {
  ///             "name": "posts",
  ///             "schema": "public",
  ///             "comment": "Blog posts",
  ///             "columns": [
  ///               { "name": "id", "type": "integer", "isPrimaryKey": true, ... },
  ///               { "name": "author_id", "type": "uuid", ... },
  ///               { "name": "content", "type": "text", ... }
  ///             ],
  ///             "foreignKeys": [
  ///               {
  ///                 "constraintName": "posts_author_id_fkey",
  ///                 "columnNames": ["author_id"],
  ///                 "foreignSchemaName": "public",
  ///                 "foreignTableName": "users",
  ///                 "foreignColumnNames": ["id"],
  ///                 "updateAction": "NO ACTION",
  ///                 "deleteAction": "CASCADE",
  ///                 ...
  ///               }
  ///             ]
  ///           },
  ///           // ... other tables
  ///         ]
  ///         ```
  /// @throws StateError if the database connection is not initialized (connect() was not called or failed).
  /// @throws Exception if fetching details for a table fails.
  Future<List<SupabaseTableInfo>> readTables() async {
    if (_connection == null) {
      throw StateError('Database connection not initialized.');
    }

    _logger.info('Reading base table information...');
    final List<SupabaseTableInfo> tablesWithoutReverseRelations =
        []; // Renamed from unsortedTables

    // 1. Fetch ALL base table information (existing logic)
    final initialResult = await _connection!.execute(
      Sql(r'''
        SELECT DISTINCT ON (pgc.oid, t.table_schema, t.table_name)
          t.table_schema, t.table_name, obj_description(pgc.oid, 'pg_class') as table_comment
        FROM information_schema.tables t
        JOIN pg_catalog.pg_class pgc ON pgc.relname = t.table_name
          AND pgc.relnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = t.table_schema)
        WHERE t.table_schema NOT IN ('information_schema', 'pg_catalog', 'pg_toast')
          AND t.table_schema NOT LIKE 'pg_temp_%' AND t.table_schema NOT LIKE 'pg_toast_temp_%'
          AND t.table_type = 'BASE TABLE'
        ORDER BY pgc.oid ASC, t.table_schema, t.table_name
      '''),
    );

    // 2. Apply Exclusions based on ORIGINAL DB names (existing logic)
    final List<List<dynamic>> includedBaseTables;
    if (config.excludeTables.isNotEmpty) {
      includedBaseTables =
          initialResult.where((row) {
            final schema = row[0] as String;
            final originalDbName =
                row[1] as String; // Use original name for exclusion check

            // --- ACTUAL EXCLUSION CHECK ---
            bool isExcluded = config.excludeTables.any((pattern) {
              final parts = pattern.split('.');
              if (parts.length == 2) {
                // Schema-qualified pattern
                return _matchesPattern(schema, parts[0]) &&
                    _matchesPattern(originalDbName, parts[1]);
              } else {
                // Simple table name pattern (matches any schema)
                return _matchesPattern(originalDbName, pattern);
              }
            });
            // --- END EXCLUSION CHECK ---

            if (isExcluded) {
              _logger.fine(
                'Excluding table based on config.excludeTables: $schema.$originalDbName',
              );
            }
            // Keep the row in the filtered list only if it was NOT excluded
            return !isExcluded;
          }).toList(); // Convert the filtered iterable back to a list
      _logger.info(
        'Applied exclusions, processing ${includedBaseTables.length} of ${initialResult.length} initially found tables.',
      );
    } else {
      // No exclusions defined, process all initially found tables
      includedBaseTables = initialResult;
      _logger.info(
        'No exclusions defined, processing all ${initialResult.length} initially found tables.',
      );
    }

    // 3. Fetch details (Columns, FKs, Indexes) and build initial TableInfo list (existing logic)
    for (final row in includedBaseTables) {
      final schema = row[0] as String;
      final originalDbName = row[1] as String;
      final comment = row[2] as String?;

      // Apply include rules
      if (!_shouldProcessTableBasedOnIncludes(schema, originalDbName)) {
        _logger.fine(
          'Skipping table based on include rules: $schema.$originalDbName',
        );
        continue;
      }

      _logger.info('Reading schema details for table: $schema.$originalDbName');

      late final List<TetherColumnInfo> columns;
      late final List<SupabaseForeignKeyConstraint> foreignKeys;
      late final List<SupabaseIndexInfo> indexes;

      try {
        // Fetch Columns, FKs, and Indexes concurrently
        final results = await Future.wait([
          _readTableColumns(schema, originalDbName),
          _readTableForeignKeys(schema, originalDbName),
          _readTableIndexes(schema, originalDbName),
        ]);
        columns = results[0] as List<TetherColumnInfo>;
        foreignKeys = results[1] as List<SupabaseForeignKeyConstraint>;
        indexes = results[2] as List<SupabaseIndexInfo>;
      } catch (e, s) {
        _logger.severe(
          'Failed to read complete details for table $schema.$originalDbName: $e\n$s',
        );
        continue;
      }

      tablesWithoutReverseRelations.add(
        SupabaseTableInfo(
          name: StringUtils.toCamelCase(originalDbName),
          originalName: originalDbName,
          schema: schema,
          columns: columns,
          foreignKeys: foreignKeys,
          indexes: indexes,
          comment: comment,
          reverseRelations:
              const [], // Initialize with empty, will be populated next
        ),
      );
    }

    // --- 4. Populate Reverse Relations ---
    _logger.info('Populating reverse relations for all tables...');
    final Map<String, List<ModelReverseRelationInfo>> allReverseRelationsMap =
        {}; // Key: targetTable.uniqueKey

    for (final referencingTableInfo in tablesWithoutReverseRelations) {
      for (final fk in referencingTableInfo.foreignKeys) {
        final targetTableUniqueKey =
            '${fk.foreignTableSchema}.${fk.originalForeignTableName}';

        // Determine fieldNameInThisModel (in the target table's model)
        // This is the name of the list of 'referencingTableInfo' models.
        // Example: if 'books' references 'authors', then in AuthorModel, this field might be 'booksList' or 'books'.
        // A common convention is to use the pluralized camelCase name of the referencing table.
        // This might need to be more sophisticated if multiple FKs from the same table point to the target
        // or if specific naming conventions are desired.
        String fieldName = StringUtils.toCamelCase(
          referencingTableInfo.originalName,
        );
        // Attempt to make it plural. You might need a more robust pluralization utility.
        // For simplicity, if 'StringUtils.pluralize' is not available or complex,
        // you can use a simpler heuristic or make it configurable.
        // Assuming 'StringUtils.toCamelCase' gives 'bookGenre', pluralizing might give 'bookGenres'.
        // If StringUtils.pluralize is available from tether_libs/utils/string_utils.dart:
        // fieldName = StringUtils.pluralize(fieldName);
        // If not, a simple 's' for now, or leave as singular and let ModelGenerator handle pluralization.
        // Let's assume a simple pluralization for now if not already plural.
        if (!fieldName.endsWith('s')) {
          fieldName = '${fieldName}s'; // Basic pluralization
        }

        final reverseRelation = ModelReverseRelationInfo(
          fieldNameInThisModel: fieldName,
          referencingTableOriginalName: referencingTableInfo.originalName,
          foreignKeyColumnInReferencingTable: fk.originalColumns.first,
        );

        (allReverseRelationsMap[targetTableUniqueKey] ??= []).add(
          reverseRelation,
        );
      }
    }

    // 5. Create new TableInfo instances with populated reverseRelations
    final List<SupabaseTableInfo> tablesWithReverseRelations =
        tablesWithoutReverseRelations.map((table) {
          return SupabaseTableInfo(
            name: table.name,
            originalName: table.originalName,
            localName: table.localName,
            schema: table.schema,
            columns: table.columns,
            foreignKeys: table.foreignKeys,
            indexes: table.indexes,
            comment: table.comment,
            reverseRelations:
                allReverseRelationsMap[table.uniqueKey] ?? const [],
          );
        }).toList();

    _logger.info('Finished populating reverse relations.');
    return tablesWithReverseRelations;
  }

  // --- NEW Helper Function: _readTableIndexes ---
  Future<List<SupabaseIndexInfo>> _readTableIndexes(
    String schema,
    String originalTableName,
  ) async {
    if (_connection == null) throw StateError('DB not connected.');
    _logger.fine('Reading indexes for $schema.$originalTableName');
    final indexes = <SupabaseIndexInfo>[];

    try {
      final indexResult = await _connection!.execute(
        Sql.named(r'''
          SELECT
            idx_class.relname AS index_name, -- Index 0: Original index name
            idx.indisunique AS is_unique,    -- Index 1: Uniqueness flag
            -- Aggregate column names and CAST TO TEXT
            array_agg(attr.attname ORDER BY array_position(idx.indkey, attr.attnum))::text AS indexed_columns_text -- Index 2: String representation like {"col1","col2"}
          FROM
            pg_catalog.pg_class tbl_class        -- Represents the table
          JOIN
            pg_catalog.pg_namespace ns ON ns.oid = tbl_class.relnamespace -- Link table to namespace (for schema name)
          JOIN
            pg_catalog.pg_index idx ON idx.indrelid = tbl_class.oid -- Link table to its index definitions
          JOIN
            pg_catalog.pg_class idx_class ON idx_class.oid = idx.indexrelid -- Link index definition to the index relation object (for name)
          -- Need to unnest the array of column attribute numbers (indkey) to join with pg_attribute
          -- Use JOIN LATERAL for clarity or JOIN directly with unnest
          JOIN
            unnest(idx.indkey) WITH ORDINALITY AS key_cols(attnum, ord) ON true -- Create rows for each attribute number in the index key
          JOIN
            pg_catalog.pg_attribute attr ON attr.attrelid = tbl_class.oid AND attr.attnum = key_cols.attnum -- Join attributes based on table and attnum from index key
          WHERE
            ns.nspname = @schema               -- Filter by schema name
            AND tbl_class.relname = @tableName -- Filter by table name
            AND idx_class.relkind = 'i'        -- Ensure we only select index relations
            -- Optional: Exclude primary key indexes if they are handled separately
            -- AND idx.indisprimary = false
          GROUP BY
            idx.indexrelid, -- Group by the specific index OID to aggregate columns correctly
            idx_class.relname,
            idx.indisunique,
            idx.indkey       -- Include indkey because array_position needs it for ordering within array_agg
          ORDER BY
            idx_class.relname; -- Order results by index name
        '''),
        parameters: {'schema': schema, 'tableName': originalTableName},
      );

      for (final row in indexResult) {
        indexes.add(
          SupabaseIndexInfo.fromRow(row, StringUtils.toCamelCase),
        ); // Pass converter
      }
    } catch (e, s) {
      _logger.severe(
        'Failed to read indexes for $schema.$originalTableName: $e\n$s',
      );
      // Return empty list on error or rethrow?
    }
    return indexes;
  }

  /// Reads detailed column information for a specific table.
  ///
  /// Fetches column names, data types, nullability, default values, comments,
  /// primary key status, and unique constraint status.
  /// **Note:** This method focuses *only* on column attributes. Foreign key
  /// constraint details are handled separately by `_readTableForeignKeys`.
  ///
  /// {@tool example}
  /// ```dart
  /// // Assuming 'reader' is connected
  /// try {
  ///   List<ColumnInfo> columns = await reader._readTableColumns('public', 'users');
  ///   // Process basic column info (name, type, pk, unique, etc.)
  /// } catch (e) {
  ///   print('Error reading columns: $e');
  /// }
  /// ```
  /// {@end-tool}
  ///
  /// @param schema The schema name of the table.
  /// @param tableName The name of the table.
  /// @return A [Future] containing a list of [TetherColumnInfo] objects for the table,
  ///         representing individual column properties. Foreign key relationships
  ///         are *not* populated in these objects.
  ///         Example return structure:
  ///         ```json
  ///         [
  ///           {
  ///             "name": "id",
  ///             "type": "uuid",
  ///             "isNullable": false,
  ///             "isPrimaryKey": true,
  ///             "isUnique": true,
  ///             "defaultValue": "gen_random_uuid()",
  ///             "comment": "Primary key for the user."
  ///           },
  ///           {
  ///             "name": "username",
  ///             "type": "text",
  ///             "isNullable": false,
  ///             "isPrimaryKey": false,
  ///             "isUnique": true,
  ///             "defaultValue": null,
  ///             "comment": "User's unique username."
  ///           }
  ///           // ... other columns
  ///         ]
  ///         ```
  /// @throws StateError if the database connection is not initialized.
  /// @throws Exception if the database query fails.
  /// @private Internal helper method.
  Future<List<TetherColumnInfo>> _readTableColumns(
    String schema,
    String tableName,
  ) async {
    if (_connection == null) {
      throw StateError(
        'Database connection not initialized. Call connect() before reading columns.',
      );
    }

    // This query now correctly identifies array types like 'text[]' or 'integer[]'
    // instead of just 'ARRAY'. It also fetches identity column information.
    final result = await _connection!.execute(
      Sql.named(r'''
      SELECT
          c.column_name,
          CASE 
              WHEN c.data_type = 'ARRAY' THEN 
                  ltrim(c.udt_name, '_') || '[]'
              WHEN c.data_type = 'USER-DEFINED' AND c.udt_name = 'geometry' THEN
                  'geometry'
              ELSE 
                  c.data_type 
          END AS data_type,
          c.is_nullable,
          c.column_default,
          d.description,
          (
              SELECT COUNT(tc.constraint_name) > 0
              FROM information_schema.key_column_usage AS kcu
              JOIN information_schema.table_constraints AS tc
              ON kcu.constraint_name = tc.constraint_name
              WHERE kcu.table_schema = c.table_schema 
              AND kcu.table_name = c.table_name
              AND kcu.column_name = c.column_name
              AND tc.constraint_type = 'PRIMARY KEY'
          ) AS is_primary_key,
          (
              SELECT COUNT(tc.constraint_name) > 0
              FROM information_schema.key_column_usage AS kcu
              JOIN information_schema.table_constraints AS tc
              ON kcu.constraint_name = tc.constraint_name
              WHERE kcu.table_schema = c.table_schema 
              AND kcu.table_name = c.table_name
              AND kcu.column_name = c.column_name
              AND tc.constraint_type = 'UNIQUE'
          ) AS is_unique,
          c.is_identity
      FROM information_schema.columns AS c
      LEFT JOIN pg_catalog.pg_statio_all_tables AS st
          ON c.table_schema = st.schemaname AND c.table_name = st.relname
      LEFT JOIN pg_catalog.pg_description AS d
          ON st.relid = d.objoid AND c.ordinal_position = d.objsubid
      WHERE c.table_schema = @schema AND c.table_name = @tableName
      ORDER BY c.ordinal_position;
      '''),
      parameters: {
        'schema': schema,
        'tableName': tableName,
      },
    );

    return result
        .map(
          (row) => TetherColumnInfo.fromRow(row, StringUtils.toCamelCase),
        )
        .toList();
  }

  // --- Helper Function: _readTableForeignKeys ---
  /// Fetches and processes detailed foreign key constraints for a given table.
  /// Converts relevant names to camelCase using the provided converter.
  ///
  /// @param schema The schema name of the table.
  /// @param originalTableName The original database name of the table to query for FKs.
  /// @return A Future resolving to a list of ForeignKeyConstraint objects.
  Future<List<SupabaseForeignKeyConstraint>> _readTableForeignKeys(
    String schema,
    String originalTableName, // Use original name for query
  ) async {
    if (_connection == null) throw StateError('DB not connected.');
    _logger.fine('Reading foreign keys for $schema.$originalTableName');
    final List<SupabaseForeignKeyConstraint> foreignKeys = [];
    try {
      // Query to get detailed foreign key info
      final foreignKeysResult = await _connection!.execute(
        Sql.named(
          'SELECT '
          '  tc.constraint_name, ' // Index 0
          '  kcu.column_name, ' // Index 1 (Local column)
          '  ccu.table_schema AS foreign_table_schema, ' // Index 2
          '  ccu.table_name AS foreign_table_name, ' // Index 3
          '  ccu.column_name AS foreign_column_name, ' // Index 4 (Foreign column)
          '  rc.update_rule, ' // Index 5 (ON UPDATE action)
          '  rc.delete_rule, ' // Index 6 (ON DELETE action)
          '  rc.match_option, ' // Index 7 (MATCH option)
          '  tc.is_deferrable, ' // Index 8 ('YES'/'NO')
          '  tc.initially_deferred ' // Index 9 ('YES'/'NO')
          'FROM information_schema.table_constraints AS tc '
          'JOIN information_schema.key_column_usage AS kcu '
          '  ON tc.constraint_name = kcu.constraint_name AND tc.constraint_schema = kcu.constraint_schema '
          'JOIN information_schema.constraint_column_usage AS ccu '
          '  ON ccu.constraint_name = tc.constraint_name AND ccu.constraint_schema = tc.constraint_schema '
          'JOIN information_schema.referential_constraints AS rc '
          '  ON rc.constraint_name = tc.constraint_name AND rc.constraint_schema = tc.constraint_schema '
          'WHERE tc.constraint_type = \'FOREIGN KEY\' '
          '  AND tc.table_schema = @schema '
          '  AND tc.table_name = @tableName ' // Use parameter name @tableName
          'ORDER BY tc.constraint_name, kcu.ordinal_position',
        ),
        // Pass original names to the query
        parameters: {'schema': schema, 'tableName': originalTableName},
      );

      // Group the raw rows by constraint name
      final groupedFkRows = groupBy<List<dynamic>, String>(
        foreignKeysResult,
        (row) => row[0] as String, // Group by constraint_name (Index 0)
      );

      // Create ForeignKeyConstraint objects from the grouped rows
      groupedFkRows.forEach((constraintName, rows) {
        if (rows.isNotEmpty) {
          // Pass the name converter to the factory
          foreignKeys.add(
            SupabaseForeignKeyConstraint.fromRawRows(
              constraintName,
              rows,
              StringUtils.toCamelCase,
            ),
          );
        }
      });
    } catch (e, s) {
      _logger.severe(
        'Failed to read foreign keys for $schema.$originalTableName: $e\n$s',
      );
      // Return empty list on error or rethrow?
    }
    return foreignKeys;
  }

  // --- Helper Function: _shouldProcessTableBasedOnIncludes ---
  /// Determines if a table should be processed based *only* on include rules
  /// and the generateForAllTables flag. Assumes explicit exclusions were
  /// already handled. Uses original database names for matching.
  ///
  /// @param schema The schema name of the table.
  /// @param originalTableName The original database name of the table.
  /// @return `true` if the table should be processed, `false` otherwise.
  bool _shouldProcessTableBasedOnIncludes(
    String schema,
    String originalTableName,
  ) {
    // 1. Check include list: if it's defined, only includes matter.
    if (config.includeTables.isNotEmpty) {
      // Return true if *any* include pattern matches the original name
      return config.includeTables.any((pattern) {
        final parts = pattern.split('.');
        if (parts.length == 2) {
          // Schema-qualified pattern: match both schema and table name
          return _matchesPattern(schema, parts[0]) &&
              _matchesPattern(originalTableName, parts[1]);
        } else {
          // Simple pattern: match only table name (in any schema)
          return _matchesPattern(originalTableName, pattern);
        }
      });
      // If the loop using .any finishes without returning true, it means no include pattern matched.
      // Since includeTables is not empty, this implies the table should NOT be processed.
    }

    // 2. If include list is empty, rely on the global flag generateForAllTables.
    return config.generateForAllTables;
  }

  /// Matches a string against a simple wildcard pattern (`*`).
  ///
  /// Supports '*' as a wildcard character matching zero or more characters anywhere
  /// within the pattern. Converts the pattern to a regular expression for matching.
  ///
  /// @param text The string to test (e.g., schema or table name).
  /// @param pattern The pattern to match against (e.g., 'public', 'user*', '*').
  /// @return `true` if the text matches the pattern, `false` otherwise.
  ///
  /// {@tool example}
  /// ```dart
  /// _matchesPattern('users', '*')              // -> true
  /// _matchesPattern('users', 'users')          // -> true
  /// _matchesPattern('users', 'user*')          // -> true
  /// _matchesPattern('user_profiles', 'user*')  // -> true
  /// _matchesPattern('posts', 'user*')          // -> false
  /// _matchesPattern('users', 'u*rs')           // -> true
  /// _matchesPattern('users', '*rs')            // -> true
  /// _matchesPattern('users', 'u*')             // -> true
  /// _matchesPattern('users', 'u')              // -> false
  /// _matchesPattern('users', 'users*')         // -> true
  /// ```
  /// {@end-tool}
  /// @private Internal helper method.
  bool _matchesPattern(String text, String pattern) {
    // Simple case: '*' pattern matches everything.
    if (pattern == '*') return true;

    // If the pattern contains a wildcard:
    if (pattern.contains('*')) {
      // Convert the simple wildcard pattern to a RegExp.
      // 1. Escape existing RegExp special characters in the pattern (except '*').
      final safePattern = pattern.replaceAllMapped(
        RegExp(r'[.+?^${}()|[\]\\]'),
        (match) => '\\${match.group(0)}',
      );
      // 2. Replace the wildcard '*' with '.*' (match any char, zero or more times).
      // 3. Anchor the pattern to match the whole string (^ start, $ end).
      final regexPattern = '^${safePattern.replaceAll('*', '.*')}\$';
      final regex = RegExp(regexPattern);
      return regex.hasMatch(text);
    }

    // If no wildcard, perform a direct exact string comparison.
    return text == pattern;
  }
} // End of SchemaReader class
