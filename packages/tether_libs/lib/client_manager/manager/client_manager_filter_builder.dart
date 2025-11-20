import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/models/tether_model_input.dart';
import 'client_manager_models.dart';
import 'client_manager_transform_builder.dart';

class ClientManagerFilterBuilder<TModel extends TetherModel<TModel>>
    extends ClientManagerTransformBuilder<TModel> {
  @override
  final PostgrestFilterBuilder<dynamic> supabase;

  // Assuming _logger is inherited or defined in ClientManagerBase
  // If not, add: final Logger _logger = Logger('ClientManagerFilterBuilder');

  final Logger _logger;
  @override
  final TetherModelInputBase? updatePayload;

  ClientManagerFilterBuilder({
    required super.tableName,
    required super.localDb,
    required super.client,
    required this.supabase,
    required super.localTableName,
    required super.tableSchemas,
    required super.fromJsonFactory,
    required super.fromSqliteFactory,
    required super.baseSupabase,
    super.type,
    super.selector,
    // --- Pass SqlStatement to super ---
    required super.localQuery, // Renamed in base class, adjust if needed
    super.selectorStatement,
    this.updatePayload,
  })  : _logger = Logger('filter_builder'),
        super(supabase: supabase);

  // Helper to create a new instance with updated state (immutable approach)
  ClientManagerFilterBuilder<TModel> _copyWithFilter({
    PostgrestFilterBuilder<dynamic>? supabaseBuilder,
    // --- MODIFIED: Accept updated SqlStatement ---
    SqlStatement? localQuery, // Renamed in base class, adjust if needed
  }) {
    return ClientManagerFilterBuilder(
      tableName: tableName,
      localTableName: localTableName,
      localDb: localDb,
      client: client,
      supabase: supabaseBuilder ?? supabase,
      baseSupabase: baseSupabase,
      type: type,
      selector: selector,
      selectorStatement: selectorStatement,
      fromJsonFactory: fromJsonFactory,
      fromSqliteFactory: fromSqliteFactory,
      tableSchemas: tableSchemas,
      // --- Pass updated state ---
      localQuery: localQuery ?? this.localQuery,
      updatePayload: updatePayload,
    );
  }

  // --- Filter Implementations using ClientManagerSqlUtils.applyWhere ---

  (String, List<Object?>)? _buildLocalFilterClause(
    TetherColumn column,
    String op,
    Object? value,
  ) {
    if (localQuery == null) {
      // This is the new entry point for building an UPDATE query
      if (type == SqlOperationType.update && updatePayload != null) {
        final map = updatePayload!.toSqliteMap();
        final setClauses = map.keys.map((key) => '$key = ?').toList();
        final updateArgs = map.values.toList();

        localQuery = SqlStatement(
          operationType: SqlOperationType.update,
          tableName: localTableName,
          updateSetClauses: setClauses,
          updateArguments: updateArgs,
        );
      } else if (type == SqlOperationType.delete) {
        localQuery = SqlStatement(
          operationType: SqlOperationType.delete,
          tableName: localTableName,
        );
      } else {
        _logger.warning("Cannot build filter clause: localQuery is null and operation is not update/delete.");
        return null;
      }
    }

    final primaryTableName = selectorStatement?.currentTableInfo.originalName;

    if (column.tableName == primaryTableName) {
      // --- Filter on PRIMARY table ---
      final aliasedColumn = column.withAlias(localQuery!.fromAlias);
      final clause = '${aliasedColumn.dbName} $op ?';
      return (clause, [value]);
    } else {
      // --- Filter on RELATED table ---
      if (selectorStatement == null) {
        _logger.severe(
            "Cannot filter on related table '${column.tableName}': selectorStatement is null.");
        return null;
      }
      // 1. Find the relationship in the selectorStatement.
      final relationLink = selectorStatement!
          .supabaseRelatedBuilders.values
          .firstWhereOrNull((link) =>
              link.builder.currentTableInfo.originalName == column.tableName);

      if (relationLink == null) {
        _logger.severe(
            "Cannot apply filter on '${column.tableName}.${column.originalName}': No relation found from '$primaryTableName' in the current select statement.");
        return null;
      }

      // 2. Determine join keys from the FK constraint.
      final fkConstraintName = relationLink.fkConstraintName;
      final primaryTableInfo = selectorStatement!.currentTableInfo;
      final relatedTableInfo = relationLink.builder.currentTableInfo;

      SupabaseForeignKeyConstraint? fkConstraint;
      String localJoinColumn = '';
      String relatedJoinColumn = '';

      // Scenario A: FK is on the primary table (e.g., stash.products_id -> products.id)
      fkConstraint = primaryTableInfo.foreignKeys.firstWhereOrNull((fk) =>
          fk.constraintName == fkConstraintName &&
          fk.originalForeignTableName == relatedTableInfo.originalName);
      if (fkConstraint != null) {
        localJoinColumn = fkConstraint.originalColumns.first;
        relatedJoinColumn = fkConstraint.originalForeignColumns.first;
      } else {
        // Scenario B: FK is on the related table (e.g., comments.post_id -> posts.id)
        fkConstraint = relatedTableInfo.foreignKeys.firstWhereOrNull((fk) =>
            fk.constraintName == fkConstraintName &&
            fk.originalForeignTableName == primaryTableInfo.originalName);
        if (fkConstraint != null) {
          if (primaryTableInfo.primaryKeys.isEmpty) {
            _logger.severe(
                "Cannot form reverse relationship for filter: Primary table '${primaryTableInfo.originalName}' has no primary keys defined.");
            return null;
          }
          localJoinColumn =
              primaryTableInfo.primaryKeys.first.originalName; // PK of primary table
          relatedJoinColumn =
              fkConstraint.originalColumns.first; // FK on related table
        }
      }

      if (fkConstraint == null) {
        _logger.severe(
            "Could not resolve FK constraint '$fkConstraintName' to apply filter on '${column.tableName}'.");
        return null;
      }

      // 3. Build the EXISTS clause.
      final clause =
          'EXISTS (SELECT 1 FROM "${relatedTableInfo.originalName}" WHERE "${relatedTableInfo.originalName}"."$relatedJoinColumn" = ${localQuery!.fromAlias}."$localJoinColumn" AND "${relatedTableInfo.originalName}"."${column.originalName}" $op ?)';

      return (clause, [value]);
    }
  }

  /// Finds all rows whose value on the stated [column] matches the specified [value].
  ClientManagerFilterBuilder<TModel> eq(TetherColumn column, Object value) {
    final newSupabaseBuilder =
        supabase.eq(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery;

    final filterParts = _buildLocalFilterClause(column, '=', value);
    if (filterParts != null) {
      // If localQuery was null, _buildLocalFilterClause has initialized it.
      // We must use the instance member `localQuery` which has been updated.
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!, filterParts.$1, filterParts.$2);
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value on the stated [column] does not match the specified [value].
  ClientManagerFilterBuilder<TModel> neq(TetherColumn column, Object value) {
    final newSupabaseBuilder = supabase.neq(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      final clause = '${aliasedColumn.dbName} != ?'; // Or <>
      final args = [value];
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
        localQuery!,
        clause,
        args,
      );
    } else {
      _logger.warning("Cannot apply 'neq' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value on the stated [column] is greater than the specified [value].
  ClientManagerFilterBuilder<TModel> gt(TetherColumn column, Object value) {
    final newSupabaseBuilder =
        supabase.gt(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery;

    final filterParts = _buildLocalFilterClause(column, '>', value);
    if (filterParts != null) {
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!, filterParts.$1, filterParts.$2);
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value on the stated [column] is greater than or equal to the specified [value].
  ClientManagerFilterBuilder<TModel> gte(TetherColumn column, Object value) {
    final newSupabaseBuilder =
        supabase.gte(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery;

    final filterParts = _buildLocalFilterClause(column, '>=', value);
    if (filterParts != null) {
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!, filterParts.$1, filterParts.$2);
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value on the stated [column] is less than the specified [value].
  ClientManagerFilterBuilder<TModel> lt(TetherColumn column, Object value) {
    final newSupabaseBuilder =
        supabase.lt(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery;

    final filterParts = _buildLocalFilterClause(column, '<', value);
    if (filterParts != null) {
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!, filterParts.$1, filterParts.$2);
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value on the stated [column] is less than or equal to the specified [value].
  ClientManagerFilterBuilder<TModel> lte(TetherColumn column, Object value) {
    final newSupabaseBuilder =
        supabase.lte(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery;

    final filterParts = _buildLocalFilterClause(column, '<=', value);
    if (filterParts != null) {
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!, filterParts.$1, filterParts.$2);
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value in the stated [column] matches the supplied [pattern].
  ClientManagerFilterBuilder<TModel> like(TetherColumn column, String pattern) {
    final newSupabaseBuilder = supabase.like(column.fullyQualified(tableName), pattern);
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      final clause = '${aliasedColumn.dbName} LIKE ?';
      final args = [pattern];
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
        localQuery!,
        clause,
        args,
      );
    } else {
      _logger.warning("Cannot apply 'like' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value in the stated [column] matches the supplied [pattern] case-insensitively.
  ClientManagerFilterBuilder<TModel> ilike(
    TetherColumn column,
    String pattern,
  ) {
    final newSupabaseBuilder = supabase.ilike(column.fullyQualified(tableName), pattern);
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      // SQLite LIKE is typically case-insensitive by default
      final clause = '${aliasedColumn.dbName} LIKE ?';
      final args = [pattern];
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
        localQuery!,
        clause,
        args,
      );
    } else {
      _logger.warning("Cannot apply 'ilike' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// A check for exact equality (null, true, false).
  ClientManagerFilterBuilder<TModel> isFilter(
    TetherColumn column,
    bool? value,
  ) {
    final newSupabaseBuilder = supabase.isFilter(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      String clause;
      List<Object?> args;
      if (value == null) {
        clause = '${aliasedColumn.dbName} IS NULL';
        args = [];
      } else {
        // SQLite stores booleans as 0 (false) or 1 (true)
        clause = '${aliasedColumn.dbName} = ?';
        args = [value ? 1 : 0];
      }
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
        localQuery!,
        clause,
        args,
      );
    } else {
      _logger.warning("Cannot apply 'is' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose value on the stated [column] is found on the specified [values].
  ClientManagerFilterBuilder<TModel> inFilter(
    TetherColumn column,
    List values,
  ) {
    final newSupabaseBuilder = supabase.inFilter(column.fullyQualified(tableName), values);
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      String clause;
      List<Object?> args;
      if (values.isEmpty) {
        // Handle empty list case to avoid invalid SQL "IN ()" -> match nothing
        clause = '1 = 0'; // Always false
        args = [];
      } else {
        final placeholders = List.filled(values.length, '?').join(', ');
        clause = '${aliasedColumn.dbName} IN ($placeholders)';
        args = values;
      }
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
        localQuery!,
        clause,
        args,
      );
    } else {
      _logger.warning("Cannot apply 'in' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  // --- Array/JSON/Range Filters (Basic Implementations/Placeholders) ---

  /// Finds all rows whose json/text value on the stated [column] contains the specified [value].
  ClientManagerFilterBuilder<TModel> contains(
    TetherColumn column,
    Object value,
  ) {
    final newSupabaseBuilder = supabase.contains(column.fullyQualified(tableName), value);
    SqlStatement? newlocalQuery = localQuery; // Start with current state
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      // Basic string contains using LIKE
      if (value is String) {
        final clause = "${aliasedColumn.dbName} LIKE ?";
        final args = ['%$value%'];
        newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!,
          clause,
          args,
        );
      } else {
        // TODO: Implement proper JSON contains using json_extract or json_each
        _logger.warning(
          "SQLite 'contains' filter not fully implemented for non-string types in $localTableName.${column.dbName}.",
        );
      }
    } else {
      _logger.warning("Cannot apply 'contains' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose json/text value on the stated [column] is contained by the specified [value].
  ClientManagerFilterBuilder<TModel> containedBy(
    TetherColumn column,
    Object value,
  ) {
    final newSupabaseBuilder = supabase.containedBy(
      column.fullyQualified(tableName),
      value,
    );
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      // Basic string contained by using LIKE
      if (value is String) {
        final clause = "? LIKE '%' || ${aliasedColumn.dbName} || '%'";
        final args = [value];
        newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!,
          clause,
          args,
        );
      } else {
        // TODO: Implement proper JSON containedBy
        _logger.warning(
          "SQLite 'containedBy' filter not fully implemented for non-string types in $localTableName.${column.dbName}.",
        );
      }
    } else {
      _logger.warning("Cannot apply 'containedBy' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  // --- Range Filters (Not directly supported in SQLite standard SQL) ---
  // These would require specific schema (e.g., start/end columns) or extensions

  ClientManagerFilterBuilder<TModel> rangeLt(
    TetherColumn column,
    String range,
  ) {
    final newSupabaseBuilder = supabase.rangeLt(column.fullyQualified(tableName), range);
    _logger.warning(
      "SQLite 'rangeLt' filter not implemented for $localTableName.${column.dbName}.",
    );
    // No change to localQuery
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: localQuery,
    );
  }

  ClientManagerFilterBuilder<TModel> rangeGt(
    TetherColumn column,
    String range,
  ) {
    final newSupabaseBuilder = supabase.rangeGt(column.fullyQualified(tableName), range);
    _logger.warning(
      "SQLite 'rangeGt' filter not implemented for $localTableName.${column.dbName}.",
    );
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: localQuery,
    );
  }

  ClientManagerFilterBuilder<TModel> rangeGte(
    TetherColumn column,
    String range,
  ) {
    final newSupabaseBuilder = supabase.rangeGte(column.fullyQualified(tableName), range);
    _logger.warning(
      "SQLite 'rangeGte' filter not implemented for $localTableName.${column.dbName}.",
    );
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: localQuery,
    );
  }

  ClientManagerFilterBuilder<TModel> rangeLte(
    TetherColumn column,
    String range,
  ) {
    final newSupabaseBuilder = supabase.rangeLte(column.fullyQualified(tableName), range);
    _logger.warning(
      "SQLite 'rangeLte' filter not implemented for $localTableName.${column.dbName}.",
    );
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: localQuery,
    );
  }

  ClientManagerFilterBuilder<TModel> rangeAdjacent(
    TetherColumn column,
    String range,
  ) {
    final newSupabaseBuilder = supabase.rangeAdjacent(
      column.fullyQualified(tableName),
      range,
    );
    _logger.warning(
      "SQLite 'rangeAdjacent' filter not implemented for $localTableName.${column.dbName}.",
    );
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: localQuery,
    );
  }

  /// Finds all rows whose array/range value overlaps. Basic string implementation.
  ClientManagerFilterBuilder<TModel> overlaps(
    TetherColumn column,
    Object value,
  ) {
    final newSupabaseBuilder = supabase.overlaps(column.fullyQualified(tableName), value);
    // TODO: Implement proper array/range overlap for SQLite (complex)
    _logger.warning(
      "SQLite 'overlaps' filter not implemented for $localTableName.${column.dbName}.",
    );
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: localQuery,
    );
  }

  // --- Full Text Search ---

  /// Finds all rows matching the FTS query. Requires an FTS table (e.g., FTS5).
  ClientManagerFilterBuilder<TModel> textSearch(
    TetherColumn column,
    String query, {
    String? config, // config is PostgreSQL specific, ignored for SQLite
    TextSearchType? type, // type is PostgreSQL specific, ignored for SQLite
  }) {
    final newSupabaseBuilder = supabase.textSearch(
      column.fullyQualified(tableName),
      query,
      config: config,
      type: type,
    );
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.tableAlias);
      // Assumes the local table is an FTS table (e.g., FTS5) and the column is indexed.
      // The column name in MATCH might be the table name itself for FTS5. Check your FTS setup.
      // Using column.dbName assumes the column *is* the FTS indexed column.
      final clause = '${aliasedColumn.dbName} MATCH ?';
      final args = [query]; // Use the FTS query string directly
      newlocalQuery = ClientManagerSqlUtils.applyWhere(
        localQuery!,
        clause,
        args,
      );
    } else {
      _logger.warning("Cannot apply 'textSearch' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  // --- Logical Operators ---

  /// Finds all rows which don't satisfy the filter.
  ///
  /// This now supports direct negation of operators like 'eq', 'gt', 'lt', etc.,
  /// and handles list values to generate a 'NOT IN' clause.
  ///
  /// Example:
  /// ```dart
  /// // Generates: status != 'COMPLETED'
  /// .not('status', 'eq', 'COMPLETED')
  ///
  /// // Generates: id NOT IN (1, 2, 3)
  /// .not('id', 'in', [1, 2, 3])
  /// ```
  ClientManagerFilterBuilder<TModel> not(
    TetherColumn column,
    String operator,
    Object? value,
  ) {
    final newSupabaseBuilder = supabase.not(
      column.fullyQualified(tableName),
      operator,
      value,
    );

    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      String? clause;
      List<Object?>? args;
      bool applied = false;

      // Handle list values for 'in' -> 'NOT IN'
      if (value is List) {
        if (operator.toLowerCase() == 'in') {
          if (value.isEmpty) {
            // NOT IN an empty list is always true, so it doesn't filter anything.
            // We can just return the current state without adding a clause.
            return _copyWithFilter(supabaseBuilder: newSupabaseBuilder);
          }
          final placeholders = List.filled(value.length, '?').join(', ');
          clause = '${aliasedColumn.dbName} NOT IN ($placeholders)';
          args = value;
          applied = true;
        } else {
          _logger.warning(
            "SQLite 'not' filter with a List value is only supported for the 'in' operator.",
          );
        }
      } else if (operator.toLowerCase() == 'is') {
        // Handle 'is' operator specifically for 'IS NOT'
        if (value == null) {
          clause = '${aliasedColumn.dbName} IS NOT NULL';
          args = [];
          applied = true;
        } else if (value is bool) {
          // 'IS NOT TRUE'  -> column != 1
          // 'IS NOT FALSE' -> column != 0
          clause = '${aliasedColumn.dbName} != ?';
          args = [value ? 1 : 0];
          applied = true;
        } else {
          _logger.warning(
            "SQLite 'not is' filter only supports null, true, or false.",
          );
        }
      } else {
        // Handle negation of other operators
        final oppositeOperator = _getOppositeOperator(operator);
        if (oppositeOperator != null) {
          // If we have a direct opposite, just use the existing filter logic for that.
          // This is safer and avoids manual clause construction.
          return filter(column, oppositeOperator, value);
        } else {
          // Fallback for operators without a simple opposite (like 'like')
          _logger.warning(
            "SQLite 'not' filter for operator '$operator' is basic and may require manual parentheses for complex cases.",
          );
          final filterResult = filter(column, operator, value);
          if (filterResult.localQuery != localQuery &&
              filterResult.localQuery!.whereClauses.isNotEmpty) {
            final lastClause = filterResult.localQuery!.whereClauses.last;
            final modifiedClauses = List<String>.from(
              filterResult.localQuery!.whereClauses.sublist(
                0,
                filterResult.localQuery!.whereClauses.length - 1,
              ),
            );
            modifiedClauses.add('NOT ($lastClause)');
            newlocalQuery = filterResult.localQuery!.copyWith(
              whereClauses: modifiedClauses,
            );
            applied = true;
          }
        }
      }

      if (applied && clause != null) {
        newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!,
          clause,
          args,
        );
      } else if (!applied) {
        _logger.warning(
          "'not' filter could not be applied for operator '$operator' on $localTableName.${column.dbName}.",
        );
      }
    } else {
      _logger.warning("Cannot apply 'not' filter: localQuery is null.");
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Returns the logical opposite of a given PostgREST filter operator.
  String? _getOppositeOperator(String operator) {
    switch (operator.toLowerCase()) {
      case 'eq':
        return 'neq';
      case 'neq':
        return 'eq';
      case 'gt':
        return 'lte';
      case 'gte':
        return 'lt';
      case 'lt':
        return 'gte';
      case 'lte':
        return 'gt';
      // Operators like 'like', 'ilike', 'is' don't have simple opposites
      default:
        return null;
    }
  }

  /// Finds all rows satisfying at least one of the filters.
  /// NOTE: SQLite implementation requires parsing the filter string or a different API.
  ClientManagerFilterBuilder<TModel> or(
    String filters, {
    String? referencedTable,
  }) {
    final newSupabaseBuilder = supabase.or(
      filters,
      referencedTable: referencedTable,
    );
    // TODO: Implement SQLite 'or'. Requires parsing the 'filters' string
    // or changing the API to accept multiple conditions programmatically.
    _logger.warning(
      "SQLite 'or' filter not implemented. Filter string: '$filters'",
    );
    // No change to localQuery
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: localQuery,
    );
  }

  // --- Generic Filters ---

  /// Finds all rows whose [column] satisfies the filter. Maps PostgREST operators.
  ClientManagerFilterBuilder<TModel> filter(
    TetherColumn column,
    String operator,
    Object? value,
  ) {
    final newSupabaseBuilder = supabase.filter(
      column.fullyQualified(tableName),
      operator,
      value,
    );

    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      final aliasedColumn = column.withAlias(selectorStatement?.getAliasForTable(column.tableName));
      // Map PostgREST operators to SQLite
      String? clause;
      List<Object?>? args;
      bool applied = false; // Flag if mapping was successful

      switch (operator.toLowerCase()) {
        case 'eq':
          clause = '${aliasedColumn.dbName} = ?';
          args = [value];
          applied = true;
          break;
        case 'neq':
          clause = '${aliasedColumn.dbName} != ?';
          args = [value];
          applied = true;
          break;
        case 'gt':
          clause = '${aliasedColumn.dbName} > ?';
          args = [value];
          applied = true;
          break;
        case 'gte':
          clause = '${aliasedColumn.dbName} >= ?';
          args = [value];
          applied = true;
          break;
        case 'lt':
          clause = '${aliasedColumn.dbName} < ?';
          args = [value];
          applied = true;
          break;
        case 'lte':
          clause = '${aliasedColumn.dbName} <= ?';
          args = [value];
          applied = true;
          break;
        case 'like':
          clause = '${aliasedColumn.dbName} LIKE ?';
          args = [value];
          applied = true;
          break;
        case 'ilike': // SQLite LIKE is often case-insensitive
          clause = '${aliasedColumn.dbName} LIKE ?';
          args = [value];
          applied = true;
          break;
        case 'is':
          if (value == null) {
            clause = '${aliasedColumn.dbName} IS NULL';
            args = [];
            applied = true;
          } else if (value is bool) {
            clause = '${aliasedColumn.dbName} = ?';
            args = [value ? 1 : 0];
            applied = true;
          } else {
            _logger.warning(
              "SQLite 'is' filter only supports null, true, false for $localTableName.${column.dbName}.",
            );
          }
          break;
        case 'in':
          if (value is List && value.isNotEmpty) {
            final placeholders = List.filled(value.length, '?').join(', ');
            clause = '${aliasedColumn.dbName} IN ($placeholders)';
            args = value;
            applied = true;
          } else if (value is List && value.isEmpty) {
            clause = '1 = 0'; // Always false for empty IN list
            args = [];
            applied = true;
          } else {
            _logger.warning(
              "SQLite 'in' filter requires a List value for $localTableName.${column.dbName}.",
            );
          }
          break;
        // Add other operators as needed (cs, cd, sl, sr, nxr, nxl, adj, ov, fts)
        case 'fts':
        case 'plfts':
        case 'phfts':
        case 'wfts':
          // Assumes FTS setup
          clause = '${aliasedColumn.dbName} MATCH ?';
          args = [value];
          applied = true;
          break;
        default:
          _logger.warning(
            "SQLite filter mapping not implemented for operator '$operator' on $localTableName.${column.dbName}.",
          );
      }

      if (applied && clause != null) {
        newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!,
          clause,
          args,
        );
      }
    } else {
      _logger.warning("Cannot apply 'filter' ($operator): localQuery is null.");
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Finds all rows whose columns match the specified [query] object (equality).
  ClientManagerFilterBuilder<TModel> match(Map<String, Object> query) {
    // Supabase builder requires simple keys, handle qualification manually for local
    final newSupabaseBuilder = supabase.match(query);

    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      if (query.isNotEmpty) {
        final clauses = <String>[];
        final args = <Object?>[];
        query.forEach((key, value) {
          // For local queries, we must use the aliased column name.
          // This assumes the key in the map corresponds to a column in the current table.
          // A more robust solution might involve looking up the TetherColumn object.
          // For now, we construct it assuming the key is the originalName.
          final aliasedColumn = RelatedColumnRef(key, key, key.contains('.') ? key.split('.').first : tableName, null)
              .withAlias(selectorStatement?.tableAlias);
          clauses.add('${aliasedColumn.dbName} = ?');
          args.add(value);
        });
        // Apply all match conditions as a single ANDed clause group
        final combinedClause = '(${clauses.join(' AND ')})';
        newlocalQuery = ClientManagerSqlUtils.applyWhere(
          localQuery!,
          combinedClause,
          args,
        );
      }
      // If query is empty, no change to local state
    } else {
      _logger.warning("Cannot apply 'match' filter: localQuery is null.");
    }

    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  // --- Multi-pattern LIKE/ILIKE ---
  // Helper for LIKE/ILIKE Any/All
  SqlStatement _buildLikeAnyAllLocal(
    SqlStatement currentState,
    TetherColumn column,
    List<String> patterns,
    String joinOperator,
  ) {
    // No null check needed for currentState here, as it's called internally after check
    if (patterns.isEmpty) {
      _logger.warning(
        "LIKE Any/All called with empty patterns list for $localTableName.${column.dbName}.",
      );
      // Return condition that matches nothing if AND, everything if OR?
      // For simplicity, let's add a clause that's always false for AND, true for OR.
      final clause = joinOperator == 'AND' ? '1 = 0' : '1 = 1';
      return ClientManagerSqlUtils.applyWhere(currentState, clause);
    }
    final aliasedColumn = column.withAlias(selectorStatement?.tableAlias);
    final clauses = patterns.map((_) => '${aliasedColumn.dbName} LIKE ?').toList();
    final combinedClause = '(${clauses.join(' $joinOperator ')})';
    final args = patterns;
    return ClientManagerSqlUtils.applyWhere(currentState, combinedClause, args);
  }

  /// Match only rows where [column] matches all of [patterns] case-sensitively.
  ClientManagerFilterBuilder<TModel> likeAllOf(
    TetherColumn column,
    List<String> patterns,
  ) {
    final newSupabaseBuilder = supabase.likeAllOf(
      column.fullyQualified(tableName),
      patterns,
    );
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      // Assumes default SQLite LIKE insensitivity, so same as ilikeAllOf
      newlocalQuery = _buildLikeAnyAllLocal(
        localQuery!,
        column,
        patterns,
        'AND',
      );
    } else {
      _logger.warning("Cannot apply 'likeAllOf' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Match only rows where [column] matches any of [patterns] case-sensitively.
  ClientManagerFilterBuilder<TModel> likeAnyOf(
    TetherColumn column,
    List<String> patterns,
  ) {
    final newSupabaseBuilder = supabase.likeAnyOf(
      column.fullyQualified(tableName),
      patterns,
    );
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      // Assumes default SQLite LIKE insensitivity, so same as ilikeAnyOf
      newlocalQuery = _buildLikeAnyAllLocal(
        localQuery!,
        column,
        patterns,
        'OR',
      );
    } else {
      _logger.warning("Cannot apply 'likeAnyOf' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Match only rows where [column] matches all of [patterns] case-insensitively.
  ClientManagerFilterBuilder<TModel> ilikeAllOf(
    TetherColumn column,
    List<String> patterns,
  ) {
    final newSupabaseBuilder = supabase.ilikeAllOf(
      column.fullyQualified(tableName),
      patterns,
    );
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      newlocalQuery = _buildLikeAnyAllLocal(
        localQuery!,
        column,
        patterns,
        'AND',
      );
    } else {
      _logger.warning("Cannot apply 'ilikeAllOf' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }

  /// Match only rows where [column] matches any of [patterns] case-insensitively.
  ClientManagerFilterBuilder<TModel> ilikeAnyOf(
    TetherColumn column,
    List<String> patterns,
  ) {
    final newSupabaseBuilder = supabase.ilikeAnyOf(
      column.fullyQualified(tableName),
      patterns,
    );
    SqlStatement? newlocalQuery = localQuery;
    if (localQuery != null) {
      newlocalQuery = _buildLikeAnyAllLocal(
        localQuery!,
        column,
        patterns,
        'OR',
      );
    } else {
      _logger.warning("Cannot apply 'ilikeAnyOf' filter: localQuery is null.");
    }
    return _copyWithFilter(
      supabaseBuilder: newSupabaseBuilder,
      localQuery: newlocalQuery,
    );
  }
}
