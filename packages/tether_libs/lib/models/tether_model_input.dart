/// Base class for all input classes used for insert, update, and upsert operations.
/// 
/// [T] is the concrete input class type (e.g., BookInput)
/// [M] is the corresponding model class type (e.g., BookModel)
abstract class TetherModelInput<T extends TetherModelInput<T, M>, M> {
  /// Creates a copy of this input with modified fields.
  ///
  /// Implementing classes should override this method to provide proper field copying.
  T copyWith();
  
  /// Converts this input to a JSON map for Supabase API.
  /// 
  /// Only includes non-null fields in the output map.
  /// Keys should be the original database column names (snake_case).
  Map<String, dynamic> toJson();
  
  /// Converts this input to a map suitable for SQLite operations.
  /// 
  /// Only includes non-null fields in the output map.
  /// Performs appropriate type conversions for SQLite (e.g., bool to int).
  Map<String, dynamic> toSqliteMap();
  
  /// Creates an input instance from a model instance.
  /// 
  /// Implementing classes should provide a factory constructor:
  /// ```
  /// factory YourInput.fromModel(YourModel model) {
  ///   return YourInput(
  ///     field1: model.field1,
  ///     field2: model.field2,
  ///   );
  /// }
  /// ```
}