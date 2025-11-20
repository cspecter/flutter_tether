import 'package:supabase_flutter/supabase_flutter.dart'; // Import the wrapper
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'client_manager_base.dart';
import 'client_manager_models.dart';

/// A builder for transforming Supabase queries with pagination, ordering, and limiting capabilities.
/// Also applies transformations to an associated Drift query if present.
class ClientManagerTransformBuilder<TModel extends TetherModel<TModel>>
    extends ClientManagerBase<TModel> {
  @override
  final PostgrestTransformBuilder<dynamic> supabase;

  ClientManagerTransformBuilder({
    required super.tableName,
    required super.localDb,
    required super.client,
    required this.supabase,
    required super.localTableName,
    required super.tableSchemas,
    required super.fromJsonFactory,
    required super.fromSqliteFactory,
    super.type,
    super.selector,
    required super.localQuery,
    super.maybeSingle,
    super.isRemoteOnly,
    super.isLocalOnly,
    super.selectorStatement,
    required super.baseSupabase,
  }) : super(supabase: supabase);

  // Helper to create a new instance with updated state (immutable approach)
  ClientManagerTransformBuilder<TModel> _copyWithTransform({
    PostgrestTransformBuilder<dynamic>? supabaseTransformBuilder,
    SqlStatement? localQuery,
    bool maybeSingle = false,
    bool? isRemoteOnly,
    bool? isLocalOnly,
  }) {
    return ClientManagerTransformBuilder(
      tableName: tableName,
      localTableName: localTableName,
      localDb: localDb,
      client: client,
      supabase: supabaseTransformBuilder ?? this.supabase,
      baseSupabase: baseSupabase,
      tableSchemas: tableSchemas,
      type: type,
      selector: selector,
      maybeSingle: maybeSingle,
      selectorStatement: selectorStatement,
      localQuery: localQuery ?? this.localQuery,
      isRemoteOnly: isRemoteOnly ?? this.isRemoteOnly,
      isLocalOnly: isLocalOnly ?? this.isLocalOnly,
      fromJsonFactory: fromJsonFactory,
      fromSqliteFactory: fromSqliteFactory,
    );
  }

  /// Set remote only mode, which means the query will only fetch data from the remote database.
  ClientManagerTransformBuilder<TModel> remoteOnly() {
    return _copyWithTransform(isRemoteOnly: true);
  }

  /// Set local only mode, which means the query will only fetch data from the local database.
  ClientManagerTransformBuilder<TModel> localOnly() {
    return _copyWithTransform(isLocalOnly: true);
  }

  /// Order the results.
  ClientManagerTransformBuilder<TModel> order(
    TetherColumn column, {
    bool ascending = true,
    bool nullsFirst = false,
  }) {
    final newSupabaseBuilder = supabase.order(
      column.fullyQualified(tableName),
      ascending: ascending,
      nullsFirst: nullsFirst,
    );

    SqlStatement? newLocalQuery = localQuery;
    if (newLocalQuery != null) {
      newLocalQuery = ClientManagerSqlUtils.applyOrder(
        localQuery!,
        column,
        ascending: ascending,
        nullsFirst: nullsFirst,
      );
    }

    return _copyWithTransform(
      supabaseTransformBuilder: newSupabaseBuilder,
      localQuery: newLocalQuery,
    );
  }

  /// Limit the number of results.
  ClientManagerTransformBuilder<TModel> limit(int count) {
    final newSupabaseBuilder = supabase.limit(count);

    SqlStatement? newLocalQuery = localQuery;
    if (newLocalQuery != null) {
      newLocalQuery = ClientManagerSqlUtils.applyLimit(localQuery!, count);
    }

    return _copyWithTransform(
      supabaseTransformBuilder: newSupabaseBuilder,
      localQuery: newLocalQuery,
    );
  }

  /// Limit the results to rows within the specified range, inclusive.
  ClientManagerTransformBuilder<TModel> range(int from, int to) {
    final newSupabaseBuilder = supabase.range(from, to);

    SqlStatement? newLocalQuery = localQuery;
    if (newLocalQuery != null) {
      newLocalQuery = ClientManagerSqlUtils.applyRange(localQuery!, from, to);
    }

    return _copyWithTransform(
      supabaseTransformBuilder: newSupabaseBuilder,
      localQuery: newLocalQuery,
    );
  }

  /// Limit the results to a single item
  ClientManagerTransformBuilder<TModel> single() {
    final newSupabaseBuilder = supabase.single();

    SqlStatement? newLocalQuery = localQuery;
    if (newLocalQuery != null) {
      newLocalQuery = ClientManagerSqlUtils.applySingle(localQuery!);
    }

    return _copyWithTransform(
      supabaseTransformBuilder: newSupabaseBuilder,
      localQuery: newLocalQuery,
      maybeSingle: true,
    );
  }
}
