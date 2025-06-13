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
  }) {
    return ClientManagerFilterBuilder(
      tableName: tableName,
      localTableName: localTableName,
      localDb: localDb,
      client: client,
      supabase: supabase,
      tableSchemas: tableSchemas,
      type: type ?? this.type,
      selector: selector,
      localQuery: localQuery ?? this.localQuery,
      selectorStatement: selectorStatement ?? this.selectorStatement,
      fromJsonFactory: fromJsonFactory,
      fromSqliteFactory: fromSqliteFactory,
    );
  }

  ClientManagerFilterBuilder<TModel> select(SelectBuilderBase select) {
    final PostgrestFilterBuilder<List<Map<String, dynamic>>> supabaseBuilder =
        supabase.select(select.buildSupabase());

    return _copyWithQuery(
      supabase: supabaseBuilder, // Pass the wrapped Drift statement
      type: SqlOperationType.select,
      localQuery: select.buildSelectWithNestedData(), // Pass the wrapped
      selectorStatement: select,
    );
  }

  ClientManagerFilterBuilder<TModel> insert<TInput extends TetherModelInput<TInput, TModel>>(
    List<TInput> values, {
    bool defaultToNull = true,
  }) {
    return _copyWithQuery(
      supabase: supabase.insert(
        values.map((e) => e.toJson()).toList(),
        defaultToNull: defaultToNull,
      ),
      // No initial driftSelect for insert
      type: SqlOperationType.insert,
      localQuery: ClientManagerSqlUtils.buildInsertSql(values, tableName),
    );
  }

  ClientManagerFilterBuilder<TModel> upsert<TInput extends TetherModelInput<TInput, TModel>>(
    TInput value, {
    String? onConflict,
    bool ignoreDuplicates = false,
    bool defaultToNull = true,
  }) {
    // supabase.upsert returns PostgrestFilterBuilder<dynamic>, which now matches _copyWithQuery
    return _copyWithQuery(
      supabase: supabase.upsert(
        value.toJson(),
        onConflict: onConflict,
        ignoreDuplicates: ignoreDuplicates,
        defaultToNull: defaultToNull,
      ),
      // No initial driftSelect for upsert
      type: SqlOperationType.upsert,
      localQuery: ClientManagerSqlUtils.buildUpdateSql(value, tableName),
    );
  }

  ClientManagerFilterBuilder<TModel> update<TInput extends TetherModelInput<TInput, TModel>>({
    required TInput value,
  }) {
    // supabase.update returns PostgrestFilterBuilder<dynamic>, which now matches _copyWithQuery
    return _copyWithQuery(
      supabase: supabase.update(value.toJson()),
      // No initial driftSelect for update
      type: SqlOperationType.update,
      localQuery: ClientManagerSqlUtils.buildUpdateSql(value, tableName),
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
      supabase: supabase.delete().eq('id', id),
      type: SqlOperationType.delete,
      localQuery: ClientManagerSqlUtils.buildDeleteSql(
        tableName,
        id,
        idColumnName: idColumnName,
      ),
    );
  }
}
