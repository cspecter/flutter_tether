import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_tether/config/config_model.dart';
import 'package:tether_libs/utils/logger.dart'; // Assuming Logger exists

class FeedManagerGenerator {
  final SupabaseGenConfig config;
  final Logger _logger;

  FeedManagerGenerator({required this.config, Logger? logger})
    : _logger = logger ?? Logger('FeedManagerGenerator');

  Future<void> generate() async {
    if (!config.generateClientManagers) {
      _logger.info(
        'FeedItemReferenceManager generation is disabled (linked to generateClientManagers flag). Skipping.',
      );
      return;
    }

    final managersDir = p.join(config.outputDirectory, 'managers');
    final fileName = 'feed_item_reference_manager.g.dart';
    final filePath = p.join(managersDir, fileName);

    final className = 'FeedItemReferenceManager';
    final providerName = 'feedItemReferenceManagerProvider';

    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln('// ignore_for_file: constant_identifier_names');
    buffer.writeln('');
    buffer.writeln("import 'package:sqlite_async/sqlite_async.dart';");
    if (config.useRiverpod) {
      buffer.writeln(
        "import 'package:flutter_riverpod/flutter_riverpod.dart';",
      );
      buffer.writeln("import '../database.dart';");
    }
    buffer.writeln('');

    buffer.writeln(r"""

/// Represents an item reference stored in a feed.
class FeedItemReference {
  final String itemSourceTable;
  final String itemSourceId;
  final int displayOrder;

  FeedItemReference({
    required this.itemSourceTable,
    required this.itemSourceId,
    required this.displayOrder,
  });

  factory FeedItemReference.fromMap(Map<String, dynamic> map) {
    return FeedItemReference(
      itemSourceTable: map['item_source_table'] as String,
      itemSourceId: map['item_source_id'] as String,
      displayOrder: map['display_order'] as int,
    );
  }
}

class FeedItemReferenceManager {
  final SqliteDatabase db;
  static const String _tableName = 'feed_item_references';

  FeedItemReferenceManager(this.db);

  /// Clears all items for the given [feedKey] and inserts/updates the new [items]
  /// ensuring their display_order is set according to their position in the list.
  Future<void> setFeedItems({
    required String feedKey,
    required List<FeedItemReference> items,
  }) async {
    await db.writeTransaction((tx) async {
      // It's often still useful to clear items not present in the new list.
      // If items can only be added/reordered but not removed by this operation,
      // you might reconsider this delete. For a full "set", this delete is common.
      await tx.execute('DELETE FROM $_tableName WHERE feed_key = ?', [feedKey]);
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        // UPSERT: Insert the item or update its display_order if it already exists
        // (though with the preceding DELETE, it will always be an INSERT here unless
        // items list has duplicates for the same item_source_id/table for this feedKey).
        await tx.execute(
          '''INSERT INTO $_tableName (feed_key, item_source_table, item_source_id, display_order)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(feed_key, item_source_table, item_source_id) DO UPDATE SET
            display_order = excluded.display_order''',
          [feedKey, item.itemSourceTable, item.itemSourceId, i],
        );
      }
    });
    await db.get('SELECT 1');
  }

  /// Adds a list of items to the start of the specified feed.
  /// All items in the feed (new and existing) will be renumbered sequentially starting from 0.
  /// The `displayOrder` property of the [newItemsToAdd] is ignored.
  Future<void> addItemsToStart({
    required String feedKey,
    required List<FeedItemReference> newItemsToAdd,
  }) async {
    if (newItemsToAdd.isEmpty) {
      return;
    }

    await db.writeTransaction((tx) async {
      // 1. Get current items' identifiers, ordered by their current display_order.
      // We only need itemSourceTable and itemSourceId to identify them.
      final existingItemsRaw = await tx.execute(
        'SELECT item_source_table, item_source_id FROM $_tableName WHERE feed_key = ? ORDER BY display_order ASC',
        [feedKey],
      );
      final List<FeedItemReference> existingItems = existingItemsRaw
          .map(
            (row) => FeedItemReference(
              itemSourceTable: row['item_source_table'] as String,
              itemSourceId: row['item_source_id'] as String,
              displayOrder:
                  0, // This displayOrder is a placeholder, it will be reassigned.
            ),
          )
          .toList();

      // 2. Create the new combined list.
      // New items come first. Existing items are added if not already included from newItemsToAdd
      // (this handles moving an existing item to the start).
      final List<FeedItemReference> combinedList = [];
      final Set<String> addedItemUniqueKeys =
          {}; // To track "table:id" to prevent duplicates

      for (final item in newItemsToAdd) {
        final uniqueKey = "${item.itemSourceTable}:${item.itemSourceId}";
        // We add all newItemsToAdd, their position at the start is guaranteed.
        // If a new item is a duplicate of another new item, both will be added here,
        // and the last one's position will be based on its order in newItemsToAdd.
        // The final INSERT loop will assign display_order based on this combinedList.
        combinedList.add(
          FeedItemReference(
            itemSourceTable: item.itemSourceTable,
            itemSourceId: item.itemSourceId,
            displayOrder: 0,
          ),
        ); // Placeholder displayOrder
        addedItemUniqueKeys.add(uniqueKey);
      }

      for (final item in existingItems) {
        final uniqueKey = "${item.itemSourceTable}:${item.itemSourceId}";
        if (!addedItemUniqueKeys.contains(uniqueKey)) {
          combinedList.add(
            FeedItemReference(
              itemSourceTable: item.itemSourceTable,
              itemSourceId: item.itemSourceId,
              displayOrder: 0,
            ),
          ); // Placeholder displayOrder
        }
      }

      // 3. Clear all existing items for this feedKey (within the transaction).
      await tx.execute('DELETE FROM $_tableName WHERE feed_key = ?', [feedKey]);

      // 4. Insert all items from the combined list with new, sequential display_order.
      // Since we've deleted all items for this feedKey and combinedList ensures uniqueness
      // of (itemSourceTable, itemSourceId) by how it's constructed, a simple INSERT is sufficient.
      // If combinedList could have internal duplicates, an UPSERT would be needed here.
      for (int i = 0; i < combinedList.length; i++) {
        final itemToInsert = combinedList[i];
        await tx.execute(
          '''INSERT INTO $_tableName (feed_key, item_source_table, item_source_id, display_order)
             VALUES (?, ?, ?, ?)''',
          [
            feedKey,
            itemToInsert.itemSourceTable,
            itemToInsert.itemSourceId,
            i, // New sequential display_order
          ],
        );
      }
    });
  }

  /// Adds a single item to the end of the specified feed.
  /// If the item already exists in the feed, its display_order will be updated to move it to the end.
  Future<void> addItemToEnd({
    required String feedKey,
    required String itemSourceTable,
    required String itemSourceId,
  }) async {
    await db.writeTransaction((tx) async {
      final maxOrderResult = await tx.execute(
        'SELECT MAX(display_order) as max_order FROM $_tableName WHERE feed_key = ?',
        [feedKey],
      );
      final maxOrder = (maxOrderResult.isNotEmpty
              ? maxOrderResult.first['max_order'] as int?
              : null) ??
          -1;
      // UPSERT: Insert the item or update its display_order if it already exists.
      await tx.execute(
        '''INSERT INTO $_tableName (feed_key, item_source_table, item_source_id, display_order)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(feed_key, item_source_table, item_source_id) DO UPDATE SET
          display_order = excluded.display_order''',
        [feedKey, itemSourceTable, itemSourceId, maxOrder + 1],
      );
    });
  }

  /// Adds a list of items to the end of the specified feed.
  /// If an item already exists, its position is updated to the end.
  /// This is more efficient than the previous implementation for pagination.
  Future<void> addItemsToEnd({
    required String feedKey,
    required List<FeedItemReference> itemsToAdd,
  }) async {
    if (itemsToAdd.isEmpty) {
      return;
    }

    await db.writeTransaction((tx) async {
      // 1. Get the current max display order for the feed.
      final maxOrderResult = await tx.execute(
        'SELECT MAX(display_order) as max_order FROM $_tableName WHERE feed_key = ?',
        [feedKey],
      );
      int maxOrder = (maxOrderResult.isNotEmpty
              ? maxOrderResult.first['max_order'] as int?
              : null) ??
          -1;

      // 2. Prepare a single UPSERT statement for all new items.
      final columns = [
        'feed_key',
        'item_source_table',
        'item_source_id',
        'display_order'
      ];
      final valuePlaceholderGroup = '(?, ?, ?, ?)';
      final allPlaceholders =
          List.filled(itemsToAdd.length, valuePlaceholderGroup).join(', ');
      final allArguments = <Object?>[];

      for (final item in itemsToAdd) {
        maxOrder++; // Increment order for each new item
        allArguments.addAll([
          feedKey,
          item.itemSourceTable,
          item.itemSourceId,
          maxOrder,
        ]);
      }

      final sql = '''
        INSERT INTO $_tableName (${columns.join(', ')})
        VALUES $allPlaceholders
        ON CONFLICT(feed_key, item_source_table, item_source_id) DO UPDATE SET
          display_order = excluded.display_order
      ''';

      await tx.execute(sql, allArguments);
    });
  }

  /// Removes a specific item from the feed. Note: This does NOT automatically re-compact display_order values.
  Future<void> removeItem({
    required String feedKey,
    required String itemSourceTable,
    required String itemSourceId,
  }) async {
    await db.execute(
      'DELETE FROM $_tableName WHERE feed_key = ? AND item_source_table = ? AND item_source_id = ?',
      [feedKey, itemSourceTable, itemSourceId],
    );
  }

  /// Removes an item by its source ID from all feeds.
  /// This is useful when an item is permanently deleted and must be removed
  /// from all feed references.
  Future<void> removeItemFromAllFeeds({
    required String itemSourceId,
  }) async {
    await db.execute(
      'DELETE FROM $_tableName WHERE item_source_id = ?',
      [itemSourceId],
    );
  }

  /// Removes all items from the specified feed.
  Future<void> clearFeed({required String feedKey}) async {
    await db.execute('DELETE FROM $_tableName WHERE feed_key = ?', [feedKey]);
  }

  /// Gets the total count of items for a given feed.
  Future<int> getCount({required String feedKey}) async {
    final result = await db.execute(
      'SELECT COUNT(*) as count FROM $_tableName WHERE feed_key = ?',
      [feedKey],
    );
    if (result.isNotEmpty) {
      return result.first['count'] as int? ?? 0;
    }
    return 0;
  }

  /// Retrieves all item references for a given feed, ordered by their display_order.
  Future<List<FeedItemReference>> getFeedItemReferences({
    required String feedKey,
  }) async {
    final results = await db.execute(
      'SELECT item_source_table, item_source_id, display_order FROM $_tableName WHERE feed_key = ? ORDER BY display_order ASC',
      [feedKey],
    );
    return results.map((map) => FeedItemReference.fromMap(map)).toList();
  }

  /// Reorders the items in a feed according to the provided list of source IDs.
  /// This method updates the display_order of each item to match its index in the
  /// provided [orderedSourceIds] list.
  Future<void> reorderFeedItems({
    required String feedKey,
    required List<String> orderedSourceIds,
  }) async {
    await db.writeTransaction((tx) async {
      for (int i = 0; i < orderedSourceIds.length; i++) {
        final id = orderedSourceIds[i];
        await tx.execute(
          'UPDATE feed_item_references SET display_order = ? WHERE feed_key = ? AND item_source_id = ?',
          [i, feedKey, id],
        );
      }
    });
  }
}

final feedItemReferenceManagerProvider = Provider<FeedItemReferenceManager>((
  ref,
) {
  final database = ref.watch(databaseProvider);
  return FeedItemReferenceManager(database.db);
});



""");

    buffer.writeln('');

    if (config.useRiverpod) {
      buffer.writeln(
        'final $providerName = Provider<$className>((',
      ); // Adjusted for multiline
      buffer.writeln('  ref,'); // Added ref for multiline
      buffer.writeln(') {');
      buffer.writeln(
        '  final database = ref.watch(databaseProvider);',
      );
      buffer.writeln('  return $className(database.db);');
      buffer.writeln('});');
    }

    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(buffer.toString());
      _logger.info('Generated feed item reference manager: $filePath');
    } catch (e) {
      _logger.severe(
        'Error writing feed item reference manager file $filePath: $e',
      );
    }
  }
}
