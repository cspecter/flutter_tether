import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/client_manager/manager/client_manager_models.dart'; // For SqlStatement, ClientManagerSqlUtils
import 'package:tether_libs/utils/logger.dart';

/// Manages Supabase RPC calls where the response is expected to conform
/// to the structure of a specific database table and should be stored locally.
///
/// The RPC function's JSON reply must be an array of objects, where each object
/// represents a row with fields corresponding to the `targetSupabaseTableName`'s columns.
class RpcManager<TModel extends TetherModel<TModel>> {
  final SupabaseClient _supabaseClient;
  final SqliteDatabase _localDb;

  // Target table the RPC response mirrors; used for local upsert.
  final String _targetSupabaseTableName;
  final String _targetLocalTableName;

  final FromJsonFactory<TModel> _fromJsonFactory;
  final Map<String, SupabaseTableInfo> _tableSchemas;
  final Logger _logger = Logger('RpcManager');

  RpcManager({
    required SupabaseClient supabaseClient,
    required SqliteDatabase localDb,
    required String targetSupabaseTableName,
    required String targetLocalTableName,
    required FromJsonFactory<TModel> fromJsonFactory,
    required Map<String, SupabaseTableInfo> tableSchemas,
  })  : _supabaseClient = supabaseClient,
        _localDb = localDb,
        _targetSupabaseTableName = targetSupabaseTableName,
        _targetLocalTableName = targetLocalTableName,
        _fromJsonFactory = fromJsonFactory,
        _tableSchemas = tableSchemas;

  /// Call an RPC function.
  /// rpcName: the PostgREST function name to invoke.
  /// params: function params.
  /// storeResult: when true, deserializes and upserts into _targetLocalTableName.
  /// maybeSingle: when true, expects a single JSON object instead of a list.
  Future<dynamic> call(
    String rpcName, {
    Map<String, dynamic>? params,
    bool storeResult = true,
    bool maybeSingle = false,
  }) async {
    _logger.info('Calling RPC: $rpcName with params: $params');
    try {
      final dynamic rpcResponse = await _supabaseClient.rpc(
        rpcName,
        params: params,
      );

      if (!storeResult) {
        _logger.info('RPC "$rpcName" call successful. Result not stored locally.');
        return rpcResponse;
      }

      if (rpcResponse == null) {
        _logger.warning('RPC "$rpcName" returned null. No data to store.');
        return <TModel>[];
      }

      List<Map<String, dynamic>> responseDataList;

      if (maybeSingle) {
        if (rpcResponse is Map<String, dynamic>) {
          responseDataList = [rpcResponse];
        } else {
          _logger.severe(
            'RPC "$rpcName" expected a single object, got: ${rpcResponse.runtimeType}',
          );
          throw RpcResponseFormatException(
            rpcName,
            'Expected a single JSON object (Map).',
            rpcResponse,
          );
        }
      } else {
        if (rpcResponse is List) {
          if (rpcResponse.every((item) => item is Map<String, dynamic>)) {
            responseDataList = rpcResponse.cast<Map<String, dynamic>>();
          } else {
            _logger.severe(
              'RPC "$rpcName" returned a list, but items are not Map<String, dynamic>.',
            );
            throw RpcResponseFormatException(
              rpcName,
              'Expected a List of JSON objects (Map).',
              rpcResponse,
            );
          }
        } else {
          _logger.severe(
            'RPC "$rpcName" did not return a List as expected. Got: ${rpcResponse.runtimeType}',
          );
          throw RpcResponseFormatException(
            rpcName,
            'Expected a List of JSON objects (Map).',
            rpcResponse,
          );
        }
      }

      if (responseDataList.isEmpty) {
        _logger.info('RPC "$rpcName" returned empty list. Nothing to store.');
        return <TModel>[];
      }

      final List<TModel> models =
          responseDataList.map((data) => _fromJsonFactory(data)).toList();

      await _upsertDataToLocalDb(rpcName, models);

      _logger.info(
        'RPC "$rpcName" stored ${models.length} rows into "$_targetLocalTableName".',
      );
      return models;
    } catch (e, s) {
      _logger.severe('Error in RPC "$rpcName": $e\n$s');
      if (e is PostgrestException || e is RpcResponseFormatException) {
        rethrow;
      }
      throw RpcCallException(
        rpcName,
        e.toString(),
        originalException: e,
        stackTrace: s,
      );
    }
  }

  Future<void> _upsertDataToLocalDb(String rpcName, List<TModel> models) async {
    if (models.isEmpty) return;

    final schemaKey = 'public.$_targetSupabaseTableName';
    final tableInfo = _tableSchemas[schemaKey];

    if (tableInfo == null) {
      final errorMsg =
          "Schema for '$schemaKey' not found. Cannot upsert RPC '$rpcName' results.";
      _logger.severe(errorMsg);
      throw Exception(errorMsg);
    }

    if (tableInfo.localName != _targetLocalTableName) {
      _logger.warning(
        "Mismatch: targetLocalTableName ('$_targetLocalTableName') "
        "differs from schema's localName ('${tableInfo.localName}') for '$_targetSupabaseTableName'. "
        "Proceeding with targetLocalTableName.",
      );
    }

    final upsertStatement = ClientManagerSqlUtils.buildUpsertSqlForModels(
      models,
      _targetSupabaseTableName,
      tableSchemas: _tableSchemas,
    );

    _logger.info(
      'Preparing upsert of ${models.length} models from RPC "$rpcName" into "$_targetLocalTableName".',
    );

    await _localDb.writeTransaction((tx) async {
      final finalSql = upsertStatement.build();
      _logger.fine('SQL: ${finalSql.sql} | args: ${finalSql.arguments}');
      await tx.execute(finalSql.sql, finalSql.arguments);
    });
  }
}

/// Custom exception for RPC call failures.
class RpcCallException implements Exception {
  final String rpcName;
  final String message;
  final dynamic originalException;
  final StackTrace? stackTrace;

  RpcCallException(
    this.rpcName,
    this.message, {
    this.originalException,
    this.stackTrace,
  });

  @override
  String toString() {
    String result =
        'RpcCallException: Failed to execute RPC "$rpcName". Message: $message';
    if (originalException != null) {
      result += '\nOriginal Exception: $originalException';
    }
    return result;
  }
}

/// Custom exception for unexpected RPC response formats.
class RpcResponseFormatException implements Exception {
  final String rpcName;
  final String message;
  final dynamic responseReceived;

  RpcResponseFormatException(this.rpcName, this.message, this.responseReceived);

  @override
  String toString() {
    return 'RpcResponseFormatException: RPC "$rpcName" returned data in an unexpected format. Message: $message. Received: $responseReceived';
  }
}
