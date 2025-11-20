import 'package:collection/collection.dart';
import 'package:tether_libs/utils/string_utils.dart';

/// A set of Dart reserved keywords.
///
/// These cannot be used as identifiers (e.g., variable names,
/// class names, method names) without special handling, such as appending a suffix.
/// This is crucial for code generation to avoid syntax errors.
final Set<String> _dartKeywords = {
  'abstract',
  'as',
  'assert',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

/// Dart built-in types and common class names.
///
/// These names should be avoided for generated table class names to prevent
/// conflicts and confusion with standard Dart libraries. Appending a suffix
/// like "Table" is a common strategy if a database table has such a name.
final Set<String> _dartBuiltInTypes = {
  'List',
  'Map',
  'Set',
  'String',
  'Object',
  'Future',
  'Stream',
  'Function',
  'Type',
  'Null',
  'Bool',
  'Int',
  'Double',
  'Num',
  'Runes',
  'Symbol',
  'DateTime',
  'Duration',
  'Iterable',
  'Uri',
};

/// Represents information about a database index.
///
/// An index improves the speed of data retrieval operations on a database table
/// at the cost of additional writes and storage space to maintain the index structure.
class SupabaseIndexInfo {
  /// The name of the index, converted to camelCase for Dart conventions.
  /// Example: `user_email_idx` becomes `userEmailIdx`.
  final String name;

  /// The original database name of the index as it exists in PostgreSQL.
  /// Example: `user_email_idx`.
  final String originalName;

  /// A Dart-safe name for the index, avoiding keyword conflicts.
  /// If `name` is a Dart keyword (e.g., `default`), `localName` might be `defaultIndex`.
  final String localName;

  /// Indicates whether the index enforces uniqueness on the indexed column(s).
  /// If `true`, duplicate values are not allowed in the combination of indexed columns.
  final bool isUnique;

  /// List of column names covered by this index, converted to camelCase.
  /// Example: `user_id` becomes `userId`.
  final List<String> columns;

  /// List of original database names of columns covered by this index.
  /// Example: `user_id`.
  final List<String> originalColumns;

  /// Creates an instance of [SupabaseIndexInfo].
  ///
  /// Requires [name], [originalName], [isUnique], [columns], and [originalColumns].
  /// The [localName] is automatically generated if not provided, ensuring it's a
  /// safe Dart identifier.
  SupabaseIndexInfo({
    required this.name,
    required this.originalName,
    String? localName,
    required this.isUnique,
    required this.columns,
    required this.originalColumns,
  }) : localName = localName ?? _makeSafeDartIdentifier(name);

  /// Creates a Dart-safe identifier from a given [name].
  ///
  /// If the [name] is a Dart reserved keyword, it appends "Index" to it.
  /// Otherwise, it returns the [name] unchanged.
  ///
  /// Example:
  /// ```dart
  /// _makeSafeDartIdentifier("primary") // returns "primaryIndex"
  /// _makeSafeDartIdentifier("userName") // returns "userName"
  /// ```
  static String _makeSafeDartIdentifier(String name) {
    return _dartKeywords.contains(name) ? '${name}Index' : name;
  }

  /// Creates a [SupabaseIndexInfo] instance from a raw SQL query result row.
  ///
  /// The [row] is expected to be a list where:
  /// - `row[0]` is the original index name (String).
  /// - `row[1]` is a boolean indicating if the index is unique.
  /// - `row[2]` is a text representation of an array of original column names
  ///   (e.g., `{"col1","col2"}`).
  ///
  /// The [nameConverter] function is used to transform database identifiers
  /// (like index and column names) into Dart-conventional names (e.g., camelCase).
  factory SupabaseIndexInfo.fromRow(
    List<dynamic> row,
    String Function(String) nameConverter,
  ) {
    final originalIndexName = row[0] as String;
    final convertedName = nameConverter(originalIndexName);
    final isUnique = row[1] as bool? ?? false;
    // Index 2 is now the text representation of the array (e.g., {"col1","col2"})
    final columnsText = row[2] as String?;
    final originalColumnNames = _parsePgTextArray(
      columnsText,
    ); // Parse the string

    return SupabaseIndexInfo(
      name: convertedName, // Convert index name
      originalName: originalIndexName,
      localName: _makeSafeDartIdentifier(convertedName),
      isUnique: isUnique,
      columns:
          originalColumnNames
              .map(nameConverter)
              .toList(), // Convert column names
      originalColumns: originalColumnNames,
    );
  }

  /// Converts this [SupabaseIndexInfo] instance to a JSON map.
  ///
  /// This is useful for serialization, for example, when saving schema information
  /// to a file.
  Map<String, dynamic> toJson() => {
    'name': name,
    'originalName': originalName,
    'localName': localName,
    'isUnique': isUnique,
    'columns': columns,
    'originalColumns': originalColumns,
  };

  /// Creates a [SupabaseIndexInfo] instance from a JSON map.
  ///
  /// This is useful for deserialization, for example, when loading schema
  /// information from a file. It handles potential missing fields from older
  /// versions of serialized data by providing default values.
  factory SupabaseIndexInfo.fromJson(Map<String, dynamic> json) {
    // Handle potential missing original names in older delta files
    final cols = List<String>.from(json['columns'] as List? ?? []);
    final origCols = List<String>.from(
      json['originalColumns'] as List? ?? cols,
    );
    final name = json['name'] as String? ?? ''; // Provide default if missing
    final origName = json['originalName'] as String? ?? name;

    return SupabaseIndexInfo(
      name: name,
      originalName: origName,
      localName: json['localName'] as String? ?? _makeSafeDartIdentifier(name),
      isUnique: json['isUnique'] as bool? ?? false,
      columns: cols,
      originalColumns: origCols,
    );
  }

  @override
  String toString() =>
      'Index $name (Unique: $isUnique, Columns: [${columns.join(', ')}])';
}

/// Represents details about a specific foreign key constraint on a table.
///
/// A foreign key links a column (or a set of columns) in one table to a
/// column (or a set of columns) in another table (or the same table).
/// This enforces referential integrity.
class SupabaseForeignKeyConstraint {
  /// The original name of the foreign key constraint as defined in the database.
  final String constraintName;

  /// List of local column names (converted to camelCase) that are part of this foreign key.
  final List<String> columns;

  /// List of original database names of the local columns for this foreign key.
  final List<String> originalColumns;

  /// List of Dart-safe local column names.
  /// If an original column name is a Dart keyword, this version will be suffixed.
  final List<String> localColumns;

  /// The schema of the table referenced by this foreign key.
  final String foreignTableSchema;

  /// The name of the table referenced by this foreign key (converted to camelCase).
  final String foreignTableName;

  /// The original database name of the table referenced by this foreign key.
  final String originalForeignTableName;

  /// A Dart-safe class name for the foreign table.
  /// If the original table name conflicts with a Dart built-in type, this will be suffixed.
  final String localForeignTableName;

  /// List of column names in the foreign table that this key references (converted to camelCase).
  final List<String> foreignColumns;

  /// List of original database names of the columns in the foreign table.
  final List<String> originalForeignColumns;

  /// List of Dart-safe foreign column names.
  final List<String> localForeignColumns;

  /// The action to take on the referencing rows if the referenced row is updated.
  /// Common values: `NO ACTION`, `CASCADE`, `SET NULL`, `SET DEFAULT`.
  final String updateRule;

  /// The action to take on the referencing rows if the referenced row is deleted.
  /// Common values: `NO ACTION`, `CASCADE`, `SET NULL`, `SET DEFAULT`.
  final String deleteRule;

  /// The match type for the foreign key (e.g., `SIMPLE`, `FULL`, `PARTIAL`).
  /// Typically `SIMPLE` for most use cases.
  final String matchOption;

  /// Indicates if the constraint check can be deferred until the end of the transaction.
  final bool isDeferrable;

  /// Indicates if the constraint check is deferred by default.
  final bool initiallyDeferred;

  /// If this foreign key is part of a many-to-many relationship, this holds the
  /// name of the join table (intermediate table). Otherwise, it\'s `null`.
  String? joinTableName;

  /// Creates an instance of [SupabaseForeignKeyConstraint].
  SupabaseForeignKeyConstraint({
    required this.constraintName,
    required this.columns,
    required this.originalColumns,
    List<String>? localColumns,
    required this.foreignTableSchema,
    required this.foreignTableName,
    required this.originalForeignTableName,
    String? localForeignTableName,
    required this.foreignColumns,
    required this.originalForeignColumns,
    List<String>? localForeignColumns,
    required this.updateRule,
    required this.deleteRule,
    required this.matchOption,
    required this.isDeferrable,
    required this.initiallyDeferred,
    this.joinTableName,
  }) : localColumns =
           localColumns ??
           originalColumns.map((col) => _makeSafeDartIdentifier(col)).toList(),
       localForeignTableName =
           localForeignTableName ??
           _makeSafeDartClassName(originalForeignTableName),
       localForeignColumns =
           localForeignColumns ??
           originalForeignColumns
               .map((col) => _makeSafeDartIdentifier(col))
               .toList();

  /// Creates a Dart-safe identifier from a given [name].
  /// Appends "Field" if [name] is a Dart keyword.
  static String _makeSafeDartIdentifier(String name) {
    return _dartKeywords.contains(name) ? '${name}Field' : name;
  }

  /// Creates a Dart-safe class name from a given [name].
  /// Appends "Table" if [name] conflicts with a Dart built-in type.
  static String _makeSafeDartClassName(String name) {
    return _dartBuiltInTypes.contains(name) ? '${name}Table' : name;
  }

  /// Creates a [SupabaseForeignKeyConstraint] from a list of raw SQL query result rows.
  ///
  /// All [rows] must belong to the same foreign key constraint, identified by [name].
  /// Each row typically represents one column pair in a composite foreign key.
  /// The [nameConverter] function transforms database identifiers to Dart conventions.
  /// The optional [joinTableName] is used for many-to-many relationships.
  static SupabaseForeignKeyConstraint fromRawRows(
    String name,
    List<List<dynamic>> rows,
    String Function(String) nameConverter, {
    String? joinTableName,
  }) {
    if (rows.isEmpty) {
      throw ArgumentError(
        'Cannot create ForeignKeyConstraint from empty rows.',
      );
    }
    final firstRow = rows.first;
    final originalLocalColumns =
        rows.map<String>((row) => row[1] as String).toList();
    final originalForeignTblName = firstRow[3] as String;
    final originalForeignCols =
        rows.map<String>((row) => row[4] as String).toList();

    return SupabaseForeignKeyConstraint(
      constraintName: name,
      columns: originalLocalColumns.map(nameConverter).toList(),
      originalColumns: originalLocalColumns,
      localColumns: originalLocalColumns.map(_makeSafeDartIdentifier).toList(),
      foreignTableSchema: firstRow[2] as String,
      foreignTableName: nameConverter(originalForeignTblName),
      originalForeignTableName: originalForeignTblName,
      localForeignTableName: _makeSafeDartClassName(originalForeignTblName),
      foreignColumns: originalForeignCols.map(nameConverter).toList(),
      originalForeignColumns: originalForeignCols,
      localForeignColumns:
          originalForeignCols.map(_makeSafeDartIdentifier).toList(),
      updateRule: firstRow[5] as String,
      deleteRule: firstRow[6] as String,
      matchOption: firstRow[7] as String,
      isDeferrable: (firstRow[8] as String? ?? 'NO') == 'YES',
      initiallyDeferred: (firstRow[9] as String? ?? 'NO') == 'YES',
      joinTableName: joinTableName, // Set the join table name
    );
  }

  /// Converts this [SupabaseForeignKeyConstraint] instance to a JSON map for serialization.
  Map<String, dynamic> toJson() => {
    'constraintName': constraintName,
    'columns': columns,
    'originalColumns': originalColumns,
    'localColumns': localColumns,
    'foreignTableSchema': foreignTableSchema,
    'foreignTableName': foreignTableName,
    'originalForeignTableName': originalForeignTableName,
    'localForeignTableName': localForeignTableName,
    'foreignColumns': foreignColumns,
    'originalForeignColumns': originalForeignColumns,
    'localForeignColumns': localForeignColumns,
    'updateRule': updateRule,
    'deleteRule': deleteRule,
    'matchOption': matchOption,
    'isDeferrable': isDeferrable,
    'initiallyDeferred': initiallyDeferred,
    'joinTableName': joinTableName, // Serialize the join table name
  };

  /// Creates a [SupabaseForeignKeyConstraint] instance from a JSON map (deserialization).
  /// Handles missing fields from older data formats with default values.
  factory SupabaseForeignKeyConstraint.fromJson(Map<String, dynamic> json) {
    final cols = List<String>.from(json['columns'] as List);
    final origCols = List<String>.from(
      json['originalColumns'] as List? ?? cols,
    );
    final localCols =
        json['localColumns'] != null
            ? List<String>.from(json['localColumns'] as List)
            : origCols.map(_makeSafeDartIdentifier).toList();

    final fTblName = json['foreignTableName'] as String;
    final origFTblName =
        json['originalForeignTableName'] as String? ?? fTblName;
    final localFTblName =
        json['localForeignTableName'] as String? ??
        _makeSafeDartClassName(origFTblName);

    final fCols = List<String>.from(json['foreignColumns'] as List);
    final origFCols = List<String>.from(
      json['originalForeignColumns'] as List? ?? fCols,
    );
    final localFCols =
        json['localForeignColumns'] != null
            ? List<String>.from(json['localForeignColumns'] as List)
            : origFCols.map(_makeSafeDartIdentifier).toList();

    return SupabaseForeignKeyConstraint(
      constraintName: json['constraintName'] as String,
      columns: cols,
      originalColumns: origCols,
      localColumns: localCols,
      foreignTableSchema: json['foreignTableSchema'] as String,
      foreignTableName: fTblName,
      originalForeignTableName: origFTblName,
      localForeignTableName: localFTblName,
      foreignColumns: fCols,
      originalForeignColumns: origFCols,
      localForeignColumns: localFCols,
      updateRule: json['updateRule'] as String,
      deleteRule: json['deleteRule'] as String,
      matchOption: json['matchOption'] as String,
      isDeferrable: json['isDeferrable'] as bool,
      initiallyDeferred: json['initiallyDeferred'] as bool,
      joinTableName:
          json['joinTableName'] as String?, // Deserialize the join table name
    );
  }

  /// Generates a sanitized key for the foreign key relationship, used for generating
  /// field names in model classes.
  ///
  /// It takes the first local column name of the foreign key, removes any specified [endings]
  /// (like "_id", "Id", "uuid"), converts it to camelCase, and then:
  /// - If the resulting name (lowercase) matches the foreign table name (lowercase),
  ///   it returns the pluralized version of that name.
  ///   Example: `author_id` in `books` table referencing `authors` table -> `authors`.
  /// - Otherwise, it appends the capitalized camelCase foreign table name to ensure uniqueness.
  ///   Example: `primary_author_id` in `books` table referencing `authors` table -> `primaryAuthorAuthors`.
  ///
  /// This helps create intuitive field names for relationships. For instance, a `Book` model
  /// might have an `author` field (if FK is `author_id`) or `coAuthorAuthors` (if FK is `co_author_id`
  /// pointing to `authors` table).
  String sanitizedKey(List<String> endings) {
    String baseName = originalColumns.first;

    // Remove any matching ending from the column name
    for (final ending in endings) {
      if (baseName.toLowerCase().endsWith(ending.toLowerCase())) {
        baseName = baseName.substring(0, baseName.length - ending.length);
        break; // Stop after the first match
      }
    }

    // Convert the base name to camelCase
    baseName = StringUtils.toCamelCase(baseName);

    // If the base name matches the foreign table name, return the pluralized table name
    if (baseName.toLowerCase() == originalForeignTableName.toLowerCase()) {
      return StringUtils.pluralize(baseName);
    }

    // Combine the base name with the foreign table name to ensure uniqueness
    return '$baseName${StringUtils.capitalize(StringUtils.toCamelCase(originalForeignTableName))}';
  }

  @override
  String toString() =>
      'FK $constraintName (${localColumns.join(', ')}) -> $foreignTableSchema.$localForeignTableName (${localForeignColumns.join(', ')}) ON DELETE $deleteRule ON UPDATE $updateRule${joinTableName != null ? ', Join Table: $joinTableName' : ''}';
}

/// Represents details about a single column within a database table.
class TetherColumnInfo {
  /// The name of the column, converted to camelCase for Dart conventions.
  /// Example: `user_name` becomes `userName`.
  final String name;

  /// The original database name of the column.
  /// Example: `user_name`.
  final String originalName;

  /// A Dart-safe identifier name for the column, avoiding keyword conflicts.
  /// If `originalName` is a Dart keyword (e.g., `is`), `localName` might be `isField`.
  final String localName;

  /// The data type of the column as defined in the database (e.g., `TEXT`, `INTEGER`, `TIMESTAMPZ`).
  final String type;

  /// Indicates whether the column can store `NULL` values.
  final bool isNullable;

  /// Indicates whether this column is part of the table\'s primary key.
  final bool isPrimaryKey;

  /// Indicates whether this column has a unique constraint.
  final bool isUnique;

  /// The default value of the column, if any, as a string representation.
  /// Example: `CURRENT_TIMESTAMP`, `\'active\'::character varying`.
  final String? defaultValue;

  /// The comment associated with the column in the database, if any.
  final String? comment;

  /// Indicates whether the column is an identity column (e.g., auto-incrementing).
  /// For PostgreSQL, this corresponds to `is_identity = \'YES\'`.
  final bool isIdentity;

  /// Creates an instance of [TetherColumnInfo].
  TetherColumnInfo({
    required this.name,
    required this.originalName,
    String? localName,
    required this.type,
    required this.isNullable,
    required this.isPrimaryKey,
    required this.isUnique,
    this.defaultValue,
    this.comment,
    this.isIdentity = false,
  }) : localName = localName ?? _makeSafeDartIdentifier(originalName);

  /// Creates a Dart-safe identifier from a given [name].
  /// Appends "Field" if [name] is a Dart keyword.
  static String _makeSafeDartIdentifier(String name) {
    return _dartKeywords.contains(name) ? '${name}Field' : name;
  }

  /// Creates a [TetherColumnInfo] instance from a raw SQL query result row.
  ///
  /// The [row] is a list of values corresponding to column attributes fetched
  /// from the database\'s information schema. The exact indices depend on the
  /// `SELECT` query used.
  /// [nameConverter] transforms the original DB column name to a Dart-friendly one.
  ///
  /// Example `SELECT` statement columns and their typical `row` indices:
  /// - `column_name` (String) -> `row[0]`
  /// - `data_type` (String) -> `row[1]`
  /// - `is_nullable` (String: 'YES'/'NO') -> `row[2]`
  /// - `column_default` (String or null) -> `row[3]`
  /// - `description` (String or null, from `pg_description`) -> `row[4]`
  /// - `is_primary_key` (bool, from joining with constraints) -> `row[5]`
  /// - `is_unique` (bool, from joining with constraints) -> `row[6]`
  /// - `is_identity` (String: 'YES'/'NO') -> `row[7]` (Adjust `indexOfIsIdentity` if different)
  factory TetherColumnInfo.fromRow(
    List<dynamic> row,
    String Function(String) nameConverter,
  ) {
    final originalDbName = row[0] as String;

    // --- Determine the correct index for 'is_identity' ---
    // This index MUST match the position of 'is_identity' in the SELECT list
    // of your database schema introspection query.
    // For this example, let's assume it's at index 7.
    const int indexOfIsIdentity = 7; // <<< ADJUST THIS INDEX

    bool isIdentityValue = false;
    if (row.length > indexOfIsIdentity && row[indexOfIsIdentity] is String) {
      // PostgreSQL's information_schema.columns.is_identity is 'YES' or 'NO'
      isIdentityValue =
          (row[indexOfIsIdentity] as String).toUpperCase() == 'YES';
    } else if (row.length > indexOfIsIdentity &&
        row[indexOfIsIdentity] is bool) {
      // In case your query somehow pre-converts it to a boolean
      isIdentityValue = row[indexOfIsIdentity] as bool;
    }
    // Add more checks if other representations are possible

    return TetherColumnInfo(
      name: nameConverter(originalDbName),
      originalName: originalDbName,
      localName: _makeSafeDartIdentifier(originalDbName),
      type: row[1] as String, // Assuming type is at index 1
      isNullable:
          (row[2] as String? ?? 'NO').toUpperCase() ==
          'YES', // Assuming is_nullable is at index 2
      defaultValue: row[3] as String?, // Assuming column_default is at index 3
      comment:
          row[4] as String?, // Assuming comment is at index 4 (if you fetch it)
      isPrimaryKey:
          row[5] as bool? ??
          false, // Assuming is_primary_key is at index 5 (you'd need to join to get this)
      isUnique:
          row[6] as bool? ??
          false, // Assuming is_unique is at index 6 (you'd need to join to get this)
      isIdentity: isIdentityValue,
    );
  }

  /// Converts this [TetherColumnInfo] instance to a JSON map for serialization.
  Map<String, dynamic> toJson() => {
    'name': name,
    'originalName': originalName,
    'localName': localName,
    'type': type,
    'isNullable': isNullable,
    'isPrimaryKey': isPrimaryKey,
    'isUnique': isUnique,
    'defaultValue': defaultValue,
    'comment': comment,
    'isIdentity': isIdentity, // <<< ADDED TO toJson
  };

  /// Creates a [TetherColumnInfo] instance from a JSON map (deserialization).
  /// Handles missing fields from older data formats with default values.
  factory TetherColumnInfo.fromJson(Map<String, dynamic> json) {
    final originalName =
        json['originalName'] as String? ?? json['name'] as String;
    return TetherColumnInfo(
      name: json['name'] as String,
      originalName: originalName,
      localName:
          json['localName'] as String? ?? _makeSafeDartIdentifier(originalName),
      type: json['type'] as String,
      isNullable: json['isNullable'] as bool,
      isPrimaryKey: json['isPrimaryKey'] as bool,
      isUnique: json['isUnique'] as bool,
      defaultValue: json['defaultValue'] as String?,
      comment: json['comment'] as String?,
      isIdentity:
          json['isIdentity'] as bool? ??
          false, // <<< ADDED TO fromJson with default
    );
  }

  @override
  String toString() =>
      'Column $name ($type, Nullable: $isNullable, PK: $isPrimaryKey, Unique: $isUnique, Identity: $isIdentity${defaultValue != null ? ', Default: $defaultValue' : ''}${comment != null ? ', Comment: "$comment"' : ''})'; // <<< ADDED isIdentity to toString
}

/// Represents information about a "reverse" relationship from another table to this one.
///
/// This is used to model one-to-many or many-to-many relationships from the "one" side
/// or from one side of a join table.
///
/// For example, if an `Author` can have many `Book`s, and `Book` has an `author_id`
/// foreign key, then `Author` model would have a `ModelReverseRelationInfo`
/// describing its list of books.
class ModelReverseRelationInfo {
  /// The name of the field in the current model class that will hold the list of related items.
  ///
  /// Example: If `AuthorModel` has `List<BookModel>? books;`, this would be "books".
  final String fieldNameInThisModel;

  /// The original database name of the table that references this model (the "many" side).
  ///
  /// Example: For `AuthorModel`\'s `books` list, this would be "books" (the table name of `BookModel`).
  final String referencingTableOriginalName;

  /// The name of the foreign key column in the `referencingTableOriginalName`
  /// that points back to this model\'s table.
  ///
  /// Example: For `AuthorModel`\'s `books` list, this would be "author_id" (from the "books" table).
  final String foreignKeyColumnInReferencingTable;

  /// Creates an instance of [ModelReverseRelationInfo].
  ModelReverseRelationInfo({
    required this.fieldNameInThisModel,
    required this.referencingTableOriginalName,
    required this.foreignKeyColumnInReferencingTable,
  });

  /// Converts this [ModelReverseRelationInfo] instance to a JSON map for serialization.
  Map<String, dynamic> toJson() => {
    'fieldNameInThisModel': fieldNameInThisModel,
    'referencingTableOriginalName': referencingTableOriginalName,
    'foreignKeyColumnInReferencingTable': foreignKeyColumnInReferencingTable,
  };

  /// Creates a [ModelReverseRelationInfo] instance from a JSON map (deserialization).
  factory ModelReverseRelationInfo.fromJson(Map<String, dynamic> json) {
    return ModelReverseRelationInfo(
      fieldNameInThisModel: json['fieldNameInThisModel'] as String,
      referencingTableOriginalName:
          json['referencingTableOriginalName'] as String,
      foreignKeyColumnInReferencingTable:
          json['foreignKeyColumnInReferencingTable'] as String,
    );
  }

  @override
  String toString() =>
      'ReverseRelation: $fieldNameInThisModel (from $referencingTableOriginalName via $foreignKeyColumnInReferencingTable)';
}

/// Represents detailed information about a database table, including its columns,
/// foreign keys, indexes, and reverse relationships.
///
/// This class is a central piece of metadata used for code generation,
/// allowing the creation of Dart model classes that accurately reflect the
/// database schema.
class SupabaseTableInfo {
  /// The name of the table, converted to camelCase for Dart conventions.
  /// Example: `user_profiles` becomes `userProfiles`.
  final String name;

  /// The original database name of the table.
  /// Example: `user_profiles`.
  final String originalName;

  /// A Dart-safe class name for the table.
  /// If `originalName` conflicts with a Dart built-in type (e.g., `List`),
  /// `localName` might be `ListTable`.
  final String localName;

  /// The database schema the table belongs to (e.g., `public`).
  final String schema;

  /// A list of [TetherColumnInfo] objects representing the columns in this table.
  final List<TetherColumnInfo> columns;

  /// A list of [SupabaseForeignKeyConstraint] objects representing the foreign keys
  /// defined on this table.
  final List<SupabaseForeignKeyConstraint> foreignKeys;

  /// A list of [SupabaseIndexInfo] objects representing the indexes on this table.
  final List<SupabaseIndexInfo> indexes;

  /// A list of [SupabaseIndexInfo] objects representing the unique constraints on this table.
  /// This is typically derived from unique indexes.
  final List<SupabaseIndexInfo> uniqueConstraints;

  /// The comment associated with the table in the database, if any.
  final String? comment;

  /// A list of [ModelReverseRelationInfo] objects describing relationships where
  /// other tables reference this table (one-to-many or through a join table).
  final List<ModelReverseRelationInfo> reverseRelations;

  /// Creates an instance of [SupabaseTableInfo].
  ///
  /// It automatically calls `_setJoinTableNames()` to identify and mark
  /// foreign keys involved in many-to-many relationships via join tables.
  SupabaseTableInfo({
    required this.name,
    required this.originalName,
    String? localName,
    required this.schema,
    required this.columns,
    required this.foreignKeys,
    required this.indexes,
    this.comment,
    this.reverseRelations = const [],
  })  : localName = localName ?? _makeSafeDartClassName(originalName),
        uniqueConstraints =
            indexes.where((index) => index.isUnique).toList() {
    _setJoinTableNames();
  }

  /// Creates a Dart-safe class name from a given [name].
  /// Appends "Table" if [name] conflicts with a Dart built-in type.
  static String _makeSafeDartClassName(String name) {
    return _dartBuiltInTypes.contains(name) ? '${name}Table' : name;
  }

  /// Identifies if this table acts as a join table for many-to-many relationships.
  ///
  /// A table is considered a join table if it has exactly two foreign keys.
  /// If so, it sets the `joinTableName` property on those [SupabaseForeignKeyConstraint]s
  /// to this table\'s `originalName`. This helps in generating appropriate
  /// relationship fields in the model classes of the two tables linked by this join table.
  void _setJoinTableNames() {
    // A table is considered a join table if it has exactly two foreign keys
    if (foreignKeys.length == 2) {
      for (final fk in foreignKeys) {
        fk.joinTableName = originalName; // Set the join table name
      }
    }
  }

  /// Converts this [SupabaseTableInfo] instance to a JSON map for serialization.
  Map<String, dynamic> toJson() => {
        'name': name,
        'originalName': originalName,
        'localName': localName,
        'schema': schema,
        'columns': columns.map((c) => c.toJson()).toList(),
        'foreignKeys': foreignKeys.map((fk) => fk.toJson()).toList(),
        'indexes': indexes.map((idx) => idx.toJson()).toList(),
        'comment': comment,
        'reverseRelations':
            reverseRelations.map((rr) => rr.toJson()).toList(),
      };

  /// Creates a [SupabaseTableInfo] instance from a JSON map (deserialization).
  /// Handles missing fields from older data formats with default values.
  factory SupabaseTableInfo.fromJson(Map<String, dynamic> json) {
    final originalName =
        json['originalName'] as String? ?? json['name'] as String? ?? '';
    return SupabaseTableInfo(
      name: json['name'] as String? ?? originalName,
      originalName: originalName,
      localName: json['localName'] as String?,
      schema: json['schema'] as String? ?? 'public',
      columns: (json['columns'] as List<dynamic>? ?? [])
          .map((c) => TetherColumnInfo.fromJson(c as Map<String, dynamic>))
          .toList(),
      foreignKeys: (json['foreignKeys'] as List<dynamic>? ?? [])
          .map((fk) =>
              SupabaseForeignKeyConstraint.fromJson(fk as Map<String, dynamic>))
          .toList(),
      indexes: (json['indexes'] as List<dynamic>? ?? [])
          .map((idx) => SupabaseIndexInfo.fromJson(idx as Map<String, dynamic>))
          .toList(),
      comment: json['comment'] as String?,
      reverseRelations: (json['reverseRelations'] as List<dynamic>? ?? [])
          .map((rr) =>
              ModelReverseRelationInfo.fromJson(rr as Map<String, dynamic>))
          .toList(),
    );
  }

  /// A unique key for this table, combining schema and original name.
  /// Example: `public.user_profiles`.
  String get uniqueKey => '$schema.$originalName';

  /// Returns a map of sanitized keys for all foreign key relationships of this table.
  ///
  /// The key in the map is the result of `fk.sanitizedKey(endings)`, and the value
  /// is the [SupabaseForeignKeyConstraint] itself.
  /// The [endings] list is passed to `sanitizedKey` to help generate cleaner field names.
  Map<String, SupabaseForeignKeyConstraint> sanitizedKeys(
    List<String> endings,
  ) {
    final Map<String, SupabaseForeignKeyConstraint> keys = {};
    for (final fk in foreignKeys) {
      keys[fk.sanitizedKey(endings)] = fk;
    }
    return keys;
  }

  /// Gets a list of columns that are part of the primary key for this table.
  List<TetherColumnInfo> get primaryKeys =>
      columns.where((col) => col.isPrimaryKey).toList();

  /// Gets a list of foreign key constraints that involve the specified [columnName].
  List<SupabaseForeignKeyConstraint> getForeignKeysForColumn(
    String columnName,
  ) {
    return foreignKeys.where((fk) => fk.columns.contains(columnName)).toList();
  }

  /// Finds a foreign key constraint by its [constraintName].
  /// Returns `null` if no such constraint exists.
  SupabaseForeignKeyConstraint? getForeignKeyByName(String constraintName) {
    return foreignKeys.firstWhereOrNull(
      (fk) => fk.constraintName == constraintName,
    );
  }

  @override
  String toString() =>
      'Table $schema.$name (${columns.length} cols, ${foreignKeys.length} FKs, ${indexes.length} Idxs, ${reverseRelations.length} RevRels)${comment != null ? ' Comment: "$comment"' : ''}';
}

/// Parses a PostgreSQL text array representation (e.g., `{"col1","col2"}`)
/// into a `List<String>`.
///
/// Handles basic cases and assumes column names do not contain commas, quotes, or braces.
/// For more complex array strings (e.g., with quoted elements or escaped characters),
/// a more robust parser would be needed.
///
/// Returns an empty list if [arrayText] is null, too short, or not in the expected
/// `{...}` format. Also handles the empty array case `"{}"`.
List<String> _parsePgTextArray(String? arrayText) {
  if (arrayText == null ||
      arrayText.length < 2 ||
      !arrayText.startsWith('{') ||
      !arrayText.endsWith('}')) {
    return <String>[]; // Return empty list for null, empty, or invalid format
  }
  // Remove braces
  final content = arrayText.substring(1, arrayText.length - 1);
  if (content.isEmpty) {
    return <String>[]; // Handle empty array "{}"
  }
  // Split by comma and trim whitespace (basic parsing)
  // This assumes simple column names without quotes or escaped commas.
  return content.split(',').map((s) => s.trim()).toList();
}
