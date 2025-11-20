import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/tether_model_input.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'client_manager_models.dart';
import 'client_manager_base.dart';
import 'client_manager_filter_builder.dart';

class ClientManagerQueryBuilder<TModel extends TetherModel<TModel>>
    extends ClientManagerBase<TModel> {
  @override
  final SupabaseQueryBuilder supabase;

  /// Creates a new query builder.
  ClientManagerQueryBuilder({
    required super.tableName,
    required super.localTableName,
    required super.localDb,
    required super.client,
    required this.supabase,
    required super.baseSupabase,
    required super.tableSchemas,
    required super.fromJsonFactory,
    required super.fromSqliteFactory,
    super.type,
    super.selector,
    super.localQuery,
    super.selectorStatement,
  }) : super(supabase: supabase);

  /// Creates a copy of this builder with a new filter builder.
  ClientManagerFilterBuilder<TModel> _copyWithQuery({
    required PostgrestFilterBuilder<dynamic> supabase,
    SqlOperationType? type,
    SqlStatement? localQuery,
    SelectBuilderBase? selectorStatement,
    TetherModelInputBase? updatePayload,
  }) {
    return ClientManagerFilterBuilder(
      tableName: tableName,
      localTableName: localTableName,
      localDb: localDb,
      client: client,
      supabase: supabase,
      baseSupabase: baseSupabase,
      tableSchemas: tableSchemas,
      type: type ?? this.type,
      selector: selector,
      localQuery: localQuery ?? this.localQuery,
      selectorStatement: selectorStatement ?? this.selectorStatement,
      fromJsonFactory: fromJsonFactory,
      fromSqliteFactory: fromSqliteFactory,
      updatePayload: updatePayload,
    );
  }

  ClientManagerFilterBuilder<TModel> select(SelectBuilderBase select) {
    final PostgrestFilterBuilder<List<Map<String, dynamic>>> supabaseBuilder =
        baseSupabase.select(select.buildSupabase());

    return _copyWithQuery(
      supabase: supabaseBuilder, // Pass the wrapped Drift statement
      type: SqlOperationType.select,
      localQuery: select.buildSelectWithNestedData(), // Pass the wrapped
      selectorStatement: select,
    );
  }

  ClientManagerFilterBuilder<TModel> insert(
    List<TetherModelInputBase> values, {
    bool defaultToNull = true,
  }) {
    return _copyWithQuery(
      supabase: baseSupabase.insert(
        values.map((e) => e.toJson()).toList(),
        defaultToNull: defaultToNull,
      ),
      // No initial driftSelect for insert
      type: SqlOperationType.insert,
      localQuery: ClientManagerSqlUtils.buildInsertSql(values, tableName),
    );
  }

  ClientManagerFilterBuilder<TModel> upsert(
    TetherModelInputBase value, {
    String? onConflict,
    bool ignoreDuplicates = false,
    bool defaultToNull = true,
  }) {
    final localSql = ClientManagerSqlUtils.buildUpsertSql(
      [value],
      tableName,
      tableSchemas: tableSchemas,
      defaultToNull: defaultToNull,
    );

    return _copyWithQuery(
      supabase: baseSupabase.upsert(
        value.toJson(),
        onConflict: onConflict,
        ignoreDuplicates: ignoreDuplicates,
        defaultToNull: defaultToNull,
      ),
      type: SqlOperationType.upsert,
      localQuery: localSql,
    );
  }

  ClientManagerFilterBuilder<TModel> update(
    TetherModelInputBase value,
  ) {
    // For update, the localQuery's SET and WHERE clauses are built by the
    // filter builder methods. We pass the update payload here.
    return _copyWithQuery(
      supabase: baseSupabase.update(value.toJson()),
      type: SqlOperationType.update,
      updatePayload: value, // Pass the update payload
    );
  }

  ClientManagerFilterBuilder<TModel> delete(
    dynamic id, {
    String idColumnName = 'id',
  }) {
    if (id is! String && id is! int) {
      throw ArgumentError('ID must be either a String or an int');
    }

    return _copyWithQuery(
      supabase: baseSupabase.delete().eq('id', id),
      type: SqlOperationType.delete,
      localQuery: ClientManagerSqlUtils.buildDeleteSql(
        tableName,
        id,
        idColumnName: idColumnName,
      ),
    );
  }
}
