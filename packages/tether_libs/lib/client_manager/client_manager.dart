import 'package:sqlite_async/sqlite_async.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tether_libs/client_manager/realtime/realtime_manager.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/models/table_info.dart';
import 'manager/client_manager_models.dart';
import 'manager/client_manager_query_builder.dart';
import 'manager/rpc_manager.dart';

class ClientManager<TModel extends TetherModel<TModel>> {
  final String tableName;

  final String localTableName;

  final SqliteDatabase localDb;

  final SupabaseClient client;

  final SupabaseQueryBuilder supabase;

  final Map<String, SupabaseTableInfo> tableSchemas;

  final FromJsonFactory<TModel> fromJsonFactory;

  final FromSqliteFactory<TModel> fromSqliteFactory;

  ClientManager({
    required this.tableName,
    required this.localTableName,
    required this.localDb,
    required this.client,
    required this.tableSchemas,
    required this.fromJsonFactory,
    required this.fromSqliteFactory,
  }) : supabase = client.from(tableName);

  ClientManagerQueryBuilder<TModel> get query {
    return ClientManagerQueryBuilder<TModel>(
      tableName: tableName,
      localTableName: localTableName,
      localDb: localDb,
      client: client,
      supabase: supabase,
      baseSupabase: supabase,
      tableSchemas: tableSchemas,
      fromJsonFactory: fromJsonFactory,
      fromSqliteFactory: fromSqliteFactory,
    );
  }

  RpcManager<TModel> get rpc {
    return RpcManager<TModel>(
      supabaseClient: client,
      localDb: localDb,
      targetSupabaseTableName: tableName,
      targetLocalTableName: localTableName,
      fromJsonFactory: fromJsonFactory,
      tableSchemas: tableSchemas,
    );
  }

  RealtimeManager<TModel> get realtime {
    return RealtimeManager<TModel>(
      supabaseClient: client,
      localDb: localDb,
      fromJsonFactory: fromJsonFactory,
      tableSchemas: tableSchemas,
      supabaseTableName: tableName,
    );
  }
}
