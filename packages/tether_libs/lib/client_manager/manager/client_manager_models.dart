import 'dart:convert';

import 'package:meta/meta.dart'; // For @immutable
import 'package:sqlite_async/sqlite3_common.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/models/tether_model_input.dart';
import 'package:tether_libs/models/tether_model.dart';

typedef FromJsonFactory<T extends TetherModel<T>> =
    T Function(Map<String, dynamic> json);
typedef FromSqliteFactory<T extends TetherModel<T>> = T Function(Row sqliteRow);

/// Types of queries that can be performed against Supabase.
enum SqlOperationType {
  /// Retrieve data from the database.
  select,

  /// Add new records to the database.
  insert,

  /// Insert or update records based on primary key.
  upsert,

  /// Remove records from the database.
  delete,

  /// Modify existing records in the database.
  update,
}

/// Helper class to track ordering information for Drift and Supabase queries.
///
/// This class stores the column to order by and the ordering preferences.
/// It can be used to generate both Drift and Supabase ordering expressions.
///
/// Example:
/// ```dart
/// final orderTerm = OrderTerm(
///   UserColumn.createdAt,
///   ascending: false,
///   nullsFirst: false,
/// );
/// ```
class OrderTerm {
  /// The Supabase column to order by.
  final TetherColumn column;

  /// Whether the order should be ascending (true) or descending (false).
  final bool ascending;

  /// Whether NULL values should appear first (true) or last (false).
  final bool nullsFirst;

  /// Creates an order term with the specified column and options.
  ///
  /// * [column] - The column to order by
  /// * [ascending] - Whether to sort in ascending order (default: true)
  /// * [nullsFirst] - Whether NULL values should appear first (default: false)
  OrderTerm(this.column, {this.ascending = true, this.nullsFirst = false});

  /// Creates an ascending order term.
  ///
  /// * [column] - The column to order by
  /// * [nullsFirst] - Whether NULL values should appear first (default: false)
  factory OrderTerm.asc(TetherColumn column, {bool nullsFirst = false}) {
    return OrderTerm(column, ascending: true, nullsFirst: nullsFirst);
  }

  /// Creates a descending order term.
  ///
  /// * [column] - The column to order by
  /// * [nullsFirst] - Whether NULL values should appear first (default: false)
  factory OrderTerm.desc(TetherColumn column, {bool nullsFirst = false}) {
    return OrderTerm(column, ascending: false, nullsFirst: nullsFirst);
  }

  /// Creates a Supabase order string for this term.
  ///
  /// Example: "created_at.desc.nullslast"
  String toSupabaseOrderString() {
    final direction = ascending ? 'asc' : 'desc';
    final nulls = nullsFirst ? 'nullsfirst' : 'nullslast';
    return '${column.fullyQualified}.$direction.$nulls';
  }

  @override
  String toString() {
    return 'OrderTerm{column: ${column.fullyQualified}, '
        'ascending: $ascending, nullsFirst: $nullsFirst}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OrderTerm &&
        other.column.fullyQualified == column.fullyQualified &&
        other.ascending == ascending &&
        other.nullsFirst == nullsFirst;
  }

  @override
  int get hashCode =>
      column.fullyQualified.hashCode ^ ascending.hashCode ^ nullsFirst.hashCode;
}

/// Represents the final built SQL string and its arguments.
class FinalSqlStatement {
  final String sql;
  final List<Object?> arguments;

  FinalSqlStatement(this.sql, this.arguments);

  @override
  String toString() => 'SQL: $sql\nArgs: $arguments';
}

/// Represents a structured SQL query being built.
@immutable
class SqlStatement {
  final SqlOperationType operationType;
  final String tableName;

  // SELECT specific
  final String? selectColumns; // e.g., '*', 'col1, col2', 'json_object(...)'
  final String? fromAlias;

  // INSERT specific
  final List<String>? insertColumns;
  final String? insertValuesPlaceholders; // e.g., '(?, ?), (?, ?)'
  final List<Object?>? insertArguments;

  // UPDATE specific
  final List<String>? updateSetClauses; // e.g., ['col1 = ?', 'col2 = ?']
  final List<Object?>? updateArguments; // Arguments for the SET part

  // UPSERT specific
  final String? upsertConflictTarget; // e.g., 'id'
  final String? upsertUpdateSetClauses; // e.g., 'col1 = excluded.col1, ...'
  // Note: Upsert uses insertColumns, insertValuesPlaceholders, insertArguments for the INSERT part

  // DELETE specific (can also use whereClauses)
  // No specific fields needed if using WHERE

  // Common / Filtering / Ordering
  final List<String> whereClauses;
  final List<Object?> whereArguments;
  final String? orderBy; // e.g., 'col1 ASC NULLS LAST'
  final int? limit;
  final int? offset;

  const SqlStatement({
    required this.operationType,
    required this.tableName,
    this.selectColumns,
    this.fromAlias,
    this.insertColumns,
    this.insertValuesPlaceholders,
    this.insertArguments,
    this.updateSetClauses,
    this.updateArguments,
    this.upsertConflictTarget,
    this.upsertUpdateSetClauses,
    this.whereClauses = const [],
    this.whereArguments = const [],
    this.orderBy,
    this.limit,
    this.offset,
  });

  /// Creates a copy of this statement with the given fields replaced.
  SqlStatement copyWith({
    SqlOperationType? operationType,
    String? tableName,
    String? selectColumns,
    String? fromAlias,
    List<String>? insertColumns,
    String? insertValuesPlaceholders,
    List<Object?>? insertArguments,
    List<String>? updateSetClauses,
    List<Object?>? updateArguments,
    String? upsertConflictTarget,
    String? upsertUpdateSetClauses,
    List<String>? whereClauses,
    List<Object?>? whereArguments,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    return SqlStatement(
      operationType: operationType ?? this.operationType,
      tableName: tableName ?? this.tableName,
      selectColumns: selectColumns ?? this.selectColumns,
      fromAlias: fromAlias ?? this.fromAlias,
      insertColumns: insertColumns ?? this.insertColumns,
      insertValuesPlaceholders:
          insertValuesPlaceholders ?? this.insertValuesPlaceholders,
      insertArguments: insertArguments ?? this.insertArguments,
      updateSetClauses: updateSetClauses ?? this.updateSetClauses,
      updateArguments: updateArguments ?? this.updateArguments,
      upsertConflictTarget: upsertConflictTarget ?? this.upsertConflictTarget,
      upsertUpdateSetClauses:
          upsertUpdateSetClauses ?? this.upsertUpdateSetClauses,
      whereClauses: whereClauses ?? this.whereClauses,
      whereArguments: whereArguments ?? this.whereArguments,
      orderBy: orderBy ?? this.orderBy,
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
    );
  }

  /// Builds the final SQL string and collects arguments.
  FinalSqlStatement build() {
    String sql;
    List<Object?> arguments = [];
    final whereClauseSql =
        whereClauses.isNotEmpty ? 'WHERE ${whereClauses.join(' AND ')}' : '';

    switch (operationType) {
      case SqlOperationType.select:
        final select = selectColumns ?? '*';
        final from = fromAlias != null ? '$tableName $fromAlias' : tableName;
        final order = orderBy != null ? 'ORDER BY $orderBy' : '';
        final limitSql = limit != null ? 'LIMIT $limit' : '';
        final offsetSql =
            offset != null && limit != null
                ? 'OFFSET $offset'
                : ''; // Offset requires Limit
        sql =
            'SELECT $select FROM $from $whereClauseSql $order $limitSql $offsetSql'
                .trim()
                .replaceAll(RegExp(r'\s+'), ' ');
        arguments.addAll(whereArguments);
        break;

      case SqlOperationType.insert:
        if (insertColumns == null ||
            insertValuesPlaceholders == null ||
            insertArguments == null) {
          throw StateError('Missing components for INSERT operation.');
        }
        final columnsSql = insertColumns!.join(', ');
        sql =
            'INSERT INTO $tableName ($columnsSql) VALUES $insertValuesPlaceholders';
        arguments.addAll(insertArguments!);
        break;

      case SqlOperationType.update:
        if (updateSetClauses == null || updateArguments == null) {
          throw StateError('Missing components for UPDATE operation.');
        }
        final setSql = updateSetClauses!.join(', ');
        sql = 'UPDATE $tableName SET $setSql $whereClauseSql';
        arguments.addAll(updateArguments!);
        arguments.addAll(whereArguments);
        break;

      case SqlOperationType.delete:
        sql = 'DELETE FROM $tableName $whereClauseSql';
        arguments.addAll(whereArguments);
        break;

      case SqlOperationType.upsert:
        if (insertColumns == null ||
            insertValuesPlaceholders == null ||
            insertArguments == null ||
            upsertConflictTarget == null) {
          throw StateError('Missing components for UPSERT operation.');
        }
        final columnsSql = insertColumns!.join(', ');
        final conflictClause =
            upsertUpdateSetClauses != null && upsertUpdateSetClauses!.isNotEmpty
                ? 'ON CONFLICT($upsertConflictTarget) DO UPDATE SET $upsertUpdateSetClauses'
                : 'ON CONFLICT($upsertConflictTarget) DO NOTHING';
        sql =
            'INSERT INTO $tableName ($columnsSql) VALUES $insertValuesPlaceholders $conflictClause';
        arguments.addAll(insertArguments!);
        // Note: WHERE clause is not typically used in this UPSERT structure.
        break;
    }
    return FinalSqlStatement(sql, arguments);
  }

  @override
  String toString() {
    // Provide a summary for debugging
    return 'SqlStatement(type: $operationType, table: $tableName, where: ${whereClauses.length} clauses, args: ${[...?insertArguments, ...?updateArguments, ...whereArguments].length})';
  }
}

// --- Updated ClientManagerSqlUtils ---


/// Utility class for generating SQLite SQL strings from TetherModels and applying transformations.
class ClientManagerSqlUtils {
/// Generates a structured INSERT statement for a list of models.
  static SqlStatement buildInsertSqlFromModel<TModel extends TetherModel<TModel>>(
    List<TModel> models,
    String tableName,
  ) {
    if (models.isEmpty) {
      throw ArgumentError(
        'Cannot build INSERT statement from empty model list.',
      );
    }
    final firstModelMap = models.first.toSqlite();
    if (firstModelMap.isEmpty) {
      throw ArgumentError(
        'Cannot build INSERT statement: First model has no data.',
      );
    }
    final columns = firstModelMap.keys.toList();
    final columnCount = columns.length;
    final valuePlaceholderGroup =
        '(${List.filled(columnCount, '?').join(', ')})';
    final allPlaceholders = List.filled(
      models.length,
      valuePlaceholderGroup,
    ).join(', ');
    final allArguments = <Object?>[];

    for (final model in models) {
      final map = model.toSqlite();
      if (map.length != columnCount ||
          map.keys.join(',') != columns.join(',')) {
        throw ArgumentError(
          'Inconsistent model structure detected for bulk INSERT.',
        );
      }
      allArguments.addAll(map.values);
    }

    return SqlStatement(
      operationType: SqlOperationType.insert,
      tableName: tableName,
      insertColumns: columns,
      insertValuesPlaceholders: allPlaceholders,
      insertArguments: allArguments,
    );
  }

  /// Generates a structured INSERT statement for a list of models.
  static SqlStatement buildInsertSql<TInput extends TetherModelInput<TInput, TModel>, TModel extends TetherModel<TModel>>(
    List<TInput> models,
    String tableName,
  ) {
    if (models.isEmpty) {
      throw ArgumentError(
        'Cannot build INSERT statement from empty model list.',
      );
    }
    final firstModelMap = models.first.toSqliteMap();
    if (firstModelMap.isEmpty) {
      throw ArgumentError(
        'Cannot build INSERT statement: First model has no data.',
      );
    }
    final columns = firstModelMap.keys.toList();
    final columnCount = columns.length;
    final valuePlaceholderGroup =
        '(${List.filled(columnCount, '?').join(', ')})';
    final allPlaceholders = List.filled(
      models.length,
      valuePlaceholderGroup,
    ).join(', ');
    final allArguments = <Object?>[];

    for (final model in models) {
      final map = model.toSqliteMap();
      if (map.length != columnCount ||
          map.keys.join(',') != columns.join(',')) {
        throw ArgumentError(
          'Inconsistent model structure detected for bulk INSERT.',
        );
      }
      allArguments.addAll(map.values);
    }

    return SqlStatement(
      operationType: SqlOperationType.insert,
      tableName: tableName,
      insertColumns: columns,
      insertValuesPlaceholders: allPlaceholders,
      insertArguments: allArguments,
    );
  }

  /// Generates a structured UPDATE statement for a given model, based on its ID.
  static SqlStatement buildUpdateSql<TInput extends TetherModelInput<TInput, TModel>, TModel extends TetherModel<TModel>>(
    TetherModelInput<TInput, TModel> model,
    String tableName, {
    String idColumnName = 'id',
  }) {
    final map = model.toSqliteMap();
    final idValue = map.remove(idColumnName);

    if (idValue == null) {
      throw ArgumentError(
        'Cannot build UPDATE: ID column "$idColumnName" not found or null.',
      );
    }
    if (map.isEmpty) {
      throw ArgumentError(
        'Cannot build UPDATE: No columns to update (excluding ID).',
      );
    }

    final setClauses = map.keys.map((key) => '$key = ?').toList();
    final updateArgs = map.values.toList();
    final whereClause = '$idColumnName = ?';
    final whereArgs = [idValue];

    return SqlStatement(
      operationType: SqlOperationType.update,
      tableName: tableName,
      updateSetClauses: setClauses,
      updateArguments: updateArgs,
      whereClauses: [whereClause],
      whereArguments: whereArgs,
    );
  }

  /// Generates a structured UPSERT statement for a list of models.
  static SqlStatement buildUpsertSql<T>(
    List<TetherModel<T>> models,
    String tableName, {
    String idColumnName = 'id',
  }) {
    if (models.isEmpty) {
      throw ArgumentError(
        'Cannot build UPSERT statement from empty model list.',
      );
    }
    final firstModelMap = models.first.toSqlite();
    if (firstModelMap.isEmpty) {
      throw ArgumentError('Cannot build UPSERT: First model has no data.');
    }
    if (!firstModelMap.containsKey(idColumnName)) {
      throw ArgumentError(
        'Cannot build UPSERT: ID column "$idColumnName" not found.',
      );
    }

    final columns = firstModelMap.keys.toList();
    final columnCount = columns.length;
    final valuePlaceholderGroup =
        '(${List.filled(columnCount, '?').join(', ')})';
    final allPlaceholders = List.filled(
      models.length,
      valuePlaceholderGroup,
    ).join(', ');
    final allArguments = <Object?>[];

    final updateColumns = columns.where((key) => key != idColumnName).toList();
    final updateSetClauses = updateColumns
        .map((key) => '$key = excluded.$key')
        .join(', ');

    for (final model in models) {
      final map = model.toSqlite();
      if (map.length != columnCount ||
          map.keys.join(',') != columns.join(',')) {
        throw ArgumentError(
          'Inconsistent model structure detected for bulk UPSERT.',
        );
      }
      if (!map.containsKey(idColumnName)) {
        throw ArgumentError(
          'Inconsistent model structure: ID column "$idColumnName" missing.',
        );
      }
      allArguments.addAll(map.values);
    }

    return SqlStatement(
      operationType: SqlOperationType.upsert,
      tableName: tableName,
      insertColumns: columns,
      insertValuesPlaceholders: allPlaceholders,
      insertArguments: allArguments,
      upsertConflictTarget: idColumnName,
      upsertUpdateSetClauses:
          updateSetClauses, // Will be ignored by build() if empty
    );
  }

  /// Generates a structured DELETE statement based on an ID.
  static SqlStatement buildDeleteSql(
    String tableName,
    dynamic idValue, {
    String idColumnName = 'id',
  }) {
    if (idValue == null) {
      throw ArgumentError('Cannot build DELETE: ID value cannot be null.');
    }
    return SqlStatement(
      operationType: SqlOperationType.delete,
      tableName: tableName,
      whereClauses: ['$idColumnName = ?'],
      whereArguments: [idValue],
    );
  }

  /// Generates a structured DELETE statement based on a TetherModel's ID.
  static SqlStatement buildDeleteSqlFromModel<T>(
    TetherModel<T> model,
    String tableName, {
    String idColumnName = 'id',
  }) {
    final idValue = model.toSqlite()[idColumnName];
    if (idValue == null) {
      throw ArgumentError(
        'Cannot build DELETE from model: ID column "$idColumnName" not found or null.',
      );
    }
    return buildDeleteSql(tableName, idValue, idColumnName: idColumnName);
  }

  /// Builds an UPSERT SqlStatement using SupabaseTableInfo for schema details.
  static SqlStatement buildRealtimeUpsertSql(
    List<TetherModel<dynamic>> models,
    String originalSupabaseTableName, // e.g., "users"
    Map<String, SupabaseTableInfo> tableSchemas, // Global schema map
  ) {
    if (models.isEmpty) {
      throw ArgumentError('Cannot build UPSERT: Model list is empty.');
    }
    final schemaKey =
        originalSupabaseTableName.contains('.')
            ? originalSupabaseTableName
            : 'public.$originalSupabaseTableName';

    final tableInfo = tableSchemas[schemaKey];
    if (tableInfo == null) {
      throw Exception(
        "Schema information for table '$schemaKey' not found. Cannot build upsert SQL.",
      );
    }

    final localTableName = tableInfo.localName;

    // Correctly get List<SupabaseColumnInfo> first
    final List<TetherColumnInfo> allColumnInfo = tableInfo.columns;

    // Then map to List<String> for local column names
    final List<String> localColumnNames =
        allColumnInfo.map((ci) => ci.localName).toList();

    if (localColumnNames.isEmpty) {
      throw ArgumentError(
        "Cannot build UPSERT: No local column names derived for table '$localTableName'.",
      );
    }

    // Determine primary keys (Supabase names)
    final pkSupabaseNames = tableInfo.primaryKeys;
    if (pkSupabaseNames.isEmpty) {
      throw ArgumentError(
        "Cannot build UPSERT: No primary keys defined for table '$schemaKey' in SupabaseTableInfo. Conflict target is required.",
      );
    }

    // Convert Supabase primary key names to local primary key names for the conflict target
    final List<String> pkLocalNames =
        pkSupabaseNames.map((supaPkName) {
          final colInfo = supaPkName;
          return colInfo.localName;
        }).toList();

    if (pkLocalNames.isEmpty) {
      throw ArgumentError(
        "Cannot build UPSERT: Could not derive local primary key names for conflict target for table '$localTableName'.",
      );
    }
    final conflictTarget = pkLocalNames.join(', ');

    // For ON CONFLICT DO UPDATE, list columns to update (all local columns except local PKs)
    final updateSetClausesList =
        localColumnNames
            .where((localColName) => !pkLocalNames.contains(localColName))
            .map((localColName) => '$localColName = excluded.$localColName')
            .toList();
    final String? updateSetClausesSql =
        updateSetClausesList.isNotEmpty
            ? updateSetClausesList.join(', ')
            : null; // Results in DO NOTHING if null/empty

    final List<Object?> allArguments = [];
    final valuePlaceholderGroup =
        '(${List.filled(localColumnNames.length, '?').join(', ')})';
    final allPlaceholders = List.filled(
      models.length,
      valuePlaceholderGroup,
    ).join(', ');

    for (final model in models) {
      final modelJson =
          model.toJson(); // Assumes toJson() keys are Supabase column names
      // Iterate based on the order of allColumnInfo to ensure argument order matches localColumnNames
      for (final colInfo in allColumnInfo) {
        var value =
            modelJson[colInfo
                .name]; // Get value using Supabase name from colInfo
        if (value is DateTime) {
          value = value.toIso8601String();
        } else if (value is Map || value is List) {
          if (value != null) {
            value = jsonEncode(value);
          }
        }
        allArguments.add(value);
      }
    }
    if (allArguments.length != localColumnNames.length * models.length) {
      throw StateError(
        "Mismatch in argument count for UPSERT. Expected ${localColumnNames.length * models.length}, got ${allArguments.length}. Check model.toJson() and SupabaseTableInfo consistency.",
      );
    }

    return SqlStatement(
      operationType: SqlOperationType.upsert,
      tableName: localTableName,
      insertColumns: localColumnNames,
      insertValuesPlaceholders: allPlaceholders,
      insertArguments: allArguments,
      upsertConflictTarget: conflictTarget,
      upsertUpdateSetClauses: updateSetClausesSql,
    );
  }

  static SqlStatement buildDeleteSqlByPks(
    String localTableName,
    Map<String, dynamic> primaryKeyValues, // Keys are local column names
  ) {
    if (primaryKeyValues.isEmpty) {
      throw ArgumentError(
        "Primary key values cannot be empty for delete operation.",
      );
    }
    // Assumes primaryKeyValues keys are local column names
    final clauses = primaryKeyValues.keys.map((key) => '$key = ?').toList();
    final args = primaryKeyValues.values.toList();
    return SqlStatement(
      operationType: SqlOperationType.delete,
      tableName: localTableName,
      whereClauses: clauses, // Pass as a list of individual clauses
      whereArguments: args,
    );
  }

  // --- SQL Transformation Methods (Now modify SqlStatement fields) ---

  /// Adds an ORDER BY clause to a SqlStatement. Replaces existing ORDER BY.
  static SqlStatement applyOrder(
    SqlStatement statement,
    TetherColumn column, {
    bool ascending = true,
    bool nullsFirst = false,
  }) {
    if (statement.operationType != SqlOperationType.select) {
      print("Warning: Applying ORDER BY to non-SELECT statement.");
      // Or throw? For now, allow but it might have no effect.
    }
    final direction = ascending ? 'ASC' : 'DESC';
    final nullsHandling = nullsFirst ? 'NULLS FIRST' : 'NULLS LAST';
    final orderByClause = '${column.dbName} $direction $nullsHandling';

    return statement.copyWith(orderBy: orderByClause);
  }

  /// Adds a LIMIT clause to a SqlStatement. Replaces existing LIMIT.
  static SqlStatement applyLimit(SqlStatement statement, int count) {
    if (statement.operationType != SqlOperationType.select) {
      print("Warning: Applying LIMIT to non-SELECT statement.");
    }
    if (count < 0) {
      throw ArgumentError('LIMIT count cannot be negative.');
    }
    return statement.copyWith(limit: count);
  }

  /// Adds LIMIT and OFFSET clauses (for range) to a SqlStatement. Replaces existing.
  static SqlStatement applyRange(SqlStatement statement, int from, int to) {
    if (statement.operationType != SqlOperationType.select) {
      print("Warning: Applying range (LIMIT/OFFSET) to non-SELECT statement.");
    }
    if (from < 0 || to < from) {
      throw ArgumentError(
        'Invalid range: "from" must be non-negative and "to" must be >= "from".',
      );
    }
    final count = to - from + 1;
    return statement.copyWith(limit: count, offset: from);
  }

  /// Adds a WHERE clause to a SqlStatement.
  static SqlStatement applyWhere(
    SqlStatement statement,
    String clause, [
    List<Object?>? arguments,
  ]) {
    // Cannot easily apply WHERE to UPSERT in this structure
    if (statement.operationType == SqlOperationType.upsert) {
      print(
        "Warning: Applying WHERE clause to UPSERT statement is not standard.",
      );
      return statement;
    }
    // Cannot apply WHERE to INSERT
    if (statement.operationType == SqlOperationType.insert) {
      print("Warning: Applying WHERE clause to INSERT statement is invalid.");
      return statement;
    }

    final newClauses = List<String>.from(statement.whereClauses)..add(clause);
    // Correctly handle adding arguments using the cascade operator and addAll
    final newArgs = List<Object?>.from(statement.whereArguments);
    if (arguments != null) {
      newArgs.addAll(arguments); // Use standard addAll method
    }

    return statement.copyWith(
      whereClauses: newClauses,
      whereArguments: newArgs,
    );
  }

  static SqlStatement applySingle(SqlStatement statement) {
    if (statement.operationType != SqlOperationType.select) {
      throw ArgumentError(
        "applySingle can only be used with SELECT statements.",
      );
    }

    return statement.copyWith(limit: 1);
  }
}
