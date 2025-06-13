import 'dart:io';

import 'package:collection/collection.dart'; // For whereNotNull
import 'package:inflection3/inflection3.dart';
import 'package:path/path.dart' as p;
import 'package:recase/recase.dart';
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/utils/logger.dart';

/// Represents information about a reverse relationship (one-to-many or many-to-many).
class _ReverseRelationInfo {
  /// The type of relationship (e.g., oneToMany, manyToMany).
  final String relationType; // 'oneToMany', 'manyToMany'

  /// For 1-to-many: Name of the table that has an FK to the current model.
  /// For M-to-M: Name of the JUNCTION table.
  final String relatedTableName;

  /// For 1-to-many: Class name of the related table's model.
  /// For M-to-M: Class name of the JUNCTION table's model.
  final String relatedModelClassName;

  /// For 1-to-many: Field name in the current model for the list of related models (e.g., "userProfiles").
  /// For M-to-M: Field name in the current model for the list of JUNCTION TABLE models (e.g., "bookAuthors").
  final String fieldNameInThisModel;

  // --- One-to-Many Specific ---
  final String?
  foreignKeyInRelatedTable; // FK in the 'relatedTableName' pointing back

  // --- Many-to-Many Specific ---
  final String?
  junctionTableName; // Name of the junction table (same as relatedTableName for M2M)

  /// For M-to-M: The desired name for the getter that returns List<TargetModel> (e.g., "authors").
  final String? m2mTargetLinkGetterName;

  /// For M-to-M: The class name of the actual target model (e.g., "AuthorModel").
  final String? m2mTargetModelClassName;

  /// For M-to-M: The field name within the junction table's model that points to the target model.
  /// (e.g., if BookAuthor model has a field 'author' of type AuthorModel).
  final String? m2mJoinModelFieldNameForTarget;

  _ReverseRelationInfo({
    required this.relationType,
    required this.relatedTableName,
    required this.relatedModelClassName,
    required this.fieldNameInThisModel,
    this.foreignKeyInRelatedTable,
    this.junctionTableName,
    this.m2mTargetLinkGetterName,
    this.m2mTargetModelClassName,
    this.m2mJoinModelFieldNameForTarget,
  });
}

/// Generates Dart model classes from SupabaseTableInfo.
class ModelGenerator {
  final SupabaseGenConfig config;
  final Logger _logger;
  final Map<String, SupabaseTableInfo> _tableMap = {};
  final Map<String, List<_ReverseRelationInfo>> _reverseRelationsMap = {};

  ModelGenerator({required this.config, Logger? logger})
    : _logger = logger ?? Logger('ModelGenerator');

  /// Generates the Dart models file.
  Future<void> generate(List<SupabaseTableInfo> tables) async {
    if (!config.generateModels) {
      _logger.info('Model generation is disabled in config. Skipping.');
      return;
    }

    _buildTableMap(tables);
    _preprocessRelations(tables);

    final outputFileName =
        config.modelsFileName; // Assuming this exists in config
    final outputFilePath = p.join(config.outputDirectory, outputFileName);
    final buffer = StringBuffer();

    _writeHeader(buffer);

    for (final table in tables) {
      // Skip junction tables if needed (optional, depends on desired output)
      // if (_isJunctionTable(table)) continue;
      _generateModelClass(buffer, table);
      buffer.writeln(); // Add space between classes
    }

    try {
      final file = File(outputFilePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(buffer.toString());
      _logger.info('Generated models file: $outputFilePath');
    } catch (e) {
      _logger.severe('Error writing models file $outputFilePath: $e');
    }
  }

  void _buildTableMap(List<SupabaseTableInfo> tables) {
    _tableMap.clear();
    for (final table in tables) {
      _tableMap[table.originalName] = table;
    }
  }

  // Add a helper to derive field name from FK (used for forward relations)
  // This logic is crucial for knowing the field name in the join model.
  String _getFieldNameFromFkColumn(String fkColumnName) {
    String name = fkColumnName.camelCase; // Start with camelCase
    if (name.endsWith('Id') && name.length > 2) {
      name = name.substring(0, name.length - 2);
    } else if (name.endsWith('Uuid') && name.length > 4) {
      name = name.substring(0, name.length - 4);
    }
    // Add other common suffixes like '_fkey' if your naming includes them before _id
    name = name.replaceAll('Fkey', ''); // If Fkey was part of the camelCase
    return name.camelCase; // Ensure it's camelCase after stripping
  }

  /// Analyzes foreign keys to determine reverse relationships (one-to-many, many-to-many).
  void _preprocessRelations(List<SupabaseTableInfo> tables) {
    _reverseRelationsMap.clear();

    for (final table in tables) {
      final isJunction = _isJunctionTable(table);

      if (isJunction && table.foreignKeys.length == 2) {
        final fk1 = table.foreignKeys[0]; // FK from junction to tableA
        final fk2 = table.foreignKeys[1]; // FK from junction to tableB

        final tableA = _tableMap[fk1.originalForeignTableName];
        final tableB = _tableMap[fk2.originalForeignTableName];

        if (tableA != null && tableB != null) {
          final junctionTableClassName = _getDartClassName(
            table,
          ); // e.g., BookAuthorModel

          // For Table A (e.g., BookModel): link to Table B (e.g., AuthorModel) via Junction (e.g., BookAuthorModel)
          _addReverseRelation(
            targetTable: tableA.originalName,
            info: _ReverseRelationInfo(
              relationType: 'manyToMany',
              relatedTableName:
                  table
                      .originalName, // Junction table is the "related" for the direct list
              relatedModelClassName:
                  junctionTableClassName, // List of junction models
              fieldNameInThisModel: _pluralize(
                table.localName.camelCase,
              ), // e.g., "bookAuthors"
              junctionTableName: table.originalName,
              m2mTargetLinkGetterName: _pluralize(
                tableB.localName.camelCase,
              ), // e.g., "authors"
              m2mTargetModelClassName: _getDartClassName(
                tableB,
              ), // e.g., AuthorModel
              // Field in JunctionModel (BookAuthorModel) that points to TableB (AuthorModel)
              // This field is derived from fk2 (the FK on junction table pointing to tableB)
              m2mJoinModelFieldNameForTarget: _getFieldNameFromFkColumn(
                fk2.originalColumns.first,
              ), // e.g. "author"
            ),
          );

          // For Table B (e.g., AuthorModel): link to Table A (e.g., BookModel) via Junction
          _addReverseRelation(
            targetTable: tableB.originalName,
            info: _ReverseRelationInfo(
              relationType: 'manyToMany',
              relatedTableName: table.originalName,
              relatedModelClassName: junctionTableClassName,
              fieldNameInThisModel: _pluralize(
                table.localName.camelCase,
              ), // e.g., "bookAuthors"
              junctionTableName: table.originalName,
              m2mTargetLinkGetterName: _pluralize(
                tableA.localName.camelCase,
              ), // e.g., "books"
              m2mTargetModelClassName: _getDartClassName(
                tableA,
              ), // e.g., BookModel
              // Field in JunctionModel (BookAuthorModel) that points to TableA (BookModel)
              // This field is derived from fk1 (the FK on junction table pointing to tableA)
              m2mJoinModelFieldNameForTarget: _getFieldNameFromFkColumn(
                fk1.originalColumns.first,
              ), // e.g. "book"
            ),
          );
        }
      } else if (!isJunction) {
        // Only process one-to-many for non-junction tables
        // --- Handle One-to-Many ---
        for (final fkInOtherTable in table.foreignKeys) {
          // fkInOtherTable is on 'table'
          final referencedByThisFkTable =
              _tableMap[fkInOtherTable
                  .originalForeignTableName]; // This is the "one" side
          if (referencedByThisFkTable != null) {
            // 'table' is the "many" side. 'referencedByThisFkTable' is the "one" side.
            // We are adding a reverse relation to 'referencedByThisFkTable'.
            // The list in 'referencedByThisFkTable' model will contain models of 'table'.
            _addReverseRelation(
              targetTable: referencedByThisFkTable.originalName, // e.g., Author
              info: _ReverseRelationInfo(
                relationType: 'oneToMany',
                relatedTableName:
                    table
                        .originalName, // e.g., Book (the table that has the FK)
                relatedModelClassName: _getDartClassName(
                  table,
                ), // e.g., BookModel
                fieldNameInThisModel: _pluralize(
                  table.localName.camelCase,
                ), // e.g., "books"
                foreignKeyInRelatedTable: fkInOtherTable.originalColumns.first,
              ),
            );
          }
        }
      }
    }
  }

  void _addReverseRelation({
    required String targetTable,
    required _ReverseRelationInfo info,
  }) {
    if (!_reverseRelationsMap.containsKey(targetTable)) {
      _reverseRelationsMap[targetTable] = [];
    }
    // Avoid adding duplicate relations if schema has redundant constraints
    if (!_reverseRelationsMap[targetTable]!.any(
      (existing) => existing.fieldNameInThisModel == info.fieldNameInThisModel,
    )) {
      _reverseRelationsMap[targetTable]!.add(info);
    }
  }

  /// Heuristic to determine if a table is likely a junction table.
  bool _isJunctionTable(SupabaseTableInfo table) {
    // A table is considered a junction table if it has exactly two foreign keys
    // and a reasonably small number of columns (e.g., its own PK, the two FKs,
    // and maybe a timestamp or two).
    if (table.foreignKeys.length == 2) {
      // Adjust column count check as needed.
      // 2 columns: FK1, FK2 (composite PK)
      // 3 columns: PK, FK1, FK2 (like your book_genres)
      // 4 columns: PK, FK1, FK2, created_at
      // 5 columns: PK, FK1, FK2, created_at, updated_at
      if (table.columns.length >= 2 && table.columns.length <= 5) {
        // Optional: You could add a check to ensure the two FKs point to different tables
        // if you want to exclude self-referencing M2M relationships from this specific logic.
        // For example:
        // if (table.foreignKeys[0].originalForeignTableName == table.foreignKeys[1].originalForeignTableName) {
        //   return false; // It's a self-referencing M2M junction
        // }
        return true;
      }
    }
    return false;
  }

  void _writeHeader(StringBuffer buffer) {
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln(
      '// ignore_for_file: non_constant_identifier_names, duplicate_ignore',
    );
    buffer.writeln();
    buffer.writeln("import 'dart:convert';");
    buffer.writeln("import 'package:sqlite_async/sqlite3_common.dart';");
    buffer.writeln("import 'package:tether_libs/models/tether_model.dart';");
    buffer.writeln("import 'package:tether_libs/models/tether_model_input.dart';"); // Add this line
    buffer.writeln();
    // Potentially add imports for custom types if needed later
  }

  void _generateModelClass(StringBuffer buffer, SupabaseTableInfo table) {
    final className = _getDartClassName(table);
    final tableName = table.originalName;
    final pkColumns = table.primaryKeys;
    TetherColumnInfo? primaryKeyColumn;
    String idFieldName = 'id';
    String idDartType = 'dynamic';

    if (pkColumns.length == 1) {
      primaryKeyColumn = table.columns.firstWhereOrNull(
        (col) => col.originalName == pkColumns[0].originalName,
      );
      if (primaryKeyColumn != null) {
        idFieldName = primaryKeyColumn.localName.camelCase;
        idDartType = _mapPostgresToDartType(
          primaryKeyColumn.type,
          primaryKeyColumn.isNullable,
        );
      }
    }

    // Generate main model class
    buffer.writeln('/// Represents the `$tableName` table.');
    buffer.writeln('class $className extends TetherModel<$className> {');

    // --- Fields for table columns ---
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final dartType = _mapPostgresToDartType(column.type, column.isNullable);
      buffer.writeln('  final $dartType $fieldName;');
    }

    // --- Fields for FORWARD relationships (belongs-to) ---
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final relatedModelClassName = _getDartClassName(foreignTableInfo);
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        buffer.writeln('  final $relatedModelClassName? $fieldName;');
      }
    }

    // --- Fields for REVERSE relationships (has-many, has-many-through) ---
    final reverseRelations = _reverseRelationsMap[table.originalName] ?? [];
    for (final relation in reverseRelations) {
      final listFieldName = relation.fieldNameInThisModel;
      final itemModelClassName = relation.relatedModelClassName;
      buffer.writeln('  final List<$itemModelClassName>? $listFieldName;');
    }
    buffer.writeln();

    // --- Constructor ---
    buffer.writeln('  $className({');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      bool makeRequired = true; // Default to required

      // If the column is nullable, it's never required in the constructor.
      if (column.isNullable) {
        makeRequired = false;
      } else {
        // If the column is not nullable, it's always required.
        // The assumption is that even non-nullable primary keys will be provided by the app.
        makeRequired = true;
      }

      final String constructorModifier = makeRequired ? 'required ' : '';
      buffer.writeln('    ${constructorModifier}this.$fieldName,');
    }
    // Forward relation fields (these are always nullable objects, so not 'required')
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        buffer.writeln('    this.$fieldName,');
      }
    }
    // Reverse relation fields (these are always nullable lists, so not 'required')
    for (final relation in reverseRelations) {
      final listFieldName = relation.fieldNameInThisModel;
      buffer.writeln('    this.$listFieldName,');
    }
    buffer.writeln('  }) : super({');

    // 1. Add direct column values, keyed by their original database column name.
    for (final col in table.columns) {
      // Use the existing localName.camelCase from SupabaseColumnInfo
      final dartFieldNameForColumnValue = col.localName.camelCase;
      buffer.writeln(
        "         '${col.originalName}': $dartFieldNameForColumnValue,",
      );
    }

    // 2. Add forward related model instances, keyed by the Dart field name for the relation.
    for (final fk in table.foreignKeys) {
      // Use the 1-argument version of _getFieldNameFromFkColumn defined in this class
      final dartRelationFieldName = _getFieldNameFromFkColumn(
        fk.originalColumns.first,
      );
      buffer.writeln(
        "         '$dartRelationFieldName': $dartRelationFieldName,",
      );
    }

    // 3. Add reverse related model lists, keyed by the Dart field name for the relation.
    // This uses the _reverseRelationsMap populated in _preprocessRelations
    final reverseRelationsForThisTable =
        _reverseRelationsMap[table.originalName] ?? [];
    for (final revRelInfo in reverseRelationsForThisTable) {
      final dartRelationFieldName =
          revRelInfo.fieldNameInThisModel; // e.g., "bookAuthors" or "books"
      buffer.writeln(
        "         '$dartRelationFieldName': $dartRelationFieldName,",
      );
    }

    buffer.writeln('       });');
    buffer.writeln();

    // --- ID Getter Implementation ---
    buffer.writeln('  /// The primary key for this model instance.');
    buffer.writeln('  @override');
    buffer.writeln('  $idDartType get localId => $idFieldName;');
    buffer.writeln();

    // --- Convenience Getter for M2M Target Models ---
    final Set<String> allFieldNamesForCollisionCheck = {};
    for (final column in table.columns) {
      allFieldNamesForCollisionCheck.add(column.localName.camelCase);
    }
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        allFieldNamesForCollisionCheck.add(
          _getFieldNameFromFkColumn(fk.originalColumns.first),
        );
      }
    }
    for (final relInfo in reverseRelations) {
      allFieldNamesForCollisionCheck.add(relInfo.fieldNameInThisModel);
    }

    final Set<String> m2mGetterNamesGeneratedSoFar = {};

    for (final relation in reverseRelations) {
      if (relation.relationType == 'manyToMany' &&
          relation.m2mTargetLinkGetterName != null &&
          relation.m2mTargetModelClassName != null &&
          relation.m2mJoinModelFieldNameForTarget != null) {
        String getterName = relation.m2mTargetLinkGetterName!;
        final String targetModelClassName = relation.m2mTargetModelClassName!;
        final String listFieldNameOfJoinModels =
            relation.fieldNameInThisModel; // e.g., bookAuthors
        final String fieldInJoinModel =
            relation.m2mJoinModelFieldNameForTarget!; // e.g. author

        // Check for conflict with existing fields or already generated M2M getters
        if (allFieldNamesForCollisionCheck.contains(getterName) ||
            m2mGetterNamesGeneratedSoFar.contains(getterName)) {
          // Attempt to create a unique name using the junction list field name's PascalCase
          String disambiguatedPart =
              relation
                  .fieldNameInThisModel
                  .pascalCase; // E.g. BookAuthors, PostFlags
          getterName =
              '${relation.m2mTargetLinkGetterName}From$disambiguatedPart';

          // Final check for the disambiguated name
          if (allFieldNamesForCollisionCheck.contains(getterName) ||
              m2mGetterNamesGeneratedSoFar.contains(getterName)) {
            _logger.warning(
              "Skipping M2M getter: Could not generate unique name for ${targetModelClassName}s via ${relation.relatedModelClassName} in ${table.localName.pascalCase}. Tried '$getterName'.",
            );
            continue; // Skip this getter
          }
        }

        // If we reach here, getterName is considered unique.
        m2mGetterNamesGeneratedSoFar.add(getterName);

        buffer.writeln(
          '  /// Convenience getter for direct access to ${targetModelClassName}s from the M2M relationship via `${listFieldNameOfJoinModels}`.',
        );
        buffer.writeln('  List<$targetModelClassName>? get $getterName {');
        buffer.writeln('    return $listFieldNameOfJoinModels');
        buffer.writeln(
          '        ?.map((joinModel) => joinModel.$fieldInJoinModel)',
        );
        buffer.writeln('        .nonNulls // From package:collection');
        buffer.writeln('        .toList();');
        buffer.writeln('  }');
        buffer.writeln();
      }
    }

    // --- fromJson Factory ---
    buffer.writeln(
      '  /// Creates an instance from a JSON map (e.g., from Supabase).',
    );
    buffer.writeln(
      '  factory $className.fromJson(Map<String, dynamic> json) {',
    );
    buffer.writeln('    return $className(');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final jsonKey =
          column.originalName; // This is already snake_case (original DB name)
      buffer.write('      $fieldName: ');
      _generateFromJsonConversion(
        buffer,
        column,
        jsonKey,
        mapVariableName: 'json',
      );
      buffer.writeln(',');
    }
    // Forward relation fields
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final relatedModelClassName = _getDartClassName(foreignTableInfo);
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        // Use the original foreign table name (snake_case) as the JSON key,
        // or a specifically defined alias if your Supabase query uses one.
        // For direct FK relations, Supabase often returns the related object
        // keyed by the foreign table's name (snake_case) or the FK column name (if not ambiguous).
        // The SupabaseSelectBuilderBase now uses snake_case(jsonKeyFromBuilder)
        // where jsonKeyFromBuilder is often the Dart field name.
        // So, we need to convert the Dart fieldName (camelCase) to snake_case for the JSON key.
        final jsonKeyForRelatedObject = fieldName.snakeCase;
        buffer.writeln(
          '      $fieldName: json[\'$jsonKeyForRelatedObject\'] == null ? null : $relatedModelClassName.fromJson(json[\'$jsonKeyForRelatedObject\'] as Map<String, dynamic>),',
        );
      }
    }
    // Reverse relation fields
    for (final relation in reverseRelations) {
      final listFieldName =
          relation.fieldNameInThisModel; // This is camelCase (e.g., bookGenres)
      final itemModelClassName =
          relation.relatedModelClassName; // Junction model for M2M
      // The JSON key from Supabase for reverse relations (lists of related objects)
      // is typically the snake_case version of the target table name or the alias used in the select query.
      // SupabaseSelectBuilderBase uses snake_case(jsonKeyFromBuilder) for these aliases.
      // The jsonKeyFromBuilder is often the Dart field name (listFieldName).
      final jsonKeyForReverseRelation = listFieldName.snakeCase;
      buffer.writeln(
        '      $listFieldName: (json[\'$jsonKeyForReverseRelation\'] as List<dynamic>?)?.map((e) => $itemModelClassName.fromJson(e as Map<String, dynamic>)).toList(),',
      );
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();

    // --- fromSqlite Factory ---
    buffer.writeln(
      '  /// Creates an instance from a map (e.g., from SQLite row containing nested JSON in \'jsobjects\' column).',
    );
    buffer.writeln(
      '  factory $className.fromSqlite(Row row) {',
    ); // Input is a SQLite Row

    // Assumes the JSON data is in a column named 'jsobjects'
    buffer.writeln(
      "    final String? jsonDataString = row['jsobjects'] as String?;",
    );
    buffer.writeln("    if (jsonDataString == null) {");
    buffer.writeln(
      "      // Or handle as an error, depending on expected data integrity. This might lead to issues if fields are required.",
    );
    buffer.writeln("      // For example, you could throw an exception: ");
    buffer.writeln(
      "      // throw ArgumentError('SQLite row is missing \'jsobjects\' column for $className deserialization.');",
    );
    buffer.writeln(
      "      // Alternatively, if a model can be validly empty or with all nulls (if fields allow):",
    );
    buffer.writeln(
      "      // return $className(/* pass all nulls or default values if constructor allows */);",
    );
    buffer.writeln(
      "      // For now, we'll create an empty map, and let constructor validation handle missing required fields.",
    );
    buffer.writeln("    }");
    buffer.writeln(
      "    final Map<String, dynamic> json = jsonDataString == null ? <String, dynamic>{} : jsonDecode(jsonDataString) as Map<String, dynamic>;",
    );
    buffer.writeln();

    buffer.writeln('    return $className(');

    // Populate direct columns from the parsed 'json' map
    // The conversion logic should treat values within this 'json' map as if they came from a direct JSON source (not raw SQLite types)
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final jsonKey =
          column.originalName; // Key within the 'json' map (already snake_case)
      buffer.write('      $fieldName: ');
      _generateFromJsonConversion(
        buffer,
        column,
        jsonKey,
        mapVariableName: 'json',
        fromSqlite: false,
      ); // fromSqlite is false because 'json' map contains parsed JSON values
      buffer.writeln(',');
    }

    // Populate forward relation fields from the parsed 'json' map
    // This logic is similar to how it's done in the .fromJson factory
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final relatedModelClassName = _getDartClassName(foreignTableInfo);
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        // The key for the related object in the JSON (jsonKeyForRelatedObject)
        // should match how it's structured by SupabaseSelectBuilderBase._buildRecursiveJson
        // which uses the snake_case(fieldName) as the key for the nested object.
        final jsonKeyForRelatedObject = fieldName.snakeCase;
        buffer.writeln(
          '      $fieldName: json[\'$jsonKeyForRelatedObject\'] == null ? null : $relatedModelClassName.fromJson(json[\'$jsonKeyForRelatedObject\'] as Map<String, dynamic>),',
        );
      }
    }

    // Populate reverse relation fields from the parsed 'json' map (from 'jsobjects')
    // This assumes 'jsobjects' contains the fully nested structure.
    for (final relation in reverseRelations) {
      final listFieldName =
          relation.fieldNameInThisModel; // This is camelCase (e.g., bookGenres)
      final itemModelClassName =
          relation
              .relatedModelClassName; // Junction model for M2M or target model for 1-M
      // The JSON key from 'jsobjects' for reverse relations
      // should match the key used when serializing to 'jsobjects'.
      // This typically aligns with the snake_case version of the Dart field name.
      final jsonKeyForReverseRelation = listFieldName.snakeCase;
      buffer.writeln(
        '      $listFieldName: (json[\'$jsonKeyForReverseRelation\'] as List<dynamic>?)?.map((e) => $itemModelClassName.fromJson(e as Map<String, dynamic>)).toList(),',
      );
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();

    // --- toJson Method ---
    buffer.writeln('  /// Converts the instance to a JSON map (for Supabase).');
    buffer.writeln('  @override');
    buffer.writeln('  Map<String, dynamic> toJson() {');
    buffer.writeln('    final map = <String, dynamic>{};'); // Use a local map
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final jsonKey =
          column.originalName; // This is the snake_case DB column name

      // Only include the column if its corresponding Dart field is not null,
      // OR if the column itself is not nullable in the DB (meaning it must be sent).
      // This prevents sending explicit nulls for fields that were never set
      // and are nullable in the DB, allowing the DB to use its default if any.
      // However, for inserts, Supabase often requires all non-defaulted, non-nullable columns.
      // A simpler approach for toJson for Supabase is to send all owned columns,
      // and let Supabase handle nulls for nullable fields if the Dart field is null.

      buffer.write('    map[\'$jsonKey\'] = ');
      _generateToJsonConversion(buffer, column, fieldName, target: 'json');
      buffer.writeln(';');
    }
    // DO NOT include forward or reverse relation fields in toJson for Supabase inserts/updates.
    // These are handled by separate operations or by Supabase's relational insert features
    // if you structure your JSON payload in a specific way (which this toJson is not currently doing).
    // For a simple toJson for a single table row, only include its direct columns.

    buffer.writeln('    return map;');
    buffer.writeln('  }');
    buffer.writeln();

    // --- toSqlite Method ---
    buffer.writeln(
      '  /// Converts the instance to a map suitable for SQLite insertion/update.',
    );
    buffer.writeln('  @override');
    buffer.writeln('  Map<String, dynamic> toSqlite() {');
    buffer.writeln('    return {');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final dbKey = column.originalName;
      buffer.write('      \'$dbKey\': ');
      _generateToJsonConversion(buffer, column, fieldName, target: 'sqlite');
      buffer.writeln(',');
    }
    // Related objects (forward or reverse) are not typically part of the main table's toSqlite map.
    // The foreign key IDs are already included via the column iteration.
    buffer.writeln('    };');
    buffer.writeln('  }');
    buffer.writeln();

    // --- toInput Method ---
    final inputClassName = _getInputClassName(className);
    buffer.writeln('  /// Creates an input object for operations like insert, update, upsert.');
    buffer.writeln('  @override'); 
    buffer.writeln('  $inputClassName toInput() {');
    buffer.writeln('    return $inputClassName(');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      buffer.writeln('      $fieldName: $fieldName,');
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();

    // --- copyWith Method ---
    buffer.writeln(
      '  /// Creates a copy of this instance with potentially modified fields.',
    );
    buffer.writeln('  @override');
    buffer.writeln('  $className copyWith({');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final dartType = _mapPostgresToDartType(column.type, column.isNullable);
      buffer.writeln(
        '    $dartType${dartType.endsWith('?') ? '' : '?'} $fieldName,',
      );
    }
    // Forward relation fields
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final relatedModelClassName = _getDartClassName(foreignTableInfo);
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        buffer.writeln('    $relatedModelClassName? $fieldName,');
      }
    }
    // Reverse relation fields
    for (final relation in reverseRelations) {
      final listFieldName = relation.fieldNameInThisModel;
      final itemModelClassName = relation.relatedModelClassName;
      buffer.writeln('    List<$itemModelClassName>? $listFieldName,');
    }
    buffer.writeln('  }) {');
    buffer.writeln('    return $className(');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      buffer.writeln('      $fieldName: $fieldName ?? this.$fieldName,');
    }
    // Forward relation fields
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        buffer.writeln('      $fieldName: $fieldName ?? this.$fieldName,');
      }
    }
    // Reverse relation fields
    for (final relation in reverseRelations) {
      final listFieldName = relation.fieldNameInThisModel;
      buffer.writeln(
        '      $listFieldName: $listFieldName ?? this.$listFieldName,',
      );
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();

    // --- toString Method ---
    buffer.writeln('  @override');
    buffer.writeln('  String toString() {');
    buffer.write("    return '$className(");
    bool firstFieldToString = true;
    for (final column in table.columns) {
      if (!firstFieldToString) buffer.write(', ');
      final fieldName = column.localName.camelCase;
      buffer.write('$fieldName: \$$fieldName');
      firstFieldToString = false;
    }
    // Forward relation fields
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        if (!firstFieldToString) buffer.write(', ');
        final fieldNameFK = _getFieldNameFromFkColumn(fk.originalColumns.first);
        buffer.write('$fieldNameFK: \$$fieldNameFK');
        firstFieldToString = false;
      }
    }
    // Reverse relation fields
    for (final relation in reverseRelations) {
      if (!firstFieldToString) buffer.write(', ');
      final fieldName = relation.fieldNameInThisModel;
      buffer.write('$fieldName: \$$fieldName');
      firstFieldToString = false;
    }
    buffer.writeln(")';");
    buffer.writeln('  }');

    buffer.writeln('}'); // End class $className

    // Generate the companion ModelInput class
    _generateModelInputClass(buffer, table, className);
  }

  /// Generates a companion Input class for a model
  void _generateModelInputClass(StringBuffer buffer, SupabaseTableInfo table, String modelClassName) {
    final inputClassName = _getInputClassName(modelClassName);
    
    buffer.writeln();
    buffer.writeln('/// Input class for `$modelClassName` operations (insert, update, upsert).');
    buffer.writeln('/// All fields are optional for flexibility in partial updates.');
    buffer.writeln('class $inputClassName extends TetherModelInput<$inputClassName, $modelClassName> {');

    // --- Fields for table columns only (no relationships) ---
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      // Make all types nullable by ensuring they end with '?'
      final dartType = _mapPostgresToDartType(column.type, true); // Force nullable
      buffer.writeln('  final $dartType $fieldName;');
    }
    buffer.writeln();

    // --- Constructor with all optional parameters ---
    buffer.writeln('  $inputClassName({');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      buffer.writeln('    this.$fieldName,');
    }
    buffer.writeln('  });');
    buffer.writeln();

    // --- Factory Constructor from model instance ---
    buffer.writeln('  /// Creates an input object from a model instance.');
    buffer.writeln('  factory $inputClassName.fromModel($modelClassName model) {');
    buffer.writeln('    return $inputClassName(');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      buffer.writeln('      $fieldName: model.$fieldName,');
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();

    // --- toJson Method (for Supabase) ---
    buffer.writeln('  @override');
    buffer.writeln('  Map<String, dynamic> toJson() {');
    buffer.writeln('    final map = <String, dynamic>{};');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final jsonKey = column.originalName; // DB column name (snake_case)
      buffer.writeln('    if ($fieldName != null) {');
      
      // Handle type-specific conversions just like in the model's toJson
      final pgType = column.type.toLowerCase();
      if (pgType.startsWith('timestamp') || pgType == 'date') {
        buffer.writeln('      map[\'$jsonKey\'] = $fieldName?.toIso8601String();');
      } else if (pgType == 'json' || pgType == 'jsonb') {
        buffer.writeln('      map[\'$jsonKey\'] = $fieldName;');
      } else if (pgType.endsWith('[]')) {
        buffer.writeln('      map[\'$jsonKey\'] = $fieldName;');
      } else {
        buffer.writeln('      map[\'$jsonKey\'] = $fieldName;');
      }
      
      buffer.writeln('    }');
    }
    buffer.writeln('    return map;');
    buffer.writeln('  }');
    buffer.writeln();

    // --- toSqliteMap Method ---
    buffer.writeln('  @override');
    buffer.writeln('  Map<String, dynamic> toSqliteMap() {');
    buffer.writeln('    final map = <String, dynamic>{};');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final sqliteKey = column.originalName; // Use DB column name for consistency
      buffer.writeln('    if ($fieldName != null) {');
      
      // Handle type-specific conversions for SQLite
      final pgType = column.type.toLowerCase();
      if (pgType.startsWith('timestamp') || pgType == 'date') {
        buffer.writeln('      map[\'$sqliteKey\'] = $fieldName?.toIso8601String();');
      } else if (pgType == 'boolean' || pgType == 'bool') {
        buffer.writeln('      map[\'$sqliteKey\'] = $fieldName == null ? null : ($fieldName! ? 1 : 0);');
      } else if (pgType == 'json' || pgType == 'jsonb' || pgType.endsWith('[]')) {
        buffer.writeln('      map[\'$sqliteKey\'] = jsonEncode($fieldName);');
      } else {
        buffer.writeln('      map[\'$sqliteKey\'] = $fieldName;');
      }
      
      buffer.writeln('    }');
    }
    buffer.writeln('    return map;');
    buffer.writeln('  }');
    buffer.writeln();

    // --- copyWith Method ---
    buffer.writeln('  @override');
    buffer.writeln('  $inputClassName copyWith({');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      // All parameters already nullable, no need for extra '?'
      final dartType = _mapPostgresToDartType(column.type, true);
      buffer.writeln('    $dartType $fieldName,');
    }
    buffer.writeln('  }) {');
    buffer.writeln('    return $inputClassName(');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      buffer.writeln('      $fieldName: $fieldName ?? this.$fieldName,');
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
    buffer.writeln();
    
    // --- toString Method ---
    buffer.writeln('  @override');
    buffer.writeln('  String toString() {');
    buffer.write("    return '$inputClassName(");
    bool firstField = true;
    for (final column in table.columns) {
      if (!firstField) buffer.write(', ');
      final fieldName = column.localName.camelCase;
      buffer.write('$fieldName: \$$fieldName');
      firstField = false;
    }
    buffer.writeln(")';");
    buffer.writeln('  }');

    buffer.writeln('}'); // End class ModelInput
  }

  /// Generates the Dart code snippet for converting a JSON/DB value to the field type.
  void _generateFromJsonConversion(
    StringBuffer buffer,
    TetherColumnInfo column,
    String key, {
    String mapVariableName = 'json',
    bool fromSqlite = false,
  }) {
    final pgType = column.type.toLowerCase();
    final isNullable = column.isNullable;
    final valueAccess =
        isNullable ? "$mapVariableName['$key']" : "$mapVariableName['$key']!";

    if (isNullable) {
      buffer.write("$mapVariableName['$key'] == null ? null : ");
    }

    if (pgType.startsWith('timestamp')) {
      buffer.write("DateTime.parse($valueAccess as String)");
    } else if (pgType == 'date') {
      buffer.write("DateTime.parse($valueAccess as String)");
    } else if (pgType == 'uuid') {
      buffer.write("$valueAccess as String");
    } else if (pgType.startsWith('int') ||
        pgType == 'serial' ||
        pgType == 'smallint' ||
        pgType == 'bigint') {
      buffer.write("$valueAccess as int");
    } else if (pgType.startsWith('float') ||
        pgType == 'real' ||
        pgType == 'double precision' ||
        pgType.startsWith('numeric') ||
        pgType.startsWith('decimal')) {
      buffer.write("($valueAccess as num).toDouble()");
    } else if (pgType == 'boolean' || pgType == 'bool') {
      if (fromSqlite) {
        buffer.write("($valueAccess as int) == 1");
      } else {
        buffer.write("$valueAccess as bool");
      }
    } else if (pgType == 'json' || pgType == 'jsonb') {
      if (fromSqlite) {
        buffer.write(
          "jsonDecode($valueAccess as String) as Map<String, dynamic>",
        );
      } else {
        buffer.write(
          "($valueAccess is Map<String, dynamic> ? $valueAccess : jsonDecode($valueAccess as String) as Map<String, dynamic>)",
        );
      }
    } else if (pgType == 'array') {
      // Handles generic 'array' type (implicitly List<String>)
      if (fromSqlite) {
        // Assumes SQLite stores the array as a JSON string
        buffer.write(
          "List<String>.from((jsonDecode($valueAccess as String) as List<dynamic>).map((e) => e as String))",
        );
      } else {
        // Assumes JSON from Supabase might be a List<dynamic> or a String to be decoded
        buffer.write(
          "($valueAccess is List<dynamic> ? List<String>.from($valueAccess.map((e) => e as String)) : List<String>.from((jsonDecode($valueAccess as String) as List<dynamic>).map((e) => e as String)))",
        );
      }
    } else if (pgType.endsWith('[]')) {
      // Handles specific arrays like 'text[]', 'integer[]'
      String basePgType = pgType.substring(0, pgType.length - 2);
      String dartListElementType = _mapPostgresToDartType(basePgType, false);

      if (fromSqlite) {
        buffer.write(
          "List<$dartListElementType>.from((jsonDecode($valueAccess as String) as List<dynamic>).map((e) => e as $dartListElementType))",
        );
      } else {
        // Assumes JSON from Supabase might be a List<dynamic> or a String to be decoded
        buffer.write(
          "($valueAccess is List<dynamic> ? List<$dartListElementType>.from(($valueAccess as List<dynamic>).map((e) => e as $dartListElementType)) : List<$dartListElementType>.from((jsonDecode($valueAccess as String) as List<dynamic>).map((e) => e as $dartListElementType)))",
        );
      }
    } else if (pgType == 'text' ||
        pgType.startsWith('varchar') ||
        pgType.startsWith('char')) {
      buffer.write("$valueAccess as String");
    } else {
      _logger.warning(
        "Unrecognized PostgreSQL type '${column.type}' for column '${column.originalName}'. Treating as String. Adjust manually if needed.",
      );
      buffer.write("$valueAccess as String"); // Default fallback
    }
  }

  /// Generates the Dart code snippet for converting a field value to JSON or SQLite map value.
  void _generateToJsonConversion(
    StringBuffer buffer,
    TetherColumnInfo column,
    String fieldName, {
    required String target, // 'json' or 'sqlite'
  }) {
    final pgType = column.type.toLowerCase();
    final isNullable = column.isNullable;
    // Use null-aware access if nullable for intermediate steps
    final valueAccess = isNullable ? "$fieldName?" : fieldName;

    if (pgType.startsWith('timestamp') || pgType == 'date') {
      // JSON: ISO8601 string
      // SQLite: ISO8601 string (common practice)
      buffer.write("$valueAccess.toIso8601String()");
    } else if (pgType == 'boolean' || pgType == 'bool') {
      if (target == 'sqlite') {
        // SQLite: 0 or 1 integer
        buffer.write(
          isNullable
              ? "$fieldName == null ? null : ($fieldName! ? 1 : 0)"
              : "$fieldName ? 1 : 0",
        );
      } else {
        // JSON: true or false boolean
        buffer.write(fieldName);
      }
    } else if (pgType == 'json' || pgType == 'jsonb' || pgType.endsWith('[]')) {
      if (target == 'sqlite') {
        // SQLite: Store as JSON encoded string
        buffer.write(
          isNullable
              ? "$fieldName == null ? null : jsonEncode($fieldName)"
              : "jsonEncode($fieldName)",
        );
      } else {
        // JSON (Supabase): Handles Map/List directly
        buffer.write(fieldName);
      }
    }
    // --- Default for primitives (int, double, String, uuid) ---
    else {
      buffer.write(fieldName); // Most other types map directly for both targets
    }
  }

  /// Maps PostgreSQL type names to Dart type names.
  String _mapPostgresToDartType(String pgType, bool isNullable) {
    String baseType;
    pgType = pgType.toLowerCase();

    if (pgType.endsWith('[]')) {
      // Handle array types like text[], integer[]
      final elementType = pgType.substring(0, pgType.length - 2);
      final dartElementType = _mapPostgresToDartType(
        elementType,
        false,
      ); // Array elements are non-nullable within the list
      baseType = 'List<$dartElementType>';
    } else if (pgType == 'array') {
      _logger.info(
        "Mapping PostgreSQL type 'array' to 'List<string>'. For specific element types, schema should ideally provide e.g., 'text[]' or the internal '_text' format.",
      );
      baseType = 'List<String>';
    } else if (pgType.startsWith('timestamp') || pgType == 'date') {
      baseType = 'DateTime';
    } else if (pgType == 'uuid') {
      baseType = 'String'; // Represent UUIDs as Strings
    } else if (pgType.startsWith('int') ||
        pgType == 'serial' ||
        pgType == 'smallint' ||
        pgType == 'bigint') {
      baseType = 'int';
    } else if (pgType.startsWith('float') ||
        pgType == 'real' ||
        pgType == 'double precision' ||
        pgType.startsWith('numeric') ||
        pgType.startsWith('decimal')) {
      baseType = 'double';
    } else if (pgType == 'boolean' || pgType == 'bool') {
      baseType = 'bool';
    } else if (pgType == 'json' || pgType == 'jsonb') {
      baseType = 'Map<String, dynamic>';
    } else if (pgType == 'text' ||
        pgType.startsWith('varchar') ||
        pgType.startsWith('char')) {
      baseType = 'String';
    } else {
      _logger.warning(
        "Unmapped PostgreSQL type: '$pgType'. Defaulting to String.",
      );
      baseType = 'String'; // Default fallback
    }

    return isNullable ? '$baseType?' : baseType;
  }

  /// Gets the Dart class name for a table based on config prefix/suffix.
  String _getDartClassName(SupabaseTableInfo table) {
    // Use the safe local name (already handles Dart keywords/built-ins)
    // Apply prefix and suffix from config
    final prefix = config.modelPrefix ?? '';
    final suffix =
        config.modelSuffix ?? 'Model'; // Default suffix if not provided
    // Ensure PascalCase for the base name before adding prefix/suffix
    return '$prefix${singularize(table.localName.pascalCase)}$suffix';
  }

  /// Gets the Dart input class name for a model based on config prefix/suffix.
  String _getInputClassName(String modelClassName) {
    // Check if model class name ends with 'Model' suffix
    if (modelClassName.endsWith('Model')) {
      // Remove 'Model' suffix and add 'Input' instead
      return '${modelClassName.substring(0, modelClassName.length - 5)}Input';
    }
    // If no 'Model' suffix, just append 'Input'
    return '${modelClassName}Input';
  }

  /// Simple pluralization (add 's' unless ends in 's'). Basic, improve if needed.
  String _pluralize(String word) {
    if (word.isEmpty) return word;
    if (word.endsWith('s')) return word;
    // Handle 'y' -> 'ies' (basic)
    if (word.endsWith('y') &&
        word.length > 1 &&
        !'aeiou'.contains(word[word.length - 2].toLowerCase())) {
      return '${word.substring(0, word.length - 1)}ies';
    }
    return '${word}s';
  }
} // End ModelGenerator class

