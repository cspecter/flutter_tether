import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tether_libs/utils/logger.dart'; // Assuming you have a Logger utility

class FeedProviderGenerator {
  final String outputDirectory; // e.g., 'example/frontend/lib'
  final Logger _logger;

  FeedProviderGenerator({required this.outputDirectory, Logger? logger})
    : _logger = logger ?? Logger('FeedProviderGenerator');

  Future<void> generate() async {
    final providersDir = p.join(outputDirectory);
    final fileName = 'feed_provider.dart';
    final filePath = p.join(providersDir, fileName);

    final buffer = StringBuffer();

    buffer.writeln('');
    buffer.writeln(r"""
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: constant_identifier_names

import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite_async/sqlite3_common.dart';
import 'package:sqlite_async/sqlite_async.dart'; // Ensure SqliteDatabase is imported
import 'package:tether_libs/client_manager/client_manager.dart';
import 'package:tether_libs/client_manager/manager/client_manager_base.dart'; // Import TetherClientReturn
import 'package:tether_libs/client_manager/manager/client_manager_filter_builder.dart';
import 'package:tether_libs/client_manager/manager/client_manager_models.dart';
import 'package:tether_libs/client_manager/manager/client_manager_transform_builder.dart';
import 'package:tether_libs/models/supabase_select_builder_base.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/utils/logger.dart';

import '../database.dart';
import '../managers/feed_item_reference_manager.g.dart';

/// Creates a `Row` instance from a standard `Map<String, dynamic>`.
///
/// This is useful for creating mock data or converting nested JSON objects
/// into a `Row` that model factories can consume.
Row _createRowFromMap(Map<String, dynamic> map) {
  final columnNames = map.keys.toList();
  final values = map.values.toList();

  final mockResultSet = ResultSet(
    columnNames,
    null, // tableNames are not needed for this conversion
    [values], // A list containing our single row of values
  );

  // The ResultSet is a list of Rows. The Row we want is the first one.
  return mockResultSet[0];
}

typedef QueryBuilderFactory<TModel extends TetherModel<TModel>>
    = ClientManagerFilterBuilder<TModel> Function();

/// A class that wraps the feed data with additional state information
class FeedStreamState<TModel extends TetherModel<TModel>> {
  final List<TModel> data;
  final String? error;
  final int? count;
  final bool isLoading;

  const FeedStreamState({
    required this.data,
    this.error,
    this.count,
    this.isLoading = false,
  });

  bool get hasMore {
    if (data.isEmpty) return true; // If no data, assume more items

    if (count == null) return true; // If count is unknown, assume more items
    return data.length < count!;
  }

  bool get hasError => error != null && error!.isNotEmpty;

  FeedStreamState<TModel> copyWith({
    List<TModel>? data,
    String? error,
    int? count,
    bool? isLoading,
  }) {
    return FeedStreamState<TModel>(
      data: data ?? this.data,
      error: error ?? this.error,
      count: count ?? this.count,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  @override
  String toString() {
    return 'FeedStreamState(data: ${data.length} items, error: $error, count: $count, isLoading: $isLoading)';
  }
}

class FeedStreamNotifierSettings<TModel extends TetherModel<TModel>>
    extends Equatable {
  final String feedKey;
  final TetherColumn? searchColumn;
  final String? searchRpcName; // <-- Add this line
  final int pageSize;
  final ClientManager<TModel> clientManager;
  final SelectBuilderBase selectArgs;
  final TModel Function(Row row) fromJsonFactory;
  final ClientManagerFilterBuilder<TModel> Function(
    ClientManagerFilterBuilder<TModel> baseQuery,
    Ref ref,
  )? queryCustomizer;
  final TetherColumn? defaultOrderColumn;
  final bool defaultOrderAscending;
  final bool defaultOrderNullsFirst;
  final bool fetchOnBuild;
  final TetherColumn? primaryKeyColumn;

  const FeedStreamNotifierSettings({
    required this.feedKey,
    this.searchColumn,
    this.searchRpcName, // <-- Add this line
    required this.clientManager,
    required this.selectArgs,
    required this.fromJsonFactory,
    this.pageSize = 20,
    this.queryCustomizer,
    this.defaultOrderColumn,
    this.defaultOrderAscending = true,
    this.defaultOrderNullsFirst = false,
    this.fetchOnBuild = true,
    this.primaryKeyColumn,
  });

  @override
  List<Object?> get props => [
        feedKey,
        searchColumn,
        searchRpcName, // <-- Add this line
        pageSize,
        clientManager,
        selectArgs,
        fromJsonFactory,
        queryCustomizer,
        defaultOrderColumn,
        defaultOrderAscending,
        defaultOrderNullsFirst,
        fetchOnBuild,
        primaryKeyColumn,
      ];
}

class FeedStreamNotifier<TModel extends TetherModel<TModel>>
    extends StreamNotifier<FeedStreamState<TModel>> {
  late FeedStreamNotifierSettings<TModel> _currentSettings;

  final FeedStreamNotifierSettings<TModel> arg;

  int currentPage = 0;
  String terms = '';
  bool _isDisposed = false;
  final Logger _logger = Logger('SearchStreamNotifier');

  // Track the total count from remote
  int? _totalRemoteCount;
  // Track loading state
  bool _isLoading = false;
  // Track error state
  String? _error;

  // Add this to track the current search operation
  int _currentSearchId = 0;

  // New state for excluded IDs
  List<String>? _excludedIds;

  // For dynamic filters applied on top of queryCustomizer
  ClientManagerFilterBuilder<TModel> Function(
    ClientManagerFilterBuilder<TModel> query,
  )? _dynamicFilterApplicator;

  // New ordering state variables
  TetherColumn? _orderColumn;
  bool _orderAscending = true;
  bool _orderNullsFirst = false;

  FeedStreamNotifier(this.arg);

  ClientManagerTransformBuilder<TModel> _getEffectiveQueryBuilder() {
    // 1. Start with the absolute base query from settings.
    ClientManagerFilterBuilder<TModel> baseQuery =
        _currentSettings.clientManager.query.select(
      _currentSettings.selectArgs,
    );

    // 2. Apply the "base query modifications" (static customizer) from settings
    if (_currentSettings.queryCustomizer != null) {
      baseQuery = _currentSettings.queryCustomizer!(
        baseQuery,
        ref,
      );
    }

    // Start the final query from the customized base query
    ClientManagerFilterBuilder<TModel> filterQuery = baseQuery;

    // 3. Apply dynamic filters if any are set
    if (_dynamicFilterApplicator != null) {
      filterQuery = _dynamicFilterApplicator!(filterQuery);
    }

    // 3.5 Apply excluded IDs if any are set
    if (_excludedIds != null &&
        _excludedIds!.isNotEmpty &&
        _currentSettings.primaryKeyColumn != null) {
      filterQuery = filterQuery.not(
          _currentSettings.primaryKeyColumn!, 'in', _excludedIds!);
    }

    // 4. Apply search terms if search is configured and terms are present
    if (_currentSettings.searchColumn != null && terms.isNotEmpty) {
      // textSearch is available on ClientManagerFilterBuilder
      filterQuery =
          filterQuery.textSearch(_currentSettings.searchColumn!, terms);
    }

    // 5. Apply ordering if set. The result is a TransformBuilder, so we assign it to a new variable.
    ClientManagerTransformBuilder<TModel> transformQuery = filterQuery;

    // When a search is active, always prioritize ordering by relevance.
    if (_currentSettings.searchColumn != null && terms.isNotEmpty) {
      // The .order() method in the Tether client supports ordering by rank for FTS.
      // We pass the search column and the search terms to it.
      transformQuery = transformQuery.order(
        _currentSettings.searchColumn!,
        ascending:
            false, // Higher rank is more relevant, so we sort descending.
      );
    } else if (_orderColumn != null) {
      // .order() is available on the parent ClientManagerTransformBuilder
      transformQuery = transformQuery.order(_orderColumn!,
          ascending: _orderAscending, nullsFirst: _orderNullsFirst);
    } else if (_currentSettings.searchColumn != null) {
      transformQuery = transformQuery.order(_currentSettings.searchColumn!,
          ascending: false, nullsFirst: true);
    }

    return transformQuery;
  }

  // Helper to get the query structure for feedStream's JSON sub-select
  ClientManagerFilterBuilder<TModel> _getBaseQueryForFeedStreamSchema() {
    var baseQuery = _currentSettings.clientManager.query.select(
      _currentSettings.selectArgs,
    );
    if (_currentSettings.queryCustomizer != null) {
      baseQuery = _currentSettings.queryCustomizer!(
        baseQuery,
        ref,
      );
    }
    return baseQuery;
  }

  /// Calculate how many items we currently have in the feed
  int get _currentItemCount => currentPage * _currentSettings.pageSize;

  /// Check if there are more items available to fetch
  bool get _hasMoreItems {
    if (_totalRemoteCount == null) {
      return true; // Unknown count, assume more available
    }
    return _currentItemCount < _totalRemoteCount!;
  }

  @override
  Stream<FeedStreamState<TModel>> build() async* {
    _currentSettings = arg;
    currentPage = 0;
    terms = '';
    _dynamicFilterApplicator = null;
    _totalRemoteCount = null;
    _isDisposed = false;
    _isLoading = false;
    _error = null;
    _excludedIds = null; // Initialize new state

    // Initialize ordering from settings
    _orderColumn = arg.defaultOrderColumn;
    _orderAscending = arg.defaultOrderAscending;
    _orderNullsFirst = arg.defaultOrderNullsFirst;

    ref.onDispose(() {
      _isDisposed = true;
    });

    // Yield initial loading state
    yield FeedStreamState<TModel>(
      data: <TModel>[],
      error: null,
      count: null,
      isLoading: true,
    );

    try {
      final feedStream = _buildFeedStreamState();

      final count = await _getCount();
      if (_isDisposed) return;

      // Refresh if count is 0 or fetchOnBuild is true
      if (arg.fetchOnBuild && count == 0) {
        _logger.info(
          'FeedStreamNotifier: Initial count is 0 for feedKey: ${_currentSettings.feedKey}. Refreshing feed.',
        );
        await refreshFeed(initialize: true);
      } else if (arg.fetchOnBuild) {
        _logger.info(
          'FeedStreamNotifier: Initial count is > 0 for feedKey: ${_currentSettings.feedKey}. Refreshing feed.',
        );
        await refreshFeed(initialize: true);
      } else if (count == 0) {
        _logger.info(
          'FeedStreamNotifier: Initial count is 0 for feedKey: ${_currentSettings.feedKey}. Refreshing feed.',
        );
        await refreshFeed(initialize: true);
      }

      yield* feedStream;
    } catch (e) {
      if (!_isDisposed) {
        _isLoading = false;
        _error = e.toString();
        yield FeedStreamState<TModel>(
          data: <TModel>[],
          error: _error,
          count: _totalRemoteCount,
          isLoading: false,
        );
      }
    }
  }

  Stream<FeedStreamState<TModel>> _buildFeedStreamState() async* {
    try {
      final appDatabase = ref.read(databaseProvider);
      final sqliteDb = appDatabase.db as SqliteDatabase;

      // Use the base query (with static customizer) for determining table name and selector for SQL
      final baseQueryForSchema = _getBaseQueryForFeedStreamSchema();
      final modelTableName = baseQueryForSchema.tableName;
      final SelectBuilderBase? selector = baseQueryForSchema.selectorStatement;

      if (selector == null) {
        _logger.severe(
          "SearchStreamNotifier: selectorStatement is null in feedStream for ${modelTableName}. This indicates a setup error with base query.",
        );
        yield FeedStreamState<TModel>(
          data: <TModel>[],
          error: "Setup error: selectorStatement is null",
          count: _totalRemoteCount,
          isLoading: false,
        );
        return;
      }

      final SqlStatement jsonSelectSubQueryStatement =
          selector.buildSelectWithNestedData();

      if (selector.currentTableInfo.primaryKeys.isEmpty) {
        _logger.severe(
          "SearchStreamNotifier: Table ${selector.currentTableInfo.originalName} has no primary keys defined. Cannot build feedStream SQL.",
        );
        yield FeedStreamState<TModel>(
          data: <TModel>[],
          error: "Setup error: No primary keys defined",
          count: _totalRemoteCount,
          isLoading: false,
        );
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

      // _logger.info(
      //   sql,
      // );

      yield* sqliteDb.watch(
        sql,
        parameters: [
          modelTableName,
          _currentSettings.feedKey,
        ],
        // throttle: const Duration(milliseconds: 100),
        triggerOnTables: [modelTableName, 'feed_item_references'],
      ).map<FeedStreamState<TModel>>((ResultSet rawData) {
        // Process the raw data into a list of models
        if (_isDisposed) {
          return FeedStreamState<TModel>(
            data: <TModel>[],
            error: _error,
            count: _totalRemoteCount,
            isLoading: _isLoading,
          );
        }

        _logger.info(
          'SearchStreamNotifier: Emitted ${rawData.length} rows for feedKey: ${_currentSettings.feedKey}',
        );

        final List<TModel> models = rawData
            .map((row) {
              final jsonData = row['item_json_data'];

              if (jsonData == null || jsonData is String && jsonData.isEmpty) {
                _logger.warning(
                  'SearchStreamNotifier: item_json_data is null or empty for row: $row',
                );
                return null; // Skip this row
              }

              Map<String, dynamic> parsedJson;
              if (jsonData is String) {
                try {
                  parsedJson = jsonDecode(jsonData) as Map<String, dynamic>;
                } catch (e, s) {
                  _logger.warning(
                    'SearchStreamNotifier: JSONDecode error for item_json_data: $e, data: $jsonData $s',
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
                final newRow = _createRowFromMap(parsedJson);
                return _currentSettings.fromJsonFactory(newRow);
              } catch (e, s) {
                _logger.severe(
                  'SearchStreamNotifier: Error in fromJsonFactory for $modelTableName: $e, json: $parsedJson StackTrace: $s',
                );
                return null;
              }
            })
            .whereType<TModel>()
            .toList();

        _logger.info(
          'SearchStreamNotifier: Processed ${models.length} valid models for feedKey: ${_currentSettings.feedKey}',
        );

        return FeedStreamState<TModel>(
          data: models,
          error: _error,
          count: _totalRemoteCount,
          isLoading: _isLoading,
        );
      });
    } catch (e, s) {
      _logger.severe(
        'SearchStreamNotifier: Error in _buildFeedStreamState: $e StackTrace: $s',
      );
      yield FeedStreamState<TModel>(
        data: <TModel>[],
        error: e.toString(),
        count: _totalRemoteCount,
        isLoading: false,
      );
    }
  }

  Future<int> _getCount() async {
    final feedManager = ref.read(feedItemReferenceManagerProvider);
    return await feedManager.getCount(feedKey: _currentSettings.feedKey);
  }

  Future<void> refreshFeed({bool initialize = false}) async {
    // REMOVED this block to allow new searches to interrupt old ones.
    // if (_isLoading) {
    //   _logger.info('Already refreshing, skipping.');
    //   return;
    // }

    // Increment and capture the search ID for this specific refresh operation.
    final searchId = ++_currentSearchId;

    try {
      _isLoading = true;
      if (state.value != null) {
        state = AsyncData(
          state.value!.copyWith(isLoading: true, error: null),
        );
      }

      final feedManager = ref.read(feedItemReferenceManagerProvider);

      if (initialize) {
        await feedManager.clearFeed(feedKey: _currentSettings.feedKey);
        currentPage = 0;
      }

      final TetherClientReturn<TModel> result = await _fetch(
        rangeStart: 0,
        rangeEnd: _currentSettings.pageSize - 1,
      );

      // Before applying the result, check if this is still the latest search.
      // If not, another search has been initiated, so we discard this result.
      if (_isDisposed || searchId != _currentSearchId) {
        _logger.info(
          'Search result for ID $searchId is stale, discarding. Current ID is $_currentSearchId.',
        );
        // Even if stale, we might need to turn off the loading indicator
        // if this stale operation was the one that turned it on and no new one has.
        // However, the finally block handles this better.
        return;
      }

      final newItems = result.data;
      _totalRemoteCount = result.count;

      if (newItems.isNotEmpty) {
        final feedItems = newItems.map((item) {
          return FeedItemReference(
            itemSourceTable: _currentSettings.clientManager.localTableName,
            itemSourceId: item.localId.toString(),
            displayOrder: 0,
          );
        }).toList();

        await feedManager.setFeedItems(
          feedKey: _currentSettings.feedKey,
          items: feedItems,
        );
        currentPage = 0;
      }
      // No need for an `else if (initialize)` block to clear the feed,
      // as the clearing is now handled at the beginning of the method.
    } catch (e, s) {
      // Also check for staleness in the catch block
      if (_isDisposed || searchId != _currentSearchId) {
        _logger.info(
          'Error for stale search ID $searchId, ignoring. Current ID is $_currentSearchId.',
        );
        return;
      }
      _logger.severe('Error refreshing feed $e $s');
      _error = e.toString();
      state = AsyncData(state.value!.copyWith(error: _error));
    } finally {
      // Only update loading state if this was the last operation.
      if (searchId == _currentSearchId) {
        _isLoading = false;
        if (state.value != null) {
          state = AsyncData(state.value!.copyWith(isLoading: false));
        }
      } else {
        // If this is a stale operation, we don't change the loading state
        // as a newer operation is in control.
        _logger.info(
          'Stale refresh (ID $searchId) finished, not changing loading state as current ID is $_currentSearchId.',
        );
      }
    }
  }

  Future<void> fetchMoreItems() async {
    debugPrint(
        'SearchStreamNotifier: fetchMoreItems called for feedKey: ${_currentSettings.feedKey}');
    if (_isLoading) {
      _logger.info('Already fetching more items, skipping.');
      return;
    }
    if (!_hasMoreItems) {
      _logger.info('No more items to fetch.');
      return;
    }

    final nextPage = currentPage + 1;
    try {
      _isLoading = true;
      // Visually indicate that we are loading more items.
      state = AsyncData(state.value!.copyWith(isLoading: true));

      final TetherClientReturn<TModel> result = await _fetch(
        rangeStart: nextPage * _currentSettings.pageSize,
        rangeEnd: (nextPage + 1) * _currentSettings.pageSize - 1,
      );

      if (result.error != null) {
        debugPrint(
            'SearchStreamNotifier: Error fetching more items for feedKey: ${_currentSettings.feedKey}, Error: ${result.error}');
      }

      debugPrint(
          'SearchStreamNotifier: Fetched ${result.data.length} more items for feedKey: ${_currentSettings.feedKey}, is Disposed: $_isDisposed');

      if (_isDisposed) return;

      final newItems = result.data;
      _totalRemoteCount = result.count;

      if (newItems.isNotEmpty) {
        // The missing step: add the new items to the end of the feed references.
        final feedManager = ref.read(feedItemReferenceManagerProvider);
        final newReferences = newItems
            .map((item) => FeedItemReference(
                  itemSourceTable:
                      _currentSettings.clientManager.localTableName,
                  itemSourceId: item.localId.toString(),
                  displayOrder: 0, // This is ignored by addItemsToEnd
                ))
            .toList();

        await feedManager.addItemsToEnd(
          feedKey: _currentSettings.feedKey,
          itemsToAdd: newReferences,
        );
        currentPage = nextPage;
      }
      // The stream will now automatically pick up the changes.
    } catch (e, s) {
      _logger.severe('Error fetching more items $e, $s');
      if (!_isDisposed) {
        state = AsyncData(state.value!.copyWith(error: e.toString()));
      }
    } finally {
      _isLoading = false;
      // Ensure the final state reflects that loading is complete.
      if (!_isDisposed && state.value?.isLoading == true) {
        state = AsyncData(state.value!.copyWith(isLoading: false));
      }
    }
  }

  Future<TetherClientReturn<TModel>> _fetch({
    int rangeStart = 0,
    int rangeEnd = 20,
  }) async {
    // FTS Hybrid Query Logic
    // MODIFICATION: Changed `terms.isNotEmpty` to `_currentSettings.searchRpcName != null`
    // This ensures that if an RPC is specified, we ALWAYS use it, even for empty search terms.
    // The backend RPC is responsible for handling the empty string case.
    if (_currentSettings.searchRpcName != null) {
      if (_currentSettings.primaryKeyColumn == null) {
        final errorMsg =
            "SearchStreamNotifier: primaryKeyColumn must be set when using searchRpcName for feedKey '${_currentSettings.feedKey}'.";
        _logger.severe(errorMsg);
        throw Exception(errorMsg);
      }
      final pageSize = rangeEnd - rangeStart + 1;
      final offset = rangeStart;

      // Step 1: Call the RPC to get ranked IDs, rank, and total count.
      final rpcResponse = await _currentSettings.clientManager.client
          .rpc(_currentSettings.searchRpcName!, params: {
        'search_query': terms,
        'result_limit': pageSize,
        'result_offset': offset,
      });

      _logger.info('${_currentSettings.feedKey} RPC Response: $rpcResponse');

      final List<dynamic> rpcData = rpcResponse as List<dynamic>;

      _logger.info('${_currentSettings.feedKey} RPC Data: $rpcData');

      if (rpcData.isEmpty) {
        return TetherClientReturn(data: [], count: 0);
      }

      // Extract IDs for the next query and ranks for sorting.
      final idToRankMap = {for (var e in rpcData) e['id']: e['rank'] as num};
      final ids = rpcData.map((e) => e['id']).toList();

      // The total count should be returned by the RPC on each item.
      final totalCount = (rpcData.first['total_count'] as int?) ?? 0;

      // Step 2: Fetch the full data for these IDs using a standard query.
      // Apply the query customizer first.
      var query = _currentSettings.clientManager.query
          .select(_currentSettings.selectArgs);
      if (_currentSettings.queryCustomizer != null) {
        query = _currentSettings.queryCustomizer!(query, ref);
      }

      // Then, apply the filter for the IDs returned by the RPC.
      query = query.inFilter(_currentSettings.primaryKeyColumn!, ids);
      final dataResponse = await query;

      // THIS IS THE FIX:
      // The `await query` returns before the background database writes are
      // guaranteed to be complete. We need to wait for the write queue to
      // finish before we can be sure the data is in the local DB.
      final appDatabase = ref.read(databaseProvider);
      await (appDatabase.db as SqliteDatabase).get('SELECT 1');
      ;

      debugPrint(
          '${_currentSettings.feedKey} Data response: ${dataResponse.count} items');

      // Step 3: Re-sort the fetched data according to the rank from the RPC.
      final sortedData = dataResponse.data
        ..sort((a, b) {
          final rankA = idToRankMap[a.localId] ?? 0;
          final rankB = idToRankMap[b.localId] ?? 0;
          // Higher rank is better, so sort descending.
          return rankB.compareTo(rankA);
        });

      return TetherClientReturn(data: sortedData, count: totalCount);
    } else {
      // Existing Logic for non-FTS queries or empty search terms
      final effectiveQuery = _getEffectiveQueryBuilder();
      final result =
          await effectiveQuery.range(rangeStart, rangeEnd).remoteOnly();

      // APPLY THE SAME FIX HERE for non-RPC fetches
      final appDatabase = ref.read(databaseProvider);
      await (appDatabase.db as SqliteDatabase).get('SELECT 1');
      ;

      return result;
    }
  }

  void search(String newTerms, {List<String>? excludeIds}) {
    if (_isDisposed) return;
    _logger.info('Searching for: $newTerms');

    // If the new search term is the same as the current one, do nothing.
    if (terms == newTerms && listEquals(_excludedIds, excludeIds)) {
      _logger.info('Search terms are the same, skipping.');
      return;
    }

    // Invalidate the previous search operation by incrementing the ID.
    // Any ongoing refreshFeed will now be ignored when it completes.
    _currentSearchId++;

    // Reset pagination and update terms
    currentPage = 0;
    terms = newTerms;
    _excludedIds = excludeIds; // Store the excluded IDs

    // If the search term is empty, we should still refresh to clear results
    // and show the base unfiltered feed.
    if (newTerms.isEmpty) {
      _logger.info(
          'Search term is empty, refreshing feed to show unfiltered results.');
      refreshFeed(initialize: true);
      return;
    }

    // If a search RPC name is provided, use it for a remote search.
    if (_currentSettings.searchRpcName != null) {
      _logger.info('Using search RPC: ${_currentSettings.searchRpcName}');
      refreshFeed(initialize: true);
      return;
    }

    // Fallback to column-based search if no RPC is specified.
    if (_currentSettings.searchColumn != null) {
      _logger.info(
          'Using column-based search on: ${_currentSettings.searchColumn}');
      // Apply a dynamic filter for the local search.
      applyDynamicFilters((query) {
        // Use 'ilike' for case-insensitive partial matching.
        return query.ilike(_currentSettings.searchColumn!, '%$newTerms%');
      });
    } else {
      _logger.info('No search column or RPC specified, cannot perform search.');
    }
  }

  /// Sets a list of IDs to exclude from the feed results.
  Future<void> setExcludedIds(List<String>? newIds) async {
    _logger.info(
      "Setting excluded IDs for feedKey '${_currentSettings.feedKey}'.",
    );
    _excludedIds = newIds;
    currentPage = 0;
    _totalRemoteCount = null; // Reset count when filters change
    _error = null; // Clear any previous errors
    await refreshFeed(initialize: true);
  }

  /// Applies a new set of dynamic filters to the feed.
  /// The [filterApplicator] function takes the current base query (after static customizers)
  /// and should return a new query with the dynamic filters applied.
  Future<void> applyDynamicFilters(
    ClientManagerFilterBuilder<TModel> Function(
      ClientManagerFilterBuilder<TModel> baseQueryWithoutDynamicFilters,
    ) filterApplicator,
  ) async {
    _logger.info(
      "Applying dynamic filters for feedKey '${_currentSettings.feedKey}'.",
    );
    _dynamicFilterApplicator = filterApplicator;
    currentPage = 0;
    _totalRemoteCount = null; // Reset count when filters change
    _error = null; // Clear any previous errors
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
      _error = null; // Clear any previous errors
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
      "Applying ordering for feedKey '${_currentSettings.feedKey}': ${column.dartName} ${ascending ? 'ASC' : 'DESC'}, nullsFirst: ${nullsFirst}",
    );
    _orderColumn = column;
    _orderAscending = ascending;
    _orderNullsFirst = nullsFirst;
    currentPage = 0;
    _totalRemoteCount = null; // Reset count when ordering changes
    _error = null; // Clear any previous errors
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
    _error = null; // Clear any previous errors
    await refreshFeed(initialize: true);
  }

  /// Reorders the items in the feed locally based on a new list of item IDs.
  /// This is intended to be called after a successful remote reordering operation.
  Future<void> reorderFeed(List<String> orderedItemIds) async {
    if (_isDisposed) return;
    _logger.info(
      "Reordering feed locally for feedKey '${_currentSettings.feedKey}'.",
    );

    try {
      final feedManager = ref.read(feedItemReferenceManagerProvider);
      await feedManager.reorderFeedItems(
        feedKey: _currentSettings.feedKey,
        orderedSourceIds: orderedItemIds,
      );
      // The stream watching 'feed_item_references' will automatically pick up
      // the changes and rebuild the UI with the new order.
    } catch (e, s) {
      _logger.severe(
        "Error during local reorder for feedKey '${_currentSettings.feedKey}': $e, $s",
      );
      // Optionally, handle the error in the UI
      _error = 'Failed to update local order: $e';
      state = AsyncData(state.value!.copyWith(error: _error));
    }
  }

  /// Getter to expose the current total count for UI components
  int? get totalRemoteCount => _totalRemoteCount;

  /// Getter to expose whether more items are available for UI components
  bool get hasMoreItems => _hasMoreItems;

  /// Getter to expose the current loading state
  bool get isLoading => _isLoading;

  /// Getter to expose the current error state
  String? get error => _error;
}



""");
    buffer.writeln('');

    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(buffer.toString());
      _logger.info('Generated feed provider: $filePath');
    } catch (e) {
      _logger.severe('Error writing feed provider file $filePath: $e');
    }
  }
}
