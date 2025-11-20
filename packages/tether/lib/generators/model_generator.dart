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
      '// ignore_for_file: unused_import, prefer_relative_imports, prefer_const_constructors',
    );
    buffer.writeln();
    buffer.writeln("import 'dart:convert';");
    buffer.writeln("import 'package:equatable/equatable.dart';");
    buffer.writeln("import 'package:sqlite_async/sqlite3_common.dart';");
    buffer.writeln("import 'package:tether_libs/models/tether_model.dart';");
    buffer.writeln("import 'package:tether_libs/models/tether_model_input.dart';"); // Add this line
    buffer.writeln("import 'package:tether_libs/models/geojson.dart';");
    buffer.writeln("import 'package:tether_libs/models/row_utils.dart';");
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
      primaryKeyColumn = pkColumns.first;
      idFieldName = primaryKeyColumn.localName.camelCase;
      idDartType = _mapPostgresToDartType(primaryKeyColumn.type, false);
    }

    // Generate main model class
    buffer.writeln('/// Represents the `$tableName` table.');
    buffer.writeln('class $className extends TetherModel<$className> with EquatableMixin {');

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
        buffer.writeln('  $relatedModelClassName? $fieldName;');
      }
    }

    // --- Fields for REVERSE relationships (has-many, has-many-through) ---
    final reverseRelations = _reverseRelationsMap[table.originalName] ?? [];
    for (final relation in reverseRelations) {
      final listFieldName = relation.fieldNameInThisModel;
      final itemModelClassName = relation.relatedModelClassName;
      buffer.writeln('  List<$itemModelClassName>? $listFieldName;');
    }
    buffer.writeln();

    // --- Constructor ---
    final Map<String, String> initializerListFields = {};
    buffer.writeln('  $className({');
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      bool makeRequired = true;
      String? defaultValueDart;

      // Check for default value on non-nullable columns
      if (!column.isNullable && column.defaultValue != null) {
        defaultValueDart = _convertDefaultValueToDart(column);
        // If we have a valid Dart default, the field is not required in the constructor
        if (defaultValueDart != null) {
          makeRequired = false;
          initializerListFields[fieldName] = defaultValueDart;
        }
      }

      // If the column is nullable, it's never required in the constructor.
      if (column.isNullable) {
        makeRequired = false;
      }

      if (makeRequired) {
        buffer.writeln('    required this.$fieldName,');
      } else {
        // The parameter should still be `this.fieldName`.
        // The initializer list will handle the default value.
        if (defaultValueDart != null && !defaultValueDart.contains('DateTime')) {
          buffer.writeln('    this.$fieldName = $defaultValueDart,');
        } else if (defaultValueDart != null && defaultValueDart.contains('DateTime')) {
          buffer.writeln('    DateTime? $fieldName,');
        } else {
          buffer.writeln('    this.$fieldName,');
        }
      }
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
    buffer.write('  })');

    // Build the initializer list
    final List<String> initializers = [];
    initializerListFields.forEach((fieldName, defaultValue) {
      if (defaultValue.contains('DateTime')) {
        initializers.add('this.$fieldName = $fieldName ?? $defaultValue');
      }
    });

    // Build the map for the super constructor
    final superInitializerMap = <String>[];
    for (final col in table.columns) {
      final dartFieldNameForColumnValue = col.localName.camelCase;
      superInitializerMap.add(
        "'${col.originalName}': $dartFieldNameForColumnValue",
      );
    }
    for (final fk in table.foreignKeys) {
      final dartRelationFieldName = _getFieldNameFromFkColumn(
        fk.originalColumns.first,
      );
      superInitializerMap.add(
        "'$dartRelationFieldName': $dartRelationFieldName",
      );
    }
    final reverseRelationsForThisTable =
        _reverseRelationsMap[table.originalName] ?? [];
    for (final revRelInfo in reverseRelationsForThisTable) {
      final dartRelationFieldName = revRelInfo.fieldNameInThisModel;
      superInitializerMap.add(
        "'$dartRelationFieldName': $dartRelationFieldName",
      );
    }
    initializers.add('super({${superInitializerMap.join(', ')}})');

    buffer.writeln(' : ${initializers.join(',\n       ')};');
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

    // --- Start: New logic for reading from individual columns and jsobjects ---
    buffer.writeln();
    // --- End: New logic ---

    buffer.writeln('    return $className(');

    // Populate direct columns by reading from the SQLite 'row' directly
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final dbKey = column.originalName; // Key in the SQLite row
      buffer.write('      $fieldName: ');
      _generateFromJsonConversion(
        buffer,
        column,
        dbKey,
        mapVariableName: 'row',
        fromSqlite: true, // Correctly set to true
      );
      buffer.writeln(',');
    }

    // Populate forward relation fields from the parsed 'json' map (from 'jsobjects')
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
          '      $fieldName: row[\'$jsonKeyForRelatedObject\'] == null ? null : $relatedModelClassName.fromSqlite(createRowFromMap(row[\'$jsonKeyForRelatedObject\'] as Map<String, dynamic>)),',
        );
      }
    }

    // Populate reverse relation fields from the parsed 'json' map (from 'jsobjects')
    for (final relation in reverseRelations) {
      final listFieldName =
          relation.fieldNameInThisModel; // This is camelCase (e.g., bookGenres)
      final itemModelClassName =
          relation
              .relatedModelClassName; // Junction model for M2M or target model for 1-M
      final jsonKeyForReverseRelation = listFieldName.snakeCase;
      buffer.writeln(
        '      $listFieldName: (row[\'$jsonKeyForReverseRelation\'] as List<dynamic>?)?.map((e) => $itemModelClassName.fromSqlite(createRowFromMap(e as Map<String, dynamic>))).toList(),',
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
    buffer.writeln('    return $inputClassName.fromModel(this);');
    buffer.writeln('  }');
    buffer.writeln();

    // --- copyWith Method ---
    buffer.writeln('  /// Creates a new instance of [$className] with updated fields.');
    buffer.writeln('  $className copyWith({');
    // 1. Parameters for columns
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final dartType = _mapPostgresToDartType(column.type, true); // Nullable for copyWith
      buffer.writeln('    $dartType $fieldName,');
    }
    // 2. Parameters for forward relationships
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final relatedModelClassName = _getDartClassName(foreignTableInfo);
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        buffer.writeln('    $relatedModelClassName? $fieldName,');
      }
    }
    // 3. Parameters for reverse relationships
    // final reverseRelations = _reverseRelationsMap[table.originalName] ?? [];
    for (final relation in reverseRelations) {
      final listFieldName = relation.fieldNameInThisModel;
      final itemModelClassName = relation.relatedModelClassName;
      buffer.writeln('    List<$itemModelClassName>? $listFieldName,');
    }
    buffer.writeln('  }) {');
    buffer.writeln('    return $className(');
    // 1. Assign column values
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      buffer.writeln('      $fieldName: $fieldName ?? this.$fieldName,');
    }
    // 2. Assign forward relationship values
    for (final fk in table.foreignKeys) {
      final foreignTableInfo = _tableMap[fk.originalForeignTableName];
      if (foreignTableInfo != null) {
        final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
        buffer.writeln('      $fieldName: $fieldName ?? this.$fieldName,');
      }
    }
    // 3. Assign reverse relationship values
    for (final relation in reverseRelations) {
      final listFieldName = relation.fieldNameInThisModel;
      buffer.writeln('      $listFieldName: $listFieldName ?? this.$listFieldName,');
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
      buffer.write('${column.localName.camelCase}: \$${column.localName.camelCase}');
      firstField = false;
    }
    buffer.writeln(")';");
    buffer.writeln('  }');

    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  List<Object?> get props => [');
    for (final column in table.columns) {
      buffer.writeln('        ${column.localName.camelCase},');
    }
    for (final fk in table.foreignKeys) {
      final fieldName = _getFieldNameFromFkColumn(fk.originalColumns.first);
      buffer.writeln('        $fieldName,');
    }
    for (final relation in reverseRelations) {
      buffer.writeln('        ${relation.fieldNameInThisModel},');
    }
    buffer.writeln('      ];');

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
    buffer.writeln('class $inputClassName extends TetherModelInput<$inputClassName, $modelClassName> with EquatableMixin {');

    // --- Fields for table columns only (no relationships) ---
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final pgType = column.type.toLowerCase();
      String dartType;

      if (pgType == 'geometry') {
        dartType = 'String?'; // Accept a string for geometry input
      } else {
        // Make all other types nullable
        dartType = _mapPostgresToDartType(column.type, true);
      }
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
      final pgType = column.type.toLowerCase();
      if (pgType == 'geometry') {
        // Convert the GeoJson object from the model to a WKB string for the input object.
        buffer.writeln('      $fieldName: model.$fieldName?.toWKB(),');
      } else {
        buffer.writeln('      $fieldName: model.$fieldName,');
      }
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
      } else if (pgType == 'geometry') {
        // The input is a string, which we assume is a valid GeoJSON string
        // that Supabase can process directly.
        buffer.writeln('      map[\'$jsonKey\'] = $fieldName;');
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
      } else if (pgType == 'geometry') {
        // The input is a string, which can be stored directly in SQLite.
        buffer.writeln('      map[\'$sqliteKey\'] = $fieldName;');
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
    buffer.writeln('  /// Creates a new instance of [$inputClassName] with updated fields.');
    buffer.writeln('  @override');
    buffer.writeln('  $inputClassName copyWith({');
    // Parameters for columns ONLY. No relationships in Input classes.
    for (final column in table.columns) {
      final fieldName = column.localName.camelCase;
      final pgType = column.type.toLowerCase();
      String dartType;

      if (pgType == 'geometry') {
        dartType = 'String?';
      } else {
        dartType = _mapPostgresToDartType(column.type, true); // Nullable for copyWith
      }
      buffer.writeln('    $dartType $fieldName,');
    }
    buffer.writeln('  }) {');
    buffer.writeln('    return $inputClassName(');
    // Assign column values ONLY.
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
      buffer.write('${column.localName.camelCase}: \$${column.localName.camelCase}');
      firstField = false;
    }
    buffer.writeln(")';");
    buffer.writeln('  }');

    buffer.writeln();
    buffer.writeln('  @override');
    buffer.writeln('  List<Object?> get props => [');
    for (final column in table.columns) {
      buffer.writeln('        ${column.localName.camelCase},');
    }
    buffer.writeln('      ];');

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
    final hasDefault = !isNullable && column.defaultValue != null && _convertDefaultValueToDart(column) != null;

    // If the field has a default value in the constructor, we should not use '!'
    // because the key might be missing, and we want to rely on the default.
    // We cast to nullable and provide the model's default via the ?? operator.
    final valueAccess = (isNullable || hasDefault)
        ? "$mapVariableName['$key']"
        : "$mapVariableName['$key']!";

    if (hasDefault) {
      buffer.write("$mapVariableName['$key'] == null ? ${_convertDefaultValueToDart(column)} : ");
    }

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
      // When reading from SQLite, the value is an integer (0 or 1).
      // When reading from JSON, it's a boolean.
      buffer.write(
        fromSqlite
            ? "($valueAccess as int) == 1"
            : "$valueAccess as bool",
      );
    } else if (pgType == 'geometry') {
      if (fromSqlite) {
        buffer.write(
          "GeoJson.fromJson(jsonDecode($valueAccess as String) as Map<String, dynamic>)",
        );
      } else {
        buffer.write(
          "GeoJson.fromJson($valueAccess as Map<String, dynamic>)",
        );
      }
    } else if (pgType.endsWith('[]')) {
      // Handles specific arrays like 'text[]', 'integer[]', 'json[]', 'jsonb[]'
      String basePgType = pgType.substring(0, pgType.length - 2);
      String dartListElementType = _mapPostgresToDartType(basePgType, false);

      // Special handling for json/jsonb arrays to cast elements correctly
      String elementMapExpression;
      if (basePgType == 'json' || basePgType == 'jsonb') {
        elementMapExpression = '(e) => e as Map<String, dynamic>';
      } else {
        elementMapExpression = '(e) => e as $dartListElementType';
      }

      if (fromSqlite) {
        buffer.write(
          "List<$dartListElementType>.from((jsonDecode($valueAccess as String) as List<dynamic>).map($elementMapExpression))",
        );
      } else {
        // Assumes JSON from Supabase might be a List<dynamic> or a String to be decoded
        buffer.write(
          "($valueAccess is List<dynamic> ? List<$dartListElementType>.from(($valueAccess as List<dynamic>).map($elementMapExpression)) : List<$dartListElementType>.from((jsonDecode($valueAccess as String) as List<dynamic>).map($elementMapExpression)))",
        );
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
    } else if (pgType == 'geometry') {
      if (target == 'sqlite') {
        buffer.write(
          isNullable
              ? "$fieldName == null ? null : jsonEncode($fieldName?.toJson())"
              : "jsonEncode($fieldName.toJson())",
        );
      } else {
        buffer.write(
          isNullable
              ? "$fieldName?.toJson()"
              : "$fieldName.toJson()",
        );
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
    } else if (pgType == 'geometry') {
      baseType = 'GeoJson';
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

  /// Converts a string default value from the database schema to a Dart expression.
  String? _convertDefaultValueToDart(TetherColumnInfo column) {
    if (column.defaultValue == null) return null;

    String defaultValue = column.defaultValue!;
    final pgType = column.type.toLowerCase();

    // Handle now() for timestamps
    if (defaultValue.toLowerCase().contains('now()')) {
      return 'DateTime.now()';
    }

    // Handle booleans
    if (pgType == 'boolean' || pgType == 'bool') {
      if (defaultValue.toLowerCase() == 'true') return 'true';
      if (defaultValue.toLowerCase() == 'false') return 'false';
    }

    // Handle numeric types
    if (pgType.startsWith('int') || pgType == 'serial' || pgType == 'smallint' || pgType == 'bigint' || pgType.startsWith('float') || pgType == 'real' || pgType == 'double precision' || pgType.startsWith('numeric') || pgType.startsWith('decimal')) {
      if (num.tryParse(defaultValue) != null) {
        return defaultValue;
      }
    }

    // Handle string literals, which often come with casting like ::text
    final match = RegExp(r"^'([^']*)'::\w+").firstMatch(defaultValue);
    if (match != null) {
      return "'${match.group(1)}'";
    }
    
    // Handle simple quoted strings
    if (defaultValue.startsWith("'") && defaultValue.endsWith("'")) {
      return defaultValue;
    }

    // Fallback for other cases (e.g., empty array, empty json)
    if (defaultValue == "'{}'::jsonb" || defaultValue == "'{}'::json") return 'const {}';
    if (defaultValue == "'[]'::text[]") return 'const []';


    // If we can't determine a safe default, return null so the field remains required.
    _logger.info("Could not convert default value '$defaultValue' for column '${column.originalName}' to a Dart equivalent. Field will remain required.");
    return null;
  }
} // End ModelGenerator class

