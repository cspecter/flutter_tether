import 'dart:async';
import 'dart:developer';

import 'package:sqlite_async/sqlite_async.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'client_manager_models.dart';

class TetherClientReturn<TModel extends TetherModel<TModel>> {
  final List<TModel> data;
  final String? error;
  final int? count;

  TModel? get single =>
      data.isNotEmpty ? data.first : null;

  TetherClientReturn({required this.data, this.error, this.count});

  bool get hasError => error != null && error!.isNotEmpty;

  @override
  String toString() {
    return 'TetherClientReturn(data: $data, error: $error, count: $count)';
  }
}

class ClientManagerBase<TModel extends TetherModel<TModel>>
    implements Future<TetherClientReturn<TModel>> {
  final String tableName; // Simple table name, e.g., "books"
  final String localTableName;
  final SqliteDatabase localDb;
  final SupabaseClient client;
  final PostgrestBuilder supabase;
  final SqlOperationType? type;
  final SelectBuilderBase? selector;
  final bool syncWithSupabase;
  static const Duration defaultTimeout = Duration(seconds: 15);
  final Map<String, SupabaseTableInfo>
  tableSchemas; // Keys are fully qualified, e.g., "public.books"
  SelectBuilderBase? selectorStatement;
  SqlStatement? localQuery;
  bool maybeSingle;
  bool isRemoteOnly;
  bool isLocalOnly;
  final FromJsonFactory<TModel> fromJsonFactory;
  final FromSqliteFactory<TModel> fromSqliteFactory;

  ClientManagerBase({
    required this.tableName,
    required this.localTableName,
    required this.localDb,
    required this.supabase,
    required this.client,
    required this.tableSchemas,
    required this.fromJsonFactory,
    required this.fromSqliteFactory,
    this.type = SqlOperationType.select,
    this.selector,
    this.syncWithSupabase = true,
    this.localQuery,
    this.maybeSingle = false,
    this.isRemoteOnly = false,
    this.isLocalOnly = false,
    this.selectorStatement,
  });

  /// Generates a list of UPSERT SQL statements for nested data from a Supabase response.
  /// Each type of nested data will have its own UPSERT statement.
  Future<void> upsertSupabaseData(
    List<Map<String, dynamic>> supabaseResponse,
  ) async {
    if (supabaseResponse.isEmpty) {
      return;
    }

    try {
      // 1. Deserialize the root Supabase response into fully hydrated TModel instances.
      //    The fromJsonFactory (e.g., BookModel.fromJson) is responsible for
      //    deserializing its own fields and its nested related models.
      final List<TModel> rootModels =
          supabaseResponse.map((row) => fromJsonFactory(row)).toList();

      // Data structures for collecting models by their original table name.
      final Map<String, List<TetherModel<dynamic>>> modelsByTable = {};
      // Set to keep track of processed model instances to avoid cycles and redundant work.
      // Uses a composite key: "tableName_localId"
      final Set<String> processedModelKeys = {};

      // 2. Recursive helper to traverse the deserialized object graph.
      void _collectModelsRecursively(
        TetherModel<dynamic> currentModel,
        String currentModelOriginalTableName,
      ) {
        // Ensure localId is not null before creating the key.
        // If localId is null, we might not be able to uniquely identify it for processing avoidance,
        // but we should still process its data if it's a new object.
        // For now, we rely on localId for cycle detection.
        if (currentModel.localId == null) {
          // Potentially log or handle models without IDs if they are not expected
          // print("Warning: Model of type associated with table '$currentModelOriginalTableName' has null localId.");
        }

        final String modelKey =
            '${currentModelOriginalTableName}_${currentModel.localId}';

        if (currentModel.localId != null &&
            processedModelKeys.contains(modelKey)) {
          return; // Already processed this specific model instance
        }
        if (currentModel.localId != null) {
          processedModelKeys.add(modelKey);
        }

        // Add the current model to its respective table group.
        // The key for modelsByTable is the simple original table name (e.g., "books").
        (modelsByTable[currentModelOriginalTableName] ??= []).add(currentModel);

        // Get SupabaseTableInfo for the current model's table.
        // tableSchemas uses fully qualified names (e.g., "public.books").
        final SupabaseTableInfo? tableInfo =
            tableSchemas['public.$currentModelOriginalTableName'];

        if (tableInfo == null) {
          log(
            "Warning: Table info not found for 'public.$currentModelOriginalTableName' in _collectModelsRecursively. Skipping relations for this model.",
          );
          return;
        }

        // Traverse forward relations (e.g., a Book's Author)
        for (final fk in tableInfo.foreignKeys) {
          // The fieldName is the Dart field name in the model (e.g., "author").
          // This should match the key used in the model's `data` map passed to super()
          // if it holds instances of related models.
          final fieldName = _getFieldNameFromFkColumn(
            fk.originalColumns.first,
            fk.originalForeignTableName,
          );

          // The `currentModel.data` map, as populated by the model's constructor `super(data)`,
          // should contain the actual instances of related models if the generated
          // constructors pass them.
          final dynamic relatedData = currentModel.data[fieldName];

          if (relatedData is TetherModel) {
            _collectModelsRecursively(relatedData, fk.originalForeignTableName);
          }
        }
        log(
          "Processed model of type '$currentModelOriginalTableName' with localId '${currentModel.localId}'",
        );
        log('Table info reversed relations: ${tableInfo.reverseRelations}');
        // Traverse reverse relations (e.g., an Author's Books)
        // This requires SupabaseTableInfo to be augmented with reverse relation details.
        // Assuming `tableInfo.reverseRelations` exists and provides necessary info.
        // `ModelReverseRelationInfo` would be a class holding `fieldNameInThisModel` and `referencingTableOriginalName`.
        if (tableInfo.reverseRelations.isNotEmpty) {
          for (final revRelInfo in tableInfo.reverseRelations) {
            final fieldName = revRelInfo.fieldNameInThisModel;
            log(
              "Looking for reverse relation field: '$fieldName' for table ${revRelInfo.referencingTableOriginalName}",
            );
            final dynamic relatedDataList = currentModel.data[fieldName];

            if (relatedDataList == null) {
              log(
                "Reverse relation field '$fieldName' is NULL in currentModel.data for ${currentModelOriginalTableName}",
              );
            } else if (relatedDataList is List) {
              log(
                "Found reverse relation list for '$fieldName'. Count: ${relatedDataList.length}",
              );
              for (final item in relatedDataList) {
                if (item is TetherModel) {
                  // The table name for items in this list is the table that *has* the FK
                  // pointing to the current model's table.
                  _collectModelsRecursively(
                    item,
                    revRelInfo.referencingTableOriginalName,
                  );
                }
              }
            } else {
              log(
                "Reverse relation field '$fieldName' is NOT A LIST. Type: ${relatedDataList.runtimeType}",
              );
            }
          }
        }
      }

      // 3. Start the recursive collection process for each root model.
      for (final model in rootModels) {
        // `this.tableName` is the simple name of the root table (e.g., "books")
        _collectModelsRecursively(model, this.tableName);
      }

      log('Models to Upsert: $modelsByTable');

      // 4. Build UPSERT SQL statements for each table that has collected models.
      final List<SqlStatement> upsertStatements = [];
      modelsByTable.forEach((originalTableName, modelsList) {
        if (modelsList.isNotEmpty) {
          // ClientManagerSqlUtils.buildUpsertSql expects the simple original table name.
          upsertStatements.add(
            ClientManagerSqlUtils.buildUpsertSql(modelsList, originalTableName),
          );
        }
      });

      // 5. Execute all UPSERT statements in a single transaction.
      if (upsertStatements.isNotEmpty) {
        await localDb.writeTransaction((tx) async {
          for (final statement in upsertStatements) {
            final finalSql =
                statement.build(); // Get the FinalSqlStatement object
            // Pass both the SQL string and the arguments to tx.execute()
            await tx.execute(finalSql.sql, finalSql.arguments);
          }
        });
      }
    } catch (e, s) {
      log('Error in upsertSupabaseData: $e $s');
      // Depending on desired behavior, you might rethrow or handle specific exceptions.
    }
  }

  /// Stream implementation
  @override
  Stream<TetherClientReturn<TModel>> asStream() {
    try {
      if (type != SqlOperationType.select) {
        throw UnsupportedError(
          'Streaming is only supported for SELECT operations.',
        );
      }

      if (localQuery == null) {
        throw ArgumentError('localQuery must be provided for streaming.');
      }

      // Stream data from the local database
      final localStream = localDb.watch(localQuery!.build().sql).map((rows) {
        return rows.map((row) => fromSqliteFactory(row)).toList();
      });

      final controller = StreamController<TetherClientReturn<TModel>>();
      int? currentRemoteCount;

      // Fetch remote data in the background and update the local database
      (supabase as PostgrestTransformBuilder)
          .count(CountOption.exact)
          .then((remoteData) async {
            currentRemoteCount = remoteData.count;
            await upsertSupabaseData(remoteData.data);
          })
          .catchError((error) {
            // Log the error but do not interrupt the local stream
            throw Exception('Error fetching remote data: $error');
          });

      final localSubscription = localStream.listen(
        (listData) {
          // When localDataStream emits, package it with the currentRemoteCount
          // If supabase fetch hasn't completed, currentRemoteCount will be null
          if (!controller.isClosed) {
            controller.add(
              TetherClientReturn<TModel>(
                data: listData,
                count: currentRemoteCount,
              ),
            );
          }
        },
        onError: (error, stackTrace) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
        },
        onDone: () {
          if (!controller.isClosed) {
            controller.close();
          }
        },
      );
      controller.onCancel = () {
        localSubscription.cancel();
      };

      return controller.stream;
    } catch (e) {
      return Stream.value(
        TetherClientReturn<TModel>(data: [], error: 'Error in asStream: $e'),
      );
    }
  }

  /// Handle errors
  @override
  Future<TetherClientReturn<TModel>> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) {
    return this.then(
      (value) => TetherClientReturn<TModel>(data: [], error: null),
      onError: (error) {
        if (test == null || test(error)) {
          return TetherClientReturn<TModel>(data: [], error: error.toString());
        }
      },
    );
  }

  /// Main execution point - when the future is awaited
  @override
  Future<R> then<R>(
    FutureOr<R> Function(TetherClientReturn<TModel> value) onValue, {
    Function? onError,
  }) {
    Future<TetherClientReturn<TModel>> operation;

    switch (type) {
      case SqlOperationType.select:
        operation = _executeSelect();
        break;
      case SqlOperationType.insert:
        operation = _executeInsert().then((model) => model);
        break;
      case SqlOperationType.update:
        operation = _executeUpdate().then((model) => model);
        break;
      case SqlOperationType.delete:
        operation = _executeDelete().then(
          (_) => TetherClientReturn<TModel>(data: [], count: 0, error: null),
        );
        break;
      case SqlOperationType.upsert:
        operation = _executeUpsert().then((model) => model);
        break;
      default:
        throw UnsupportedError('Unsupported operation type: $type');
    }

    return operation.then(onValue, onError: onError);
  }

  /// Timeout implementation
  @override
  Future<TetherClientReturn<TModel>> timeout(
    Duration timeLimit, {
    FutureOr<TetherClientReturn<TModel>> Function()? onTimeout,
  }) {
    return this
        .then((value) {
          return value;
        })
        .timeout(timeLimit, onTimeout: onTimeout);
  }

  /// Completion callback
  @override
  Future<TetherClientReturn<TModel>> whenComplete(
    FutureOr<void> Function() action,
  ) {
    return this.then((value) => value).whenComplete(action);
  }

  Future<TetherClientReturn<TModel>> _executeSelect() async {
    List<TModel> tetherModels = [];
    try {
      if (isLocalOnly) {
        // Fetch data from the local SQLite database
        final localData = await localDb.getAll(localQuery!.build().sql);

        // Convert local data to TetherModel instances
        tetherModels = localData.map((row) => fromSqliteFactory(row)).toList();

        return TetherClientReturn<TModel>(
          data: tetherModels,
          count: tetherModels.length,
          error: null,
        );
      }

      final PostgrestResponse<dynamic> remoteData = await (supabase
              as PostgrestTransformBuilder)
          .count(CountOption.exact);

      tetherModels =
          remoteData.data.map((row) => fromJsonFactory(row)).toList();
      await upsertSupabaseData(remoteData.data);

      return TetherClientReturn<TModel>(
        data: tetherModels,
        count: remoteData.count,
        error: null,
      );
    } catch (e) {
      return TetherClientReturn<TModel>(data: [], error: e.toString());
    }
  }

  Future<TetherClientReturn<TModel>> _executeInsert() async {
    if (localQuery == null) {
      throw ArgumentError('localQuery must be provided for INSERT operations.');
    }

    List<TModel> remoteModels = [];

    try {
      // Start a transaction with a savepoint
      await localDb.writeTransaction((tx) async {
        await tx.execute('SAVEPOINT optimistic_insert;');

        final FinalSqlStatement finalSql = localQuery!.build();

        // Optimistically insert into the local database
        await tx.execute(finalSql.sql, finalSql.arguments);

        try {
          // Execute the Supabase query
          final remoteData =
              await (supabase as PostgrestTransformBuilder).select();
          remoteModels = remoteData.map((row) => fromJsonFactory(row)).toList();

          // Update the local database with the remote data
          await upsertSupabaseData(remoteData);
        } catch (error) {
          // Roll back to the savepoint if the remote action fails
          await tx.execute('ROLLBACK TO optimistic_insert;');
          rethrow;
        }

        // Release the savepoint if everything succeeds
        await tx.execute('RELEASE SAVEPOINT optimistic_insert;');
      });

      return TetherClientReturn<TModel>(
        data: remoteModels,
        count: remoteModels.length,
        error: null,
      );
    } catch (error) {
      rethrow;
    }
  }

  Future<TetherClientReturn<TModel>> _executeUpdate() async {
    if (localQuery == null) {
      throw ArgumentError('localQuery must be provided for INSERT operations.');
    }

    TModel? remoteModel;

    try {
      // Start a transaction with a savepoint
      await localDb.writeTransaction((tx) async {
        await tx.execute('SAVEPOINT optimistic_insert;');

        final FinalSqlStatement finalSql = localQuery!.build();

        // Optimistically insert into the local database
        await tx.execute(finalSql.sql, finalSql.arguments);

        try {
          // Execute the Supabase query
          final remoteData =
              await (supabase as PostgrestTransformBuilder).select();
          remoteModel = fromJsonFactory(remoteData.first);

          // Update the local database with the remote data
          await upsertSupabaseData(remoteData);
        } catch (error) {
          // Roll back to the savepoint if the remote action fails
          await tx.execute('ROLLBACK TO optimistic_insert;');
          rethrow;
        }

        // Release the savepoint if everything succeeds
        await tx.execute('RELEASE SAVEPOINT optimistic_insert;');
      });

      return TetherClientReturn<TModel>(
        data: [remoteModel!],
        count: 1,
        error: null,
      );
    } catch (error) {
      rethrow;
    }
  }

  Future<void> _executeDelete() async {
    if (localQuery == null) {
      throw ArgumentError('localQuery must be provided for DELETE operations.');
    }

    try {
      // Start a transaction with a savepoint
      await localDb.writeTransaction((tx) async {
        await tx.execute('SAVEPOINT optimistic_delete;');

        final FinalSqlStatement finalSql = localQuery!.build();

        // Optimistically delete from the local database
        await tx.execute(finalSql.sql, finalSql.arguments);

        try {
          // Execute the Supabase query
          await supabase;
        } catch (error) {
          // Roll back to the savepoint if the remote action fails
          await tx.execute('ROLLBACK TO optimistic_delete;');
          rethrow;
        }

        // Release the savepoint if everything succeeds
        await tx.execute('RELEASE SAVEPOINT optimistic_delete;');
      });
    } catch (error) {
      rethrow;
    }
  }

  Future<TetherClientReturn<TModel>> _executeUpsert() async {
    if (localQuery == null) {
      throw ArgumentError('localQuery must be provided for UPSERT operations.');
    }

    TModel? remoteModel;

    try {
      // Start a transaction with a savepoint
      await localDb.writeTransaction((tx) async {
        await tx.execute('SAVEPOINT optimistic_upsert;');

        final FinalSqlStatement finalSql = localQuery!.build();

        // Optimistically upsert into the local database
        await tx.execute(finalSql.sql, finalSql.arguments);

        try {
          // Execute the Supabase query
          final remoteData =
              await (supabase as PostgrestTransformBuilder).select();
          remoteModel = fromJsonFactory(remoteData.first);

          // Update the local database with the remote data
          await upsertSupabaseData(remoteData);
        } catch (error) {
          // Roll back to the savepoint if the remote action fails
          await tx.execute('ROLLBACK TO optimistic_upsert;');
          rethrow;
        }

        // Release the savepoint if everything succeeds
        await tx.execute('RELEASE SAVEPOINT optimistic_upsert;');
      });

      return TetherClientReturn<TModel>(
        data: [remoteModel!],
        count: 1,
        error: null,
      );
    } catch (error) {
      rethrow;
    }
  }

  String _getFieldNameFromFkColumn(
    String originalFkColumnName,
    String originalForeignTableName,
  ) {
    String baseName = originalFkColumnName.toLowerCase();
    if (baseName.endsWith('_id')) {
      baseName = baseName.substring(0, baseName.length - '_id'.length);
    } else if (baseName.endsWith('_uuid')) {
      baseName = baseName.substring(0, baseName.length - '_uuid'.length);
    }

    if (baseName.isEmpty || baseName == 'id') {
      // if FK column was just 'id' or became empty
      String singularForeignTable = originalForeignTableName.toLowerCase();
      if (singularForeignTable.endsWith('s') &&
          singularForeignTable.length > 1 &&
          !singularForeignTable.endsWith(
            'ss',
          ) /* avoid 'address' -> 'addres' */ ) {
        // Basic pluralization, might need improvement for irregular plurals
        if (singularForeignTable.endsWith('ies') &&
            singularForeignTable.length > 3) {
          singularForeignTable =
              singularForeignTable.substring(
                0,
                singularForeignTable.length - 3,
              ) +
              'y';
        } else {
          singularForeignTable = singularForeignTable.substring(
            0,
            singularForeignTable.length - 1,
          );
        }
      }
      return _snakeToCamelCase(singularForeignTable);
    }
    return _snakeToCamelCase(baseName);
  }

  String _snakeToCamelCase(String snakeCase) {
    if (snakeCase.isEmpty) return '';
    List<String> parts = snakeCase.split('_');
    if (parts.isEmpty) return '';

    // Handle single-word already camelCased or all lowercase (e.g. "id", "authorId")
    if (parts.length == 1) {
      if (parts.first.contains(RegExp(r'[A-Z]'))) {
        // Already camelCased
        return parts.first[0].toLowerCase() + parts.first.substring(1);
      }
      return parts.first.toLowerCase();
    }

    String camelCase = parts.first.toLowerCase();
    for (int i = 1; i < parts.length; i++) {
      if (parts[i].isNotEmpty) {
        camelCase +=
            parts[i][0].toUpperCase() + parts[i].substring(1).toLowerCase();
      }
    }
    return camelCase;
  }

  // ... other methods like _executeSelect, _executeInsert, etc.
}
