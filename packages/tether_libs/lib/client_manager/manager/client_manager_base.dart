import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sqlite_async/sqlite3_common.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tether_libs/models/row_utils.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/models/tether_model_input.dart';
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
  final SupabaseQueryBuilder baseSupabase;
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
  final TetherModelInputBase? updatePayload;

  ClientManagerBase({
    required this.tableName,
    required this.localTableName,
    required this.localDb,
    required this.supabase,
    required this.baseSupabase,
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
    this.updatePayload,
  });

  /// Generates a list of UPSERT SQL statements for nested data from a Supabase response.
  /// Each type of nested data will have its own UPSERT statement.
  Future<void> upsertSupabaseData(
    List<Map<String, dynamic>> supabaseResponse,
  ) async {
    if (supabaseResponse.isEmpty) {
      debugPrint('Supabase response is empty, skipping upsert.');
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
      void collectModelsRecursively(
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
          debugPrint(
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
            collectModelsRecursively(relatedData, fk.originalForeignTableName);
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
          for (final reverseRel in tableInfo.reverseRelations) {
            // The field in the current model that holds the list of related models (e.g., 'books' in AuthorModel)
            //
            // CORRECTED: Access the nested data directly from the model's `data` map,
            // which was populated by the fromJsonFactory. Do not re-serialize to JSON.
            final dynamic relatedData =
                currentModel.data[reverseRel.fieldNameInThisModel];

            if (relatedData is List) {
              // The list items are already deserialized into TetherModel instances
              // by the fromJsonFactory.
              for (final relatedItem in relatedData) {
                if (relatedItem is TetherModel) {
                  // Recursively collect models from the list
                  collectModelsRecursively(
                    relatedItem,
                    reverseRel.referencingTableOriginalName,
                  );
                }
              }
            } else if (relatedData is TetherModel) {
              // Handle one-to-one reverse relations if they exist
              collectModelsRecursively(
                relatedData,
                reverseRel.referencingTableOriginalName,
              );
            }
          }
        }
      }

      // 3. Start the recursive collection process for each root model.
      for (final model in rootModels) {
        // `this.tableName` is the simple name of the root table (e.g., "books")
        collectModelsRecursively(model, tableName);
      }

      log('Models to Upsert: $modelsByTable');

      // 4. Build and execute UPSERT statements in batches for each table.
      if (modelsByTable.isNotEmpty) {
        await localDb.writeTransaction((tx) async {
          for (final entry in modelsByTable.entries) {
            final originalTableName = entry.key;
            final modelsList = entry.value;
            if (modelsList.isEmpty) continue;

            // Determine a safe batch size. The max variables in SQLite is 999 by default.
            // Batch size = 999 / number of columns. Let's be conservative.
            final firstModel = modelsList.first;
            final columnCount = firstModel.toSqlite().keys.length;
            if (columnCount == 0) continue;

            final batchSize = (900 / columnCount).floor().clamp(1, 500);

            for (var i = 0; i < modelsList.length; i += batchSize) {
              final end = (i + batchSize < modelsList.length)
                  ? i + batchSize
                  : modelsList.length;
              final batch = modelsList.sublist(i, end);

              if (batch.isNotEmpty) {
                final statement = ClientManagerSqlUtils.buildUpsertSqlForModels(
                  batch,
                  originalTableName,
                  tableSchemas: tableSchemas,
                );
                final finalSql = statement.build();
                await tx.execute(finalSql.sql, finalSql.arguments);
              }
            }
          }
        });
      }

      // FIX: Await a trivial command to ensure the write transaction is fully committed.
      // This forces the database isolate to process pending writes before this method returns.
      await localDb.get('SELECT 1');
    } catch (e, s) {
      debugPrint('Error in upsertSupabaseData: $e $s');
      // Depending on desired behavior, you might rethrow or handle specific exceptions.
    }
  }

  /// Stream implementation
  @override
  Stream<TetherClientReturn<TModel>> asStream() {
    if (type != SqlOperationType.select) {
      return Stream.error(
        UnsupportedError('Streaming is only supported for SELECT operations.'),
      );
    }
    if (localQuery == null) {
      return Stream.error(
        ArgumentError('localQuery must be provided for streaming.'),
      );
    }

    // 1. Build the local query.
    final aliasedQuery = localQuery!.copyWith(
      selectColumns: '${localQuery!.selectColumns} AS jsobjects',
    );
    final FinalSqlStatement builtQuery = aliasedQuery.build();

    // 2. Create a stream that watches the local database.
    // This stream will emit whenever the underlying data changes.
    final localDataStream = localDb
        .watch(builtQuery.sql, parameters: builtQuery.arguments)
        .map((rows) {
      final models = rows
          .where((row) => row['jsobjects'] != null)
          .map((row) => fromSqliteFactory(
              createRowFromMap(jsonDecode(row['jsobjects'] as String))))
          .toList();
      return TetherClientReturn<TModel>(data: models);
    });

    // 3. Define the remote sync operation as a Future.
    // This will fetch the remote count and upsert the data.
    Future<int?> syncRemoteData() async {
      if (isLocalOnly || !syncWithSupabase) return null;
      try {
        final remoteDataResponse =
            await _resetPreferForCount().count(CountOption.exact);
        await upsertSupabaseData(remoteDataResponse.data);
        return remoteDataResponse.count;
      } catch (e, s) {
        // Propagate the error through the stream.
        debugPrint('Error fetching remote data for stream: $e $s');
        rethrow;
      }
    }

    // 4. Use RxDart's `CombineLatestStream` to merge the local data stream
    //    with the result of the remote sync operation.
    return CombineLatestStream.combine2(
      localDataStream,
      // Convert the Future into a stream that emits once.
      // `startWith(null)` ensures the stream emits immediately with no count,
      // allowing the local data to be shown first.
      Stream.fromFuture(syncRemoteData()).startWith(null),
      (localData, remoteCount) {
        // The first emission will have remoteCount = null.
        // Subsequent emissions from localDataStream will be combined with the
        // now-completed remoteCount.
        // If the remote sync completes, it will trigger a new emission here.
        return TetherClientReturn(
          data: localData.data,
          count: remoteCount ?? localData.count, // Use remote count when available
          error: localData.error,
        );
      },
    ).handleError((error, stackTrace) {
      // Catch errors from either the local stream or the remote fetch.
      debugPrint('Error in asStream pipeline: $error');
      // It's better to let the UI layer handle the error state.
      // We rethrow it so providers like StreamProvider can catch it.
      throw error;
    });
  }

  /// Handle errors
  @override
  Future<TetherClientReturn<TModel>> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) {
    return then(
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
    return then((value) {
          return value;
        })
        .timeout(timeLimit, onTimeout: onTimeout);
  }

  /// Completion callback
  @override
  Future<TetherClientReturn<TModel>> whenComplete(
    FutureOr<void> Function() action,
  ) {
    return then((value) => value).whenComplete(action);
  }

  // Ensures we don’t accumulate duplicate "count=..." in Prefer.
  PostgrestTransformBuilder<dynamic> _resetPreferForCount() {
    // setHeader returns a new builder copy with the header overwritten
    return (supabase as PostgrestTransformBuilder).setHeader('Prefer', '');
  }

  Future<TetherClientReturn<TModel>> _executeSelect() async {
    List<TModel> tetherModels = [];
    try {
      if (isLocalOnly) {
        // Fetch data from the local SQLite database
        final aliasedQuery = localQuery!.copyWith(
          selectColumns: '${localQuery!.selectColumns} AS jsobjects',
        );
        final finalSql = aliasedQuery.build();
        final localRows = await localDb.getAll(finalSql.sql, finalSql.arguments);

        // Filter out rows where 'jsobjects' is null before mapping.
        tetherModels = localRows
            .where((row) => row['jsobjects'] != null)
            .map((row) => fromSqliteFactory(createRowFromMap(jsonDecode(row['jsobjects'] as String))))
            .toList();

        return TetherClientReturn<TModel>(
          data: tetherModels,
          count: tetherModels.length,
          error: null,
        );
      }

      // The PostgrestTransformBuilder is cast from the base PostgrestBuilder
      final transformBuilder = supabase as PostgrestTransformBuilder;

      // Make a CLEAN builder for this call to avoid duplicated Prefer
      final executionBuilder = transformBuilder.setHeader('Prefer', '');

      // Use count on the clean builder (returns data + count)
      final PostgrestResponse<dynamic> remoteDataResponse =
          await executionBuilder.count(CountOption.exact);

      final List<dynamic> remoteData = remoteDataResponse.data as List<dynamic>;
      tetherModels = remoteData
          .map((row) => fromJsonFactory(row as Map<String, dynamic>))
          .toList();

      if (syncWithSupabase) {
        await upsertSupabaseData(remoteData.cast<Map<String, dynamic>>());
      }

      return TetherClientReturn<TModel>(
        data: tetherModels,
        count: remoteDataResponse.count,
        error: null,
      );
    } catch (e, s) {
      return TetherClientReturn<TModel>(data: [], error: '$e $s');
    }
  }

  Future<TetherClientReturn<TModel>> _executeInsert() async {
    if (localQuery == null) {
      throw ArgumentError('localQuery must be provided for INSERT operations.');
    }

    // 1. Perform the optimistic INSERT and get the new row's ID.
    // This is NOT in a transaction, so it commits immediately and notifies the UI.
    final FinalSqlStatement optimisticSql = localQuery!.build();
    final optimisticResult =
        await localDb.execute(optimisticSql.sql, optimisticSql.arguments);
    final dynamic lastInsertedId = optimisticResult.first['id'];

    List<TModel> remoteModels = [];
    try {
      // 2. Attempt the remote operation.
      final remoteData = await (supabase
              as PostgrestTransformBuilder).select();
      remoteModels = remoteData.map((row) => fromJsonFactory(row)).toList();

      // 3. Reconcile local data with the server's response. This will update
      //    the optimistic record with the real data and notify the UI again.
      await upsertSupabaseData(remoteData.cast<Map<String, dynamic>>());

      return TetherClientReturn<TModel>(
        data: remoteModels,
        count: remoteModels.length,
        error: null,
      );
    } catch (error) {
      // 4. If remote fails, manually roll back the optimistic insert.
      debugPrint('Rolling back optimistic insert (local id: $lastInsertedId) due to error: $error.');
      final rollbackSql = ClientManagerSqlUtils.buildDeleteSql(
        localTableName,
        lastInsertedId,
        idColumnName: 'id', // Assuming the local PK column is 'id'
      );
      await localDb.execute(rollbackSql.build().sql, rollbackSql.build().arguments);
      rethrow; // Rethrow the original error.
    }
  }

  Future<TetherClientReturn<TModel>> _executeUpdate() async {
    if (localQuery == null || localQuery!.whereArguments.isEmpty) {
      throw ArgumentError(
          'localQuery with whereArguments must be provided for UPDATE.');
    }

    // 1. Identify the record and fetch its current state for rollback.
    // We assume the ID is the first argument in the WHERE clause.
    final id = localQuery!.whereArguments.first;
    final originalRows = await localDb
        .getAll('SELECT * FROM $localTableName WHERE id = ?', [id]);
    if (originalRows.isEmpty) {
      throw Exception('Item with id $id not found for optimistic update.');
    }
    final originalRow = originalRows.first;

    // 2. Perform the optimistic UPDATE. This commits immediately and notifies the UI.
    final FinalSqlStatement optimisticSql = localQuery!.build();
    await localDb.execute(optimisticSql.sql, optimisticSql.arguments);

    TModel? remoteModel;
    try {
      // 3. Attempt the remote operation.
      final remoteData = await (supabase
              as PostgrestTransformBuilder).select();
      if (remoteData.isNotEmpty) {
        remoteModel = fromJsonFactory(remoteData.first);
        await upsertSupabaseData(remoteData.cast<Map<String, dynamic>>());
      }
      return TetherClientReturn<TModel>(
        data: remoteModel != null ? [remoteModel] : [],
        count: remoteModel != null ? 1 : 0,
      );
    } catch (error) {
      // 4. If remote fails, roll back by deleting the modified row and re-inserting the original.
      debugPrint('Rolling back optimistic update for id $id due to error: $error.');
      await localDb.writeTransaction((tx) async {
        await tx.execute('DELETE FROM $localTableName WHERE id = ?', [id]);
        final columns = originalRow.keys.join(', ');
        final placeholders = List.filled(originalRow.keys.length, '?').join(', ');
        await tx.execute(
          'INSERT INTO $localTableName ($columns) VALUES ($placeholders)',
          originalRow.values.toList(),
        );
      });
      rethrow;
    }
  }

  Future<void> _executeDelete() async {

    late Row originalRow;
    try {
    if (localQuery == null || localQuery!.whereArguments.isEmpty) {
      throw ArgumentError(
          'localQuery with whereArguments must be provided for DELETE.');
    }

    // 1. Identify the record and fetch its current state for rollback.
    final id = localQuery!.whereArguments.first;
    final originalRows = await localDb
        .getAll('SELECT * FROM $localTableName WHERE id = ?', [id]);
     if (originalRows.isEmpty) {
      // The item is already gone, so we can consider the operation a success.
      return;
    }
    originalRow = originalRows.first;

    // 2. Perform the optimistic DELETE. This commits immediately and notifies the UI.
    final FinalSqlStatement optimisticSql = localQuery!.build();
    await localDb.execute(optimisticSql.sql, optimisticSql.arguments);

    
      // 3. Attempt the remote operation.
      await supabase;
    } catch (error) {
      // 4. If remote fails, roll back by re-inserting the original row.
      log('Rolling back optimistic delete due to error: $error.');
      final columns = originalRow.keys.join(', ');
      final placeholders = List.filled(originalRow.keys.length, '?').join(', ');
      await localDb.execute(
        'INSERT INTO $localTableName ($columns) VALUES ($placeholders)',
        originalRow.values.toList(),
      );
      rethrow;
    }
  }

  Future<TetherClientReturn<TModel>> _executeUpsert() async {
    if (localQuery == null) {
      throw ArgumentError('localQuery must be provided for UPSERT operations.');
    }

    // For upsert, optimistic UI is handled by simply running the command.
    // If it fails remotely, we assume the local state is still valid until the next sync.
    // A more robust rollback would be complex, involving checking if the row existed before.
    final FinalSqlStatement optimisticSql = localQuery!.build();
    await localDb.execute(optimisticSql.sql, optimisticSql.arguments);

    try {
      final remoteData = await (supabase as PostgrestTransformBuilder).select();
      final remoteModels = remoteData.map((row) => fromJsonFactory(row)).toList();

      // Re-sync with the server's response to get any server-generated values (e.g., updated_at).
      await upsertSupabaseData(remoteData.cast<Map<String, dynamic>>());

      return TetherClientReturn<TModel>(
        data: remoteModels,
        count: remoteModels.length,
      );
    } catch (e) {
      // For upsert, we generally don't roll back the optimistic write,
      // as the state might still be more correct than what was there before.
      // The next successful sync will resolve any inconsistencies.
      debugPrint('Remote upsert failed, but optimistic local upsert was kept. Error: $e');
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
              '${singularForeignTable.substring(
                0,
                singularForeignTable.length - 3,
              )}y';
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

}
