// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: constant_identifier_names

import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/utils/logger.dart';
import 'package:sqlite_async/sqlite3_common.dart';
import 'package:tether_libs/client_manager/client_manager.dart';
import 'package:tether_libs/client_manager/manager/client_manager_filter_builder.dart';
import 'package:tether_libs/client_manager/manager/client_manager_models.dart';
import 'package:tether_libs/client_manager/manager/client_manager_base.dart'; // Import TetherClientReturn
import 'package:sqlite_async/sqlite_async.dart'; // Ensure SqliteDatabase is imported

import '../database.dart';
import '../managers/feed_item_reference_manager.g.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef QueryBuilderFactory<TModel extends TetherModel<TModel>> =
    ClientManagerFilterBuilder<TModel> Function();

class FeedStreamNotifierSettings<TModel extends TetherModel<TModel>>
    extends Equatable {
  final String feedKey;
  final TetherColumn? searchColumn; // Made nullable
  final int pageSize;
  final ClientManager<TModel> clientManager;
  final SelectBuilderBase selectArgs;
  final TModel Function(Map<String, dynamic> json) fromJsonFactory;
  final ClientManagerFilterBuilder<TModel> Function(
    ClientManagerFilterBuilder<TModel> baseQuery,
  )?
  queryCustomizer; // This can define the "base filtered view"
  
  // New ordering fields
  final TetherColumn? defaultOrderColumn;
  final bool defaultOrderAscending;
  final bool defaultOrderNullsFirst;

  const FeedStreamNotifierSettings({
    required this.feedKey,
    this.searchColumn, // Nullable, so not required
    required this.clientManager,
    required this.selectArgs,
    required this.fromJsonFactory,
    this.pageSize = 20,
    this.queryCustomizer,
    this.defaultOrderColumn, // Add default ordering column
    this.defaultOrderAscending = true, // Default to ascending order
    this.defaultOrderNullsFirst = false, // Default to nulls last
  });

  @override
  List<Object?> get props => [
    feedKey,
    searchColumn,
    pageSize,
    clientManager, // Relies on stable identity from its provider
    selectArgs, // Relies on stable identity (e.g., const)
    fromJsonFactory, // Static methods have stable identity
    queryCustomizer, // Needs stable identity if provided
    defaultOrderColumn, // Add to props
    defaultOrderAscending,
    defaultOrderNullsFirst,
  ];
}

class FeedStreamNotifier<TModel extends TetherModel<TModel>>
    extends
        FamilyStreamNotifier<List<TModel>, FeedStreamNotifierSettings<TModel>> {
  late FeedStreamNotifierSettings<TModel> _currentSettings;

  int currentPage = 0;
  String terms = '';
  bool _isDisposed = false;
  final Logger _logger = Logger('SearchStreamNotifier');

  // Track the total count from remote
  int? _totalRemoteCount;

  // For dynamic filters applied on top of queryCustomizer
  ClientManagerFilterBuilder<TModel> Function(
    ClientManagerFilterBuilder<TModel> query,
  )?
  _dynamicFilterApplicator;
  
  // New ordering state variables
  TetherColumn? _orderColumn;
  bool _orderAscending = true;
  bool _orderNullsFirst = false;

  FeedStreamNotifier() {
    // Initialization in build
  }

  ClientManagerFilterBuilder<TModel> _getEffectiveQueryBuilder() {
    // 1. Start with the absolute base query from settings
    var query = _currentSettings.clientManager.query.select(
      _currentSettings.selectArgs,
    );

    // 2. Apply the "base query modifications" (static customizer) from settings
    if (_currentSettings.queryCustomizer != null) {
      query = _currentSettings.queryCustomizer!(query);
    }

    // 3. Apply dynamic filters if any are set
    if (_dynamicFilterApplicator != null) {
      query = _dynamicFilterApplicator!(query);
    }

    // 4. Apply search terms if search is configured and terms are present
    if (_currentSettings.searchColumn != null && terms.isNotEmpty) {
      query = query.textSearch(_currentSettings.searchColumn!, terms);
    }
    
    // 5. Apply ordering if set
    if (_orderColumn != null) {
      query = query.order(
        _orderColumn!, 
        ascending: _orderAscending, 
        nullsFirst: _orderNullsFirst
      ) as ClientManagerFilterBuilder<TModel>;
    }
    
    return query;
  }

  // Helper to get the query structure for feedStream's JSON sub-select
  ClientManagerFilterBuilder<TModel> _getBaseQueryForFeedStreamSchema() {
    var baseQuery = _currentSettings.clientManager.query.select(
      _currentSettings.selectArgs,
    );
    if (_currentSettings.queryCustomizer != null) {
      baseQuery = _currentSettings.queryCustomizer!(baseQuery);
    }
    return baseQuery;
  }

  /// Calculate how many items we currently have in the feed
  int get _currentItemCount => currentPage * _currentSettings.pageSize;

  /// Check if there are more items available to fetch
  bool get _hasMoreItems {
    if (_totalRemoteCount == null)
      return true; // Unknown count, assume more available
    return _currentItemCount < _totalRemoteCount!;
  }

  @override
  Stream<List<TModel>> build(FeedStreamNotifierSettings<TModel> arg) async* {
    _currentSettings = arg;
    currentPage = 0;
    terms = '';
    _dynamicFilterApplicator = null; // Reset dynamic filters
    _totalRemoteCount = null; // Reset count tracking
    _isDisposed = false;
    
    // Initialize ordering from settings
    _orderColumn = arg.defaultOrderColumn;
    _orderAscending = arg.defaultOrderAscending;
    _orderNullsFirst = arg.defaultOrderNullsFirst;

    ref.onDispose(() {
      _isDisposed = true;
    });

    final count = await _getCount();
    if (_isDisposed) return;

    if (count == 0) {
      await refreshFeed(initialize: true);
    } else {
      await refreshFeed();
    }
    if (_isDisposed) return;

    yield* feedStream;
  }

  Stream<List<TModel>> get feedStream async* {
    final appDatabase = ref.watch(databaseProvider).value!;
    final sqliteDb = appDatabase.db as SqliteDatabase;

    // Use the base query (with static customizer) for determining table name and selector for SQL
    final baseQueryForSchema = _getBaseQueryForFeedStreamSchema();
    final modelTableName = baseQueryForSchema.tableName;
    final SelectBuilderBase? selector = baseQueryForSchema.selectorStatement;

    if (selector == null) {
      _logger.severe(
        "SearchStreamNotifier: selectorStatement is null in feedStream for $modelTableName. This indicates a setup error with base query.",
      );
      yield <TModel>[];
      return;
    }

    final SqlStatement jsonSelectSubQueryStatement =
        selector.buildSelectWithNestedData();

    if (selector.currentTableInfo.primaryKeys.isEmpty) {
      _logger.severe(
        "SearchStreamNotifier: Table ${selector.currentTableInfo.originalName} has no primary keys defined. Cannot build feedStream SQL.",
      );
      yield <TModel>[];
      return;
    }
    final String modelPrimaryKeyCol =
        selector.currentTableInfo.primaryKeys.first.originalName;
    final String aliasInSubQuery =
        jsonSelectSubQueryStatement.fromAlias ?? 't_fallback';

    // Note: The SQL query for the stream is maintaining the feed_item_references display_order,
    // not applying the custom ordering. This is because the feed structure maintains its own order.
    // The custom ordering affects how items are fetched from the server and inserted into the feed.
    final sql = '''
      SELECT
        fir.id AS feed_item_ref_id,
        fir.feed_key,
        fir.item_source_table,
        fir.item_source_id,
        fir.display_order,
        CASE
            WHEN fir.item_source_table = ? THEN (
                SELECT ${jsonSelectSubQueryStatement.selectColumns}
                FROM "${jsonSelectSubQueryStatement.tableName}" AS "$aliasInSubQuery"
                WHERE "$aliasInSubQuery"."$modelPrimaryKeyCol" = fir.item_source_id
            )
            ELSE NULL
        END AS item_json_data
      FROM
        feed_item_references fir
      WHERE
        fir.feed_key = ?
      ORDER BY
        fir.display_order ASC;
    ''';

    yield* sqliteDb.watch(sql, parameters: [modelTableName, _currentSettings.feedKey]).map<
      List<TModel>
    >((ResultSet rawData) {
      // Explicit type for map's T and rawData
      if (_isDisposed) return <TModel>[];
      return rawData
          .map((row) {
            final jsonData = row['item_json_data'];
            if (jsonData == null) return null;

            Map<String, dynamic> parsedJson;
            if (jsonData is String) {
              try {
                parsedJson = jsonDecode(jsonData) as Map<String, dynamic>;
              } catch (e) {
                _logger.warning(
                  'SearchStreamNotifier: JSONDecode error for item_json_data: $e, data: $jsonData',
                );
                return null;
              }
            } else if (jsonData is Map<String, dynamic>) {
              parsedJson = jsonData;
            } else {
              _logger.warning(
                'SearchStreamNotifier: Unexpected format for item_json_data: ${jsonData.runtimeType}',
              );
              return null;
            }
            try {
              return _currentSettings.fromJsonFactory(parsedJson);
            } catch (e) {
              _logger.severe(
                'SearchStreamNotifier: Error in fromJsonFactory for $modelTableName: $e, json: $parsedJson',
              );
              return null;
            }
          })
          .whereType<TModel>()
          .toList();
    });
  }

  Future<int> _getCount() async {
    final feedManager = ref.read(feedItemReferenceManagerProvider);
    return await feedManager.getCount(feedKey: _currentSettings.feedKey);
  }

  Future<void> refreshFeed({bool initialize = false}) async {
    try {
      _logger.info(
        'refreshFeed called. initialize: $initialize, current terms: "$terms", dynamicFiltersSet: ${_dynamicFilterApplicator != null}, orderColumn: $_orderColumn',
      );

      // _fetch will use _getEffectiveQueryBuilder() and return TetherClientReturn
      final result = await _fetch(
        rangeStart: 0,
        rangeEnd: _currentSettings.pageSize - 1,
      );

      if (_isDisposed) return;

      // Update the total count from the remote response
      if (result.count != null) {
        _totalRemoteCount = result.count;
        _logger.info(
          'Updated total remote count to: $_totalRemoteCount for feedKey: ${_currentSettings.feedKey}',
        );
      }

      final items = result.data;
      final feedManager = ref.read(feedItemReferenceManagerProvider);
      final feedKey = _currentSettings.feedKey;
      final effectiveQuery = _getEffectiveQueryBuilder(); // To get tableName

      if (initialize) {
        await feedManager.clearFeed(feedKey: feedKey);
        if (_isDisposed) return;
        await feedManager.setFeedItems(
          feedKey: feedKey,
          items:
              items
                  .asMap()
                  .entries
                  .map(
                    (e) => FeedItemReference(
                      itemSourceTable:
                          effectiveQuery
                              .tableName, // Use effective query's table
                      itemSourceId: e.value.localId,
                      displayOrder: e.key,
                    ),
                  )
                  .toList(),
        );
      } else {
        // addItemsToStart might not be the right behavior if filters change.
        // Consider if 'initialize: true' should always be used when filters or search terms change.
        // For now, keeping existing logic.
        await feedManager.addItemsToStart(
          feedKey: feedKey,
          newItemsToAdd:
              items
                  .asMap()
                  .entries
                  .map(
                    (e) => FeedItemReference(
                      itemSourceTable:
                          effectiveQuery
                              .tableName, // Use effective query's table
                      itemSourceId: e.value.localId,
                      displayOrder: e.key,
                    ),
                  )
                  .toList(),
        );
      }
      if (_isDisposed) return;
      currentPage = 0;
    } catch (e, s) {
      if (!_isDisposed) {
        state = AsyncValue.error(e, s);
      } else {
        _logger.warning(
          "SearchStreamNotifier: Error in refreshFeed but unmounted: $e",
        );
      }
    }
  }

  Future<void> fetchMoreItems() async {
    // Check if there are more items to fetch based on the count
    if (!_hasMoreItems) {
      _logger.info(
        'fetchMoreItems: No more items to fetch. Current count: $_currentItemCount, Total remote count: $_totalRemoteCount',
      );
      return;
    }

    final nextPage = currentPage + 1;
    try {
      final rangeStart = nextPage * _currentSettings.pageSize;
      final rangeEnd = ((nextPage + 1) * _currentSettings.pageSize) - 1;

      // _fetch will use _getEffectiveQueryBuilder() and return TetherClientReturn
      final result = await _fetch(rangeStart: rangeStart, rangeEnd: rangeEnd);

      if (_isDisposed) return;

      // Update the total count if provided (it should be consistent)
      if (result.count != null && result.count != _totalRemoteCount) {
        _logger.info(
          'fetchMoreItems: Updated total remote count from $_totalRemoteCount to ${result.count}',
        );
        _totalRemoteCount = result.count;
      }

      final newItems = result.data;

      if (newItems.isNotEmpty) {
        final feedManager = ref.read(feedItemReferenceManagerProvider);
        final effectiveQuery = _getEffectiveQueryBuilder(); // To get tableName
        await feedManager.addItemsToEnd(
          feedKey: _currentSettings.feedKey,
          itemsToAdd:
              newItems
                  .map(
                    (item) => FeedItemReference(
                      itemSourceTable:
                          effectiveQuery
                              .tableName, // Use effective query's table
                      itemSourceId: item.localId,
                      // displayOrder for addItemsToEnd is handled by the manager
                      displayOrder: -1, // Or let manager handle it
                    ),
                  )
                  .toList(),
        );
        if (_isDisposed) return;
        currentPage = nextPage;

        _logger.info(
          'fetchMoreItems: Added ${newItems.length} items. Current page: $currentPage, Total remote count: $_totalRemoteCount',
        );
      }
    } catch (e, s) {
      if (!_isDisposed) {
        state = AsyncValue.error(e, s);
      } else {
        _logger.warning(
          "SearchStreamNotifier: Error in fetchMoreItems but unmounted: $e",
        );
      }
    }
  }

  Future<TetherClientReturn<TModel>> _fetch({
    int rangeStart = 0,
    int rangeEnd = 20,
  }) async {
    final effectiveQuery = _getEffectiveQueryBuilder();
    // The textSearch is now part of _getEffectiveQueryBuilder if terms are set
    // Now returns TetherClientReturn<TModel> instead of List<TModel>
    return await effectiveQuery.range(rangeStart, rangeEnd).remoteOnly();
  }

  Future<void> search(String newTerms) async {
    if (_currentSettings.searchColumn == null && newTerms.isNotEmpty) {
      _logger.warning(
        "SearchStreamNotifier: Search initiated for '$newTerms' but no searchColumn is configured for feedKey '${_currentSettings.feedKey}'.",
      );
      // Optionally, clear terms if search is not supported
      // terms = '';
      // return; // Or proceed to refresh without search
    }
    if (_currentSettings.searchColumn == null &&
        newTerms.isEmpty &&
        terms.isEmpty) {
      // If search isn't configured and both new and old terms are empty, no need to refresh if only terms changed.
      // However, if other filters might have changed, a refresh might still be desired.
      // For simplicity, we'll proceed with refresh, as `refreshFeed` handles the effective query.
    }

    terms = newTerms;
    currentPage = 0;
    _totalRemoteCount = null; // Reset count when searching
    await refreshFeed(initialize: true);
  }

  /// Applies a new set of dynamic filters to the feed.
  /// The [filterApplicator] function takes the current base query (after static customizers)
  /// and should return a new query with the dynamic filters applied.
  Future<void> applyDynamicFilters(
    ClientManagerFilterBuilder<TModel> Function(
      ClientManagerFilterBuilder<TModel> baseQueryWithoutDynamicFilters,
    )
    filterApplicator,
  ) async {
    _logger.info(
      "Applying dynamic filters for feedKey '${_currentSettings.feedKey}'.",
    );
    _dynamicFilterApplicator = filterApplicator;
    currentPage = 0;
    _totalRemoteCount = null; // Reset count when filters change
    // It's usually best to re-initialize the feed when filters change significantly.
    // Also, consider if search terms should be cleared or maintained.
    // For now, maintaining search terms.
    await refreshFeed(initialize: true);
  }

  /// Clears any previously applied dynamic filters, reverting to the base query
  /// (which includes the static queryCustomizer from settings).
  Future<void> clearDynamicFilters() async {
    if (_dynamicFilterApplicator != null) {
      _logger.info(
        "Clearing dynamic filters for feedKey '${_currentSettings.feedKey}'.",
      );
      _dynamicFilterApplicator = null;
      currentPage = 0;
      _totalRemoteCount = null; // Reset count when filters change
      // Also consider if search terms should be cleared.
      await refreshFeed(initialize: true);
    } else {
      _logger.info(
        "No dynamic filters to clear for feedKey '${_currentSettings.feedKey}'.",
      );
    }
  }
  
  /// Apply a new ordering to the feed items.
  ///
  /// This will fetch items from the remote source in the specified order
  /// and rebuild the feed with those items.
  ///
  /// [column] - The column to order by
  /// [ascending] - Whether to order in ascending (true) or descending (false) order
  /// [nullsFirst] - Whether NULL values should be first (true) or last (false) when ordering
  Future<void> applyOrdering({
    required TetherColumn column,
    bool ascending = true,
    bool nullsFirst = false,
  }) async {
    _logger.info(
      "Applying ordering for feedKey '${_currentSettings.feedKey}': ${column.columnName} ${ascending ? 'ASC' : 'DESC'}, nullsFirst: $nullsFirst",
    );
    _orderColumn = column;
    _orderAscending = ascending;
    _orderNullsFirst = nullsFirst;
    currentPage = 0;
    _totalRemoteCount = null; // Reset count when ordering changes
    await refreshFeed(initialize: true);
  }

  /// Clears the custom ordering, reverting to the default ordering (if any)
  Future<void> clearOrdering() async {
    _logger.info(
      "Clearing ordering for feedKey '${_currentSettings.feedKey}'.",
    );
    _orderColumn = _currentSettings.defaultOrderColumn;
    _orderAscending = _currentSettings.defaultOrderAscending;
    _orderNullsFirst = _currentSettings.defaultOrderNullsFirst;
    currentPage = 0;
    _totalRemoteCount = null; // Reset count when clearing ordering
    await refreshFeed(initialize: true);
  }

  /// Getter to expose the current total count for UI components
  int? get totalRemoteCount => _totalRemoteCount;

  /// Getter to expose whether more items are available for UI components
  bool get hasMoreItems => _hasMoreItems;
}





