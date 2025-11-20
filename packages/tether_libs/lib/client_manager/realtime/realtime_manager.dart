import 'dart:async';
import 'package:rxdart/rxdart.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:tether_libs/client_manager/manager/client_manager_models.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/utils/logger.dart' as tether_logger; // aliased
import 'realtime_manager_types.dart';

class RealtimeManager<TModel extends TetherModel<TModel>> {
  final SupabaseClient _supabaseClient;
  final SqliteDatabase _localDb;
  final String _supabaseSchema;
  final String _supabaseTableName;
  final FromJsonFactory<TModel> _fromJsonFactory;
  // Global schema map

  final List<String> _primaryKeyColumns;
  final String _localTableName;

  final List<RealtimeManagerFilterConfig> _filterConfigs = [];
  RealtimeManagerOrderConfig? _orderConfig;
  int? _limitConfig;

  RealtimeChannel? _channel;
  BehaviorSubject<List<TModel>>? _dataStreamController;
  List<TModel> _currentData = [];
  bool _wasSubscribed = false;

  final tether_logger.Logger _log;
  final Map<String, SupabaseTableInfo> _tableSchemas;

  RealtimeManager({
    required SupabaseClient supabaseClient,
    required SqliteDatabase localDb,
    required String supabaseTableName,
    required FromJsonFactory<TModel> fromJsonFactory,
    required Map<String, SupabaseTableInfo> tableSchemas,
    String supabaseSchema = 'public',
  }) : _supabaseClient = supabaseClient,
        _tableSchemas = tableSchemas,
       _localDb = localDb,
       _supabaseSchema = supabaseSchema,
       _supabaseTableName = supabaseTableName,
       _fromJsonFactory = fromJsonFactory,
       _primaryKeyColumns =
           (tableSchemas['$supabaseSchema.$supabaseTableName']?.primaryKeys
                           .map((e) => e.originalName)
                           .toList() ??
                       [])
                   .isNotEmpty
               ? tableSchemas['$supabaseSchema.$supabaseTableName']!.primaryKeys
                   .map((e) => e.originalName)
                   .toList()
               : throw ArgumentError(
                 "Primary keys for table '$supabaseSchema.$supabaseTableName' not found or empty.",
               ),
       _localTableName =
           (tableSchemas['$supabaseSchema.$supabaseTableName']?.localName ??
               (throw ArgumentError(
                 "Local table name for '$supabaseSchema.$supabaseTableName' not found.",
               ))),
       _log = tether_logger.Logger('RealtimeManager<$supabaseTableName>');

  // --- Configuration Methods ---
  RealtimeManager<TModel> eq(TetherColumn column, Object value) {
    _filterConfigs.add(RealtimeManagerFilterConfig(
      column: column.originalName,
      value: value,
      type: RealtimeManagerFilterType.eq,
    ));
    return this;
  }

  RealtimeManager<TModel> neq(TetherColumn column, Object value) {
    _filterConfigs.add(RealtimeManagerFilterConfig(
      column: column.originalName,
      value: value,
      type: RealtimeManagerFilterType.neq,
    ));
    return this;
  }

  RealtimeManager<TModel> lt(TetherColumn column, Object value) {
    _filterConfigs.add(RealtimeManagerFilterConfig(
      column: column.originalName,
      value: value,
      type: RealtimeManagerFilterType.lt,
    ));
    return this;
  }

  RealtimeManager<TModel> lte(TetherColumn column, Object value) {
    _filterConfigs.add(RealtimeManagerFilterConfig(
      column: column.originalName,
      value: value,
      type: RealtimeManagerFilterType.lte,
    ));
    return this;
  }

  RealtimeManager<TModel> gt(TetherColumn column, Object value) {
    _filterConfigs.add(RealtimeManagerFilterConfig(
      column: column.originalName,
      value: value,
      type: RealtimeManagerFilterType.gt,
    ));
    return this;
  }

  RealtimeManager<TModel> gte(TetherColumn column, Object value) {
    _filterConfigs.add(RealtimeManagerFilterConfig(
      column: column.originalName,
      value: value,
      type: RealtimeManagerFilterType.gte,
    ));
    return this;
  }

  RealtimeManager<TModel> inFilter(TetherColumn column, List<Object> values) {
    _filterConfigs.add(RealtimeManagerFilterConfig(
      column: column.originalName,
      value: values,
      type: RealtimeManagerFilterType.inFilter,
    ));
    return this;
  }

  RealtimeManager<TModel> order(TetherColumn column, {bool ascending = true}) {
    _orderConfig = RealtimeManagerOrderConfig(
      column: column.originalName,
      ascending: ascending,
    );
    return this;
  }

  RealtimeManager<TModel> limit(int count) {
    _limitConfig = count;
    return this;
  }

  // --- Stream Management ---

  Stream<List<TModel>> listen() {
    if (_dataStreamController == null || _dataStreamController!.isClosed) {
      _currentData = [];
      _dataStreamController = BehaviorSubject<List<TModel>>(
        onListen: _setupSubscription,
        onCancel: _cancelSubscription,
      );
      _log.fine('Created new BehaviorSubject for $_supabaseTableName.');
    } else {
      _log.fine('Re-using existing BehaviorSubject for $_supabaseTableName.');
      // If already listening, ensure the current data is emitted to new subscribers.
      // The BehaviorSubject handles this by design.
    }
    return _dataStreamController!.stream;
  }

  Future<void> _setupSubscription() async {
    _log.info('Setting up subscription for $_supabaseTableName...');
    await _fetchInitialData();

    PostgresChangeFilter? realtimeDbFilter;
    if (_filterConfigs.isNotEmpty) {
      if (_filterConfigs.length > 1) {
        _log.warning(
          'More than one filter is configured. Supabase Realtime only supports a single filter on the subscription. Only the first filter will be applied for live events. The initial data fetch correctly uses all filters.',
        );
      }
      final firstFilter = _filterConfigs.first;
      realtimeDbFilter = PostgresChangeFilter(
        type: firstFilter.type.toSupabaseFilterType(),
        column: firstFilter.column,
        value: firstFilter.value,
      );
    }

    final topic = 'channel_${_supabaseSchema}_$_supabaseTableName';
    _channel = _supabaseClient.channel(topic);

    _channel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: _supabaseSchema,
          table: _supabaseTableName,
          filter: realtimeDbFilter,
          callback: _handleRealtimePayload,
        )
        .subscribe((status, [error]) {
          _log.info(
            'Realtime channel status for $_supabaseTableName: $status, Error: $error',
          );
          switch (status) {
            case RealtimeSubscribeStatus.subscribed:
              if (_wasSubscribed) {
                _log.info(
                  'Re-subscribed to $_supabaseTableName. Re-fetching initial data.',
                );
                _fetchInitialData(); // Re-fetch on re-subscribe
              }
              _wasSubscribed = true;
              break;
            case RealtimeSubscribeStatus.closed:
              _log.warning('Realtime channel for $_supabaseTableName closed.');
              _dataStreamController?.close(); // This will trigger onCancel
              break;
            case RealtimeSubscribeStatus.channelError:
            case RealtimeSubscribeStatus.timedOut:
              _log.severe(
                'Realtime channel error for $_supabaseTableName: $status, Error: $error',
              );
              _dataStreamController?.addError(
                RealtimeSubscribeException(status, error),
                StackTrace.current,
              );
              break;
          }
        });
  }

  Future<void> _fetchInitialData() async {
    _log.fine('Fetching initial data for $_supabaseTableName...');
    try {
      PostgrestFilterBuilder query =
          _supabaseClient.from(_supabaseTableName).select();

      // Apply all configured filters for the initial fetch
      for (final fc in _filterConfigs) {
        switch (fc.type) {
          case RealtimeManagerFilterType.eq:
            query = query.eq(fc.column, fc.value);
            break;
          case RealtimeManagerFilterType.neq:
            query = query.neq(fc.column, fc.value);
            break;
          case RealtimeManagerFilterType.lt:
            query = query.lt(fc.column, fc.value);
            break;
          case RealtimeManagerFilterType.lte:
            query = query.lte(fc.column, fc.value);
            break;
          case RealtimeManagerFilterType.gt:
            query = query.gt(fc.column, fc.value);
            break;
          case RealtimeManagerFilterType.gte:
            query = query.gte(fc.column, fc.value);
            break;
          case RealtimeManagerFilterType.inFilter:
            query = query.inFilter(fc.column, fc.value as List<Object>);
            break;
        }
      }

      PostgrestTransformBuilder? transformQuery;
      if (_orderConfig != null) {
        transformQuery = query.order(
          _orderConfig!.column,
          ascending: _orderConfig!.ascending,
        );
      }
      if (_limitConfig != null) {
        // Apply limit to the transformed query or the base query
        transformQuery = (transformQuery ?? query).limit(_limitConfig!);
      }

      final response = await (transformQuery ?? query);

      final List<Map<String, dynamic>> responseData =
          List<Map<String, dynamic>>.from(response as List);
      final models =
          responseData.map((data) => _fromJsonFactory(data)).toList();

      await _upsertModelsToLocalDb(models);
      _currentData = models; // Replace current data with fetched data
      _sortAndEmitData();
      _log.fine(
        'Fetched and processed ${models.length} initial records for $_supabaseTableName.',
      );
    } catch (e, s) {
      _log.severe('Error fetching initial data for $_supabaseTableName: $e $s');
      _dataStreamController?.addError(e, s);
      // Optionally, close the stream or attempt retry logic here
    }
  }

  void _handleRealtimePayload(PostgresChangePayload payload) {
    _log.fine(
      'Received realtime payload for $_supabaseTableName: ${payload.eventType}',
    );
    switch (payload.eventType) {
      case PostgresChangeEvent.insert:
        final newRecord = payload.newRecord;
        final newModel = _fromJsonFactory(newRecord);
        _upsertModelsToLocalDb([newModel]);
        _currentData.add(newModel);
        break;
      case PostgresChangeEvent.update:
        final updatedRecord = payload.newRecord;
        final updatedModel = _fromJsonFactory(updatedRecord);
        _upsertModelsToLocalDb([updatedModel]);
        final index = _currentData.indexWhere(
          (m) => _modelsMatchByPk(m, updatedModel),
        );
        if (index != -1) {
          _currentData[index] = updatedModel;
        } else {
          _currentData.add(updatedModel); // Should ideally be an update
          _log.warning(
            'Update event for $_supabaseTableName, but no matching model found in cache. Added as new.',
          );
        }
        break;
      case PostgresChangeEvent.delete:
        final oldRecord = payload.oldRecord;
        // We need a way to construct a "shell" model or just use PKs for deletion
        // For simplicity, let's assume oldRecord contains enough PK info
        final pks = <String, dynamic>{};
        bool allPksPresent = true;
        for (var pkCol in _primaryKeyColumns) {
          if (oldRecord.containsKey(pkCol)) {
            pks[pkCol] = oldRecord[pkCol];
          } else {
            allPksPresent = false;
            _log.warning(
              "Delete event for $_supabaseTableName, oldRecord missing PK '$pkCol'. Cannot delete from local DB precisely via this event.",
            );
            break;
          }
        }
        if (allPksPresent && pks.isNotEmpty) {
          _deleteModelFromLocalDbByPks(pks);
        }

        _currentData.removeWhere((m) {
          for (var pkCol in _primaryKeyColumns) {
            if (m.toJson()[pkCol] != oldRecord[pkCol]) return false;
          }
          return true;
        });
        break;
      default:
        _log.warning('Unhandled realtime event type: ${payload.eventType}');
        break;
    }
    _sortAndEmitData();
  }

  bool _modelsMatchByPk(TModel model1, TModel model2) {
    final json1 = model1.toJson();
    final json2 = model2.toJson();
    for (final key in _primaryKeyColumns) {
      if (json1[key] != json2[key]) {
        return false;
      }
    }
    return true;
  }

  void _sortAndEmitData() {
    if (_orderConfig != null) {
      final oc = _orderConfig!;
      _currentData.sort((a, b) {
        final valA = a.toJson()[oc.column];
        final valB = b.toJson()[oc.column];
        int comparisonResult;
        if (valA is Comparable && valB is Comparable) {
          comparisonResult = valA.compareTo(valB);
        } else {
          comparisonResult = valA.toString().compareTo(valB.toString());
        }
        return oc.ascending ? comparisonResult : -comparisonResult;
      });
    }

    List<TModel> dataToEmit = _currentData;
    if (_limitConfig != null && _currentData.length > _limitConfig!) {
      dataToEmit = _currentData.take(_limitConfig!).toList();
    }

    if (_dataStreamController != null && !_dataStreamController!.isClosed) {
      _dataStreamController!.add(List<TModel>.from(dataToEmit)); // Emit a copy
      _log.fine(
        'Emitted ${_currentData.length} records for $_supabaseTableName (limited to ${dataToEmit.length}).',
      );
    }
  }

  Future<void> _upsertModelsToLocalDb(List<TModel> models) async {
    if (models.isEmpty) return;
    try {
      final statement = ClientManagerSqlUtils.buildUpsertSqlForModels(
        models,
        _supabaseTableName,
        tableSchemas: _tableSchemas, // Pass the tableSchemas map
      );
      final builtSql = statement.build();
      await _localDb.execute(builtSql.sql, builtSql.arguments);
      _log.fine(
        'Upserted ${models.length} models to local table $_localTableName.',
      );
    } catch (e, s) {
      _log.severe(
        'Error upserting models to local DB for $_localTableName: $e $s',
      );
    }
  }

  Future<void> _deleteModelFromLocalDbByPks(
    Map<String, dynamic> primaryKeyValues,
  ) async {
    if (primaryKeyValues.isEmpty) return;
    try {
      final statement = ClientManagerSqlUtils.buildDeleteSqlByPks(
        _localTableName,
        primaryKeyValues,
      );
      final builtSql = statement.build();
      await _localDb.execute(builtSql.sql, builtSql.arguments);
      _log.fine(
        'Deleted model from local table $_localTableName with PKs: $primaryKeyValues.',
      );
    } catch (e, s) {
      _log.severe(
        'Error deleting model from local DB for $_localTableName: $e $s',
      );
    }
  }

  Future<void> _cancelSubscription() async {
    _log.info('Cancelling subscription for $_supabaseTableName.');
    await _channel?.unsubscribe();
    _channel = null;
    await _dataStreamController?.close();
    _dataStreamController = null;
    _currentData = [];
    _wasSubscribed = false;
    _log.fine(
      'Subscription cancelled and resources cleaned up for $_supabaseTableName.',
    );
  }

  /// Closes the stream and unsubscribes from the channel.
  /// Call this when the manager is no longer needed.
  Future<void> dispose() async {
    await _cancelSubscription();
  }
}

/// Custom exception for Realtime subscription issues.
class RealtimeSubscribeException implements Exception {
  RealtimeSubscribeException(this.status, [this.details]);

  final RealtimeSubscribeStatus status;
  final Object? details;

  @override
  String toString() {
    return 'RealtimeSubscribeException(status: $status, details: $details)';
  }
}
