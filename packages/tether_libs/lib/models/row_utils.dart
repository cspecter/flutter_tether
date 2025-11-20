import 'package:sqlite_async/sqlite3.dart';

/// Creates a `Row` instance from a standard `Map<String, dynamic>`.
///
/// This is useful for creating mock data or converting nested JSON objects
/// into a `Row` that model factories can consume.
Row createRowFromMap(Map<String, dynamic> map) {
  // 1. Extract keys and values. The order must be consistent.
  final columnNames = map.keys.toList();
  final values = map.values.toList();

  // 2. Create a ResultSet to act as the Cursor.
  // The `rows` parameter for ResultSet expects a list of lists (the rows).
  final mockResultSet = ResultSet(
    columnNames,
    null, // tableNames are not needed for this conversion
    [values], // A list containing our single row of values
  );

  // 3. The ResultSet is a list of Rows. The Row we want is the first one.
  return mockResultSet[0];
}