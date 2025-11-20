import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:logging/logging.dart';
import 'package:tether_libs/client_manager/manager/client_manager_models.dart';
import 'package:tether_libs/models/table_info.dart';

// The generator will add the correct import to the generated
// supabase_select_builders.dart file.
// For SupabaseSelectBuilderBase itself, if it needs to run independently
// or in tests without full generation, this import might be tricky.
// However, since it's an abstract class used by generated code,
// the generated code will have the correct context.
// We assume `globalSupabaseSchema` will be accessible in the context
// where SupabaseSelectBuilderBase's constructor is called (i.e., from generated builders).

/// Represents a link to a related [SelectBuilderBase] for constructing nested queries.
///
/// This class holds a [builder] for the related table, the [fkConstraintName]
/// that defines the relationship, and a flag [innerJoin] to specify if an
/// inner join should be used (relevant for Supabase PostgREST queries).
class RelatedBuilderLink extends Equatable {
  /// The [SelectBuilderBase] for the related table.
  final SelectBuilderBase builder;

  /// The name of the foreign key constraint that establishes this link.
  /// This is crucial for PostgREST to correctly identify the relationship.
  final String fkConstraintName;

  /// If `true`, an inner join hint (`!inner`) is added to the PostgREST query,
  /// ensuring that rows from the parent table are only returned if a matching
  /// row exists in the related table. Defaults to `false`.
  final bool innerJoin;

  /// Creates a [RelatedBuilderLink].
  ///
  /// - `builder`: The select builder for the related table.
  /// - `fkConstraintName`: The name of the FK constraint defining the relationship.
  /// - `innerJoin`: Whether to perform an inner join (defaults to `false`).
  const RelatedBuilderLink({
    required this.builder,
    required this.fkConstraintName,
    this.innerJoin = false,
  });

  @override
  List<Object?> get props => [builder, fkConstraintName, innerJoin];
}

/// An interface representing a database column, used by generated Supabase builders.
///
/// This abstraction allows for type-safe column references in queries and provides
/// various name formats (original, local, qualified) for different contexts.
/// Implementations are typically generated enums or classes for each table.
///
/// Example (conceptual generated enum):
/// ```dart
/// enum UsersColumn implements SupabaseColumn {
///   id('id', 'id', 'users'),
///   email('email', 'email', 'users'),
///   createdAt('created_at', 'createdAt', 'users');
///
///   // ... SupabaseColumn implementation ...
/// }
/// ```
abstract class TetherColumn {
  String get originalName;
  String get localName;
  String get tableName;
  String? get relationshipPrefix;

  /// Creates a new column reference with a table alias.
  TetherColumn withAlias(String? alias);

  String get dbName =>
      tableAlias != null ? '$tableAlias."$originalName"' : '"$originalName"';
  String get dartName;
  String? get tableAlias;

  /// The column name qualified with its base table name (e.g., 'users.id').
  /// Useful for disambiguating columns in SQL joins.
  String get qualified => '$tableName.$originalName';

  /// The fully qualified column name, potentially including a [relationshipPrefix].
  /// This is the name that should be used in filters (e.g., `eq(PostsColumn.userId, 1)`
  /// might translate to a filter on 'user_id' or 'posts.user_id' or 'author.id'
  /// depending on context and prefix).
  ///
  /// If `relationshipPrefix` is set, it returns `'relationshipPrefix.dbName'`.
  /// Otherwise, it returns `dbName`.
  String fullyQualified(String? prefix) {

    if (prefix == tableName) {
      // If the prefix is the same as the table name, we don't need to add it.
      return dbName;
    } else if (prefix != null && prefix.isNotEmpty) {
      // If a prefix is provided, use it to qualify the column name.
      return '$tableName.$originalName';
    }

    return relationshipPrefix != null ? '$relationshipPrefix.$dbName' : dbName;
  }

  /// Creates a new [TetherColumn] instance that represents this column
  /// as accessed through a named relationship.
  ///
  /// This is used to build up path-like references for deeply nested filters
  /// or selections in PostgREST.
  ///
  /// - `relationshipName`: The name of the relationship (e.g., the JSON key used
  ///   in `addSupabaseRelated` or a foreign key table name).
  ///
  /// Returns a new [TetherColumn] (typically a [RelatedColumnRef]) with the
  /// `relationshipPrefix` set.
  TetherColumn related(String relationshipName);
}

class RelatedColumnRef implements TetherColumn {
  @override
  final String originalName;
  @override
  final String localName;
  @override
  final String tableName;
  @override
  final String? relationshipPrefix;
  @override
  final String? tableAlias;

  const RelatedColumnRef(
    this.originalName,
    this.localName,
    this.tableName,
    this.relationshipPrefix, {
    this.tableAlias,
  });

  @override
  String get dartName => localName;

  @override
  String get dbName =>
      tableAlias != null ? '$tableAlias."$originalName"' : '"$originalName"';

  @override
  String get qualified => '$tableName.$originalName';

  @override
  String fullyQualified(String? prefix) {
    if (prefix == tableName) {
      return dbName;
    } else if (prefix != null && prefix.isNotEmpty) {
      return '$prefix.$dbName';
    }
    return relationshipPrefix != null ? '$relationshipPrefix.$dbName' : dbName;
  }

  @override
  TetherColumn related(String relationshipName) {
    return RelatedColumnRef(
      originalName,
      localName,
      tableName,
      relationshipName,
      tableAlias: tableAlias,
    );
  }

  @override
  TetherColumn withAlias(String? alias) {
    return RelatedColumnRef(
      originalName,
      localName,
      tableName,
      relationshipPrefix,
      tableAlias: alias,
    );
  }
}

abstract class SelectBuilderBase {
  final Logger _logger = Logger('SupabaseSelectBuilderBase');

  /// The unique key (often primary key name) of the primary table for this builder.
  /// Example: 'id'.
  final String primaryTableKey;

  /// The alias for the primary table in SQL queries (e.g., 't0').
  final String tableAlias;

  /// Schema information for the primary table this builder operates on.
  final SupabaseTableInfo currentTableInfo;

  /// Stores related builders, keyed by the desired JSON key for the output in the parent object.
  /// For example, `{'author': RelatedBuilderLink(...), 'comments': RelatedBuilderLink(...)}`.
  final Map<String, RelatedBuilderLink> supabaseRelatedBuilders = {};

  /// A set of specific column names (database names) to be selected from the primary table.
  /// If `selectAllPrimary` is `true`, this set is ignored for the primary table's columns.
  final Set<String> selectedPrimaryColumns = {};

  /// If `true`, all columns (`*`) from the primary table will be selected.
  /// If `false`, only columns listed in `selectedPrimaryColumns` (or default PKs if that's empty)
  /// will be selected.
  bool selectAllPrimary = false;

  /// Constructs a [SelectBuilderBase].
  ///
  /// - `primaryTableKey`: The name of the primary key column for `currentTableInfo`.
  ///   While this could be derived from `currentTableInfo.primaryKeys`, passing it
  ///   explicitly can simplify logic or handle cases with composite/no standard PK.
  /// - `currentTableInfo`: The [SupabaseTableInfo] for the table this builder targets.
  SelectBuilderBase({
    required this.primaryTableKey,
    required this.currentTableInfo,
    this.tableAlias = 't0',
  }) {
    if (primaryTableKey != currentTableInfo.uniqueKey &&
        currentTableInfo.uniqueKey.isNotEmpty) {
      _logger.warning(
        "SupabaseSelectBuilderBase for table '${currentTableInfo.originalName}' initialized with primaryTableKey '$primaryTableKey' which does not match currentTableInfo.uniqueKey '${currentTableInfo.uniqueKey}'. This might indicate an issue if uniqueKey is the intended primary identifier.",
      );
    } else if (currentTableInfo.uniqueKey.isEmpty &&
        primaryTableKey.isNotEmpty) {
      _logger.info(
        "SupabaseSelectBuilderBase for table '${currentTableInfo.originalName}' initialized with primaryTableKey '$primaryTableKey', but currentTableInfo.uniqueKey is empty. Ensure '$primaryTableKey' is a valid identifier for selection.",
      );
    }
  }

  /// Gets the original database name of the primary table.
  String get primaryTableName => currentTableInfo.originalName;

  /// Configures this builder to select all columns (`*`) from its primary table.
  ///
  /// This overrides any previous specific column selections made by [selectSupabaseColumns].
  ///
  /// Returns `this` builder instance for chaining.
  T selectAll<T extends SelectBuilderBase>() {
    selectAllPrimary = true;
    selectedPrimaryColumns.clear();
    return this as T;
  }

  /// Configures this builder to select a specific list of columns from its primary table.
  ///
  /// - `dbColumnNames`: A list of database column names (e.g., `['id', 'user_name', 'created_at']`).
  ///
  /// This sets `selectAllPrimary` to `false`.
  ///
  /// Returns `this` builder instance for chaining.
  T selectSupabaseColumns<T extends SelectBuilderBase>(
    List<String> dbColumnNames,
  ) {
    selectedPrimaryColumns.clear();
    selectedPrimaryColumns.addAll(dbColumnNames);
    selectAllPrimary = false;
    return this as T;
  }

  /// Adds a related table to the select query.
  ///
  /// - `jsonKey`: The key that will be used in the resulting JSON for the nested
  ///   object or array of related items (e.g., "author", "posts").
  /// - `fkConstraintName`: The exact name of the foreign key constraint in the database
  ///   that defines the relationship between the current table and the nested table.
  ///   This is crucial for PostgREST to correctly identify and join the tables.
  /// - `nestedBuilder`: A [SelectBuilderBase] instance configured for the
  ///   related table (e.g., an `AuthorsBuilder` or `PostsBuilder`). This builder
  ///   defines which columns are selected from the related table and any further
  ///   nested relationships.
  /// - `innerJoin`: (Optional) If `true`, instructs PostgREST to perform an inner join
  ///   (e.g., `table!fk_constraint!inner`). This means rows from the parent table
  ///   will only be returned if there's at least one matching row in the related table.
  ///   Defaults to `false` (a left join behavior).
  ///
  /// Example:
  /// ```dart
  /// // In a PostsBuilder:
  /// addSupabaseRelated(
  ///   jsonKey: 'authorDetails',
  ///   fkConstraintName: 'posts_author_id_fkey',
  ///   nestedBuilder: AuthorsBuilder().selectColumns([AuthorsColumn.name, AuthorsColumn.bio]),
  ///   innerJoin: true,
  /// );
  /// ```
  void addSupabaseRelated({
    required String jsonKey,
    required String fkConstraintName,
    required SelectBuilderBase nestedBuilder,
    bool innerJoin = false,
  }) {
    if (supabaseRelatedBuilders.containsKey(jsonKey)) {
      _logger.warning(
        'Relationship for JSON key "$jsonKey" already configured for table "$primaryTableName". It will be overwritten.',
      );
    }
    supabaseRelatedBuilders[jsonKey] = RelatedBuilderLink(
      builder: nestedBuilder,
      fkConstraintName: fkConstraintName,
      innerJoin: innerJoin,
    );
  }

  /// Builds the Supabase PostgREST-compatible select string.
  ///
  /// This string defines which columns to fetch from the primary table and
  /// how to embed related data from other tables.
  ///
  /// Format examples:
  /// - `*` (all columns from primary table)
  /// - `id,name` (specific columns)
  /// - `*,author:authors!posts_author_id_fkey(*)` (all from primary, embed author)
  /// - `title,comments:comments!posts_id_fkey(text,user:users!comments_user_id_fkey(name))` (complex nesting)
  /// - `title,author:authors!posts_author_id_fkey!inner(name)` (using inner join)
  ///
  /// Returns the generated select string.
  String buildSupabase() {
    final List<String> parts = [];

    // Determine columns for the primary table
    if (selectAllPrimary) {
      parts.add('*');
    } else if (selectedPrimaryColumns.isNotEmpty) {
      parts.addAll(selectedPrimaryColumns);
    } else {
      // PostgREST requires at least one column or '*' from the primary table
      // if embedding related resources. If no columns are selected and relations exist,
      // default to '*' for the primary table.
      // If no columns and no relations, PostgREST might default to PKs or all.
      // To be safe and explicit, if nothing is selected, default to '*' for the current table.
      parts.add('*');
      if (selectedPrimaryColumns.isEmpty && supabaseRelatedBuilders.isEmpty) {
        _logger.info(
          "Building Supabase select for '${currentTableInfo.originalName}': No specific columns or relations selected, defaulting to '*' for the primary table.",
        );
      } else if (selectedPrimaryColumns.isEmpty &&
          supabaseRelatedBuilders.isNotEmpty) {
        _logger.info(
          "Building Supabase select for '${currentTableInfo.originalName}': No specific primary columns selected but relations exist. Defaulting to '*' for the primary table to support embedding.",
        );
      }
    }

    // Add parts for related builders
    supabaseRelatedBuilders.forEach((jsonKey, relatedLink) {
      final targetTableName = relatedLink.builder.currentTableInfo.originalName;
      final fkConstraintName = relatedLink.fkConstraintName;
      final nestedSelect = relatedLink.builder.buildSupabase();
      final useInnerJoin = relatedLink.innerJoin;

      // Construct the relationship specifier: target_table!fk_constraint_name
      String relationshipSpecifier = '$targetTableName!$fkConstraintName';
      if (useInnerJoin) {
        relationshipSpecifier = '$relationshipSpecifier!inner';
      }

      // Format: jsonKey:relationship_specifier(nested_select)
      // If nestedSelect is empty (e.g., builder defaults to '*' or is misconfigured),
      // PostgREST might still work if it implies '*' for the nested part.
      // However, an empty nestedSelect string from buildSupabase() is unlikely if it defaults to '*' itself.
      if (nestedSelect.isNotEmpty) {
        parts.add('$jsonKey:$relationshipSpecifier($nestedSelect)');
      } else {
        // This case should ideally not be reached if nestedBuilder.buildSupabase()
        // always returns at least '*' or a valid column list.
        _logger.warning(
          "Nested select string for relation '$jsonKey' (targeting '$targetTableName' via FK '$fkConstraintName') is empty. PostgREST query might be malformed. Using format: '$jsonKey:$relationshipSpecifier'.",
        );
        parts.add('$jsonKey:$relationshipSpecifier');
      }
    });

    return parts.join(',');
  }

  /// Builds an SQLite [SqlStatement] to select data from the primary table and
  /// its related tables, constructing a nested JSON structure similar to what
  /// Supabase PostgREST would return.
  ///
  /// The resulting query will typically select a single column named `jsobjects`
  /// containing the JSON string or an array of JSON strings.
  ///
  /// This is useful for querying a local SQLite mirror of Supabase data in a way
  /// that mimics the nested structure of PostgREST responses.
  ///
  /// Returns an [SqlStatement] ready for execution. The `WHERE`, `ORDER BY`, `LIMIT`,
  /// and `OFFSET` clauses should be added to this statement by other builder methods
  /// before execution.
  SqlStatement buildSelectWithNestedData() {
    // Recursively build the JSON structure starting from this builder
    final String topLevelJsonString = _buildRecursiveJson(tableAlias, 0);

    // The final SQL will select this JSON structure.
    // The alias 'AS jsobjects' is NOT added here. It should be added by the
    // final query executor if needed, allowing this method to be used for subqueries.
    return SqlStatement(
      operationType: SqlOperationType.select,
      tableName: primaryTableName, // Base table for the main FROM clause
      selectColumns: topLevelJsonString, // The JSON result, without an alias
      fromAlias: tableAlias, // Alias for the main table in the FROM clause
      // Other parts like where, orderBy, limit, offset are typically added later
    );
  }

  /// Recursively builds the SQLite JSON function calls (json_object, json_group_array)
  /// to construct the nested JSON structure for the current table and its relations.
  ///
  /// - `tableAlias`: The SQL alias for the current table in the query context.
  /// - `depth`: The current recursion depth, used for generating unique aliases for subqueries.
  ///
  /// Returns a string representing an SQLite JSON function call (e.g., `json_object(...)`).
  String _buildRecursiveJson(String tableAlias, int depth) {
    final List<String> jsonFields = []; // For 'key', value, 'key', value ...

    // 1. Determine and add direct columns of this builder's table to the JSON object.
    List<TetherColumnInfo> columnsForThisLevelJson;
    if (selectAllPrimary) {
      columnsForThisLevelJson = currentTableInfo.columns;
    } else if (selectedPrimaryColumns.isNotEmpty) {
      columnsForThisLevelJson =
          currentTableInfo.columns
              .where((col) => selectedPrimaryColumns.contains(col.originalName))
              .toList();
      if (columnsForThisLevelJson.length != selectedPrimaryColumns.length) {
        final missingCols = selectedPrimaryColumns.whereNot(
          (selCol) =>
              columnsForThisLevelJson.any((ci) => ci.originalName == selCol),
        );
        _logger.warning(
          "For table '${currentTableInfo.originalName}' (alias $tableAlias), some selected primary columns were not found in its schema: ${missingCols.join(', ')}. They will be omitted from the JSON.",
        );
      }
    } else {
      // Default to primary keys if no specific columns selected and not selectAll.
      // If no PKs, and relations exist, this might be problematic for linking.
      // If no PKs and no relations, an empty object might be intended.
      columnsForThisLevelJson = currentTableInfo.primaryKeys;
      if (columnsForThisLevelJson.isEmpty &&
          currentTableInfo.columns.isNotEmpty) {
        _logger.info(
          "For table '${currentTableInfo.originalName}' (alias $tableAlias): No columns explicitly selected, no primary keys found. Defaulting to all columns for its JSON object part to ensure some data is included.",
        );
        columnsForThisLevelJson = currentTableInfo.columns;
      } else if (columnsForThisLevelJson.isEmpty &&
          currentTableInfo.columns.isEmpty) {
        _logger.warning(
          "Table '${currentTableInfo.originalName}' (alias $tableAlias) has no columns defined in its schema. Its JSON representation will be empty or json_object().",
        );
        // json_object() is valid for an empty object.
      }
    }

    if (columnsForThisLevelJson.isEmpty && supabaseRelatedBuilders.isEmpty) {
      _logger.info(
        "Building JSON for '${currentTableInfo.originalName}' (alias $tableAlias): No direct fields selected/available and no relations. Result will be json_object().",
      );
    }

    for (final column in columnsForThisLevelJson) {
      jsonFields.add(
        "'${column.localName}'",
      ); // Use localName (Dart name) as JSON key
      // Ensure column names with spaces or special characters are quoted in SQL.
      // SQLite typically uses double quotes for identifiers if needed.
      jsonFields.add("$tableAlias.\"${column.originalName}\"");
    }

    // 2. Process related builders for nested JSON objects or arrays.
    supabaseRelatedBuilders.forEach((jsonKeyForOutput, relatedLink) {
      final nestedBuilder = relatedLink.builder;
      final fkConstraintNameToUse = relatedLink.fkConstraintName;
      final relatedTableInfo = nestedBuilder.currentTableInfo;

      SupabaseForeignKeyConstraint? fkConstraint;
      bool isForwardRelationship =
          true; // True if FK is on currentTableInfo pointing to relatedTableInfo
      String localJoinColumnName = ""; // Column on `tableAlias` (current level)
      String relatedTableJoinColumnName = ""; // Column on the related table

      // Alias for the related table in the subquery. Depth incorporated for uniqueness.
      String subQueryRelatedTableAlias =
          't${depth + 1}_${relatedTableInfo.originalName.replaceAll('_', '').substring(0, Math.min(5, relatedTableInfo.originalName.length))}';

      // Try to find the FK constraint.
      // Scenario 1: FK is on the current table, referencing the related table (e.g., post.author_id -> users.id)
      fkConstraint = currentTableInfo.foreignKeys.firstWhereOrNull(
        (fk) =>
            fk.constraintName == fkConstraintNameToUse &&
            fk.originalForeignTableName == relatedTableInfo.originalName,
      );

      if (fkConstraint != null) {
        isForwardRelationship = true;
        if (fkConstraint.originalColumns.isEmpty ||
            fkConstraint.originalForeignColumns.isEmpty) {
          _logger.severe(
            "FK Constraint '$fkConstraintNameToUse' on table '${currentTableInfo.originalName}' is incomplete (missing column definitions). Skipping relation '$jsonKeyForOutput'.",
          );
          return;
        }
        localJoinColumnName = fkConstraint.originalColumns.first;
        relatedTableJoinColumnName = fkConstraint.originalForeignColumns.first;
      } else {
        // Scenario 2: FK is on the related table, referencing the current table (e.g., comment.post_id -> posts.id)
        fkConstraint = relatedTableInfo.foreignKeys.firstWhereOrNull(
          (fk) =>
              fk.constraintName == fkConstraintNameToUse &&
              fk.originalForeignTableName == currentTableInfo.originalName,
        );

        if (fkConstraint != null) {
          isForwardRelationship = false;
          if (currentTableInfo.primaryKeys.isEmpty) {
            _logger.severe(
              "Cannot form reverse relationship for '$jsonKeyForOutput' (table '${relatedTableInfo.originalName}' to '${currentTableInfo.originalName}'): Primary table '${currentTableInfo.originalName}' has no primary keys defined in its schema. Ensure PKs are correctly parsed.",
            );
            return; // Skip this relation
          }
          if (fkConstraint.originalColumns.isEmpty ||
              currentTableInfo.primaryKeys.first.originalName.isEmpty) {
            _logger.severe(
              "FK Constraint '$fkConstraintNameToUse' on table '${relatedTableInfo.originalName}' or PK on '${currentTableInfo.originalName}' is incomplete. Skipping relation '$jsonKeyForOutput'.",
            );
            return;
          }
          localJoinColumnName =
              currentTableInfo
                  .primaryKeys
                  .first
                  .originalName; // PK on current table
          relatedTableJoinColumnName =
              fkConstraint.originalColumns.first; // FK column on related table
        }
      }

      if (fkConstraint == null) {
        _logger.warning(
          "Could not resolve FK constraint '$fkConstraintNameToUse' for relationship '$jsonKeyForOutput' between '${currentTableInfo.originalName}' and '${relatedTableInfo.originalName}'. This relationship will be skipped in the JSON output.",
        );
        return; // Skip this relation
      }

      // Recursively get the JSON object string for the nested builder
      final String nestedJsonBody = nestedBuilder._buildRecursiveJson(
        subQueryRelatedTableAlias,
        depth + 1,
      );

      String subQuerySql;
      if (isForwardRelationship) {
        // This implies a to-one relationship (e.g., post -> author)
        // The FK is on the current table (`tableAlias`).
        // We expect a single JSON object for the related item.
        subQuerySql = """
          (SELECT $nestedJsonBody
           FROM "${relatedTableInfo.originalName}" AS $subQueryRelatedTableAlias
           WHERE $subQueryRelatedTableAlias."$relatedTableJoinColumnName" = $tableAlias."$localJoinColumnName"
           LIMIT 1)
        """;
      } else {
        // This implies a to-many relationship (e.g., post -> comments)
        // The FK is on the related table (`subQueryRelatedTableAlias`).
        // We expect a JSON array of related items.
        subQuerySql = """
          (SELECT json_group_array($nestedJsonBody)
           FROM "${relatedTableInfo.originalName}" AS $subQueryRelatedTableAlias
           WHERE $subQueryRelatedTableAlias."$relatedTableJoinColumnName" = $tableAlias."$localJoinColumnName")
        """;
        // Ensure that if the subquery for json_group_array returns no rows, it results in NULL or an empty array,
        // not an error. SQLite's json_group_array returns NULL if the subquery has no rows, which is fine.
      }
      jsonFields.add(
        "'$jsonKeyForOutput'",
      ); // The key for this nested structure in the JSON
      jsonFields.add(subQuerySql);
    });

    if (jsonFields.isEmpty) {
      // If, after all processing, jsonFields is empty (e.g., table has no columns selected/available
      // and no valid relations), json_object() is the correct SQLite function for an empty JSON object.
      return "json_object()";
    }

    return "json_object(${jsonFields.join(', ')})";
  }
}

extension SelectBuilderBaseAlias on SelectBuilderBase {
  /// Returns the table alias for the main table being selected.
  ///
  /// This implementation simply returns the `tableAlias` property of the
  /// [SelectBuilderBase].  If you need more complex alias resolution (e.g.,
  /// for JOINs or subqueries), you would override this in subclasses to check
  /// for specific table names and return the correct alias from a more
  /// comprehensive tracking mechanism within your builder.
  String? getAliasForTable(String tableName) {
    // For this base implementation, we only handle the main table's alias.
    return tableName == primaryTableName ? tableAlias : null;
  }
}

/// Helper for Math.min since dart:math is not directly available here
class Math {
  static int min(int a, int b) => a < b ? a : b;
}
