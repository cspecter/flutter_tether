import 'package:sqlite_async/sqlite3_common.dart';
import 'package:tether_libs/models/tether_model_input.dart';

/// An abstract base class for all data models managed by the Tether system.
///
/// `TetherModel` provides a common interface for models that can be serialized
/// to and from JSON (for network communication, e.g., with Supabase) and
/// an SQLite-compatible format (for local database persistence).
///
/// Subclasses must implement:
/// - `toJson()`: To serialize the model to a JSON map.
/// - `toSqlite()`: To serialize the model to a map suitable for SQLite insertion/update.
///   This might involve converting complex types (like `DateTime` or enums) to
///   SQLite-compatible types (like ISO8601 strings or integers).
/// - `copyWith(...)`: A method to create a new instance of the model with some
///   fields updated. The actual parameters for `copyWith` should be specific to the
///   subclass and its properties.
/// - A `static fromJson(Map<String, dynamic> json)` factory constructor (or equivalent)
///   for deserializing from JSON.
/// - A `static fromSqlite(Row sqliteData)` factory constructor (or equivalent)
///   for deserializing from an SQLite `Row`.
///
/// The generic type `T` should be the type of the implementing class itself, enabling
/// type-safe `copyWith` and factory methods.
///
/// Example (conceptual subclass):
/// ```dart
/// class MyData extends TetherModel<MyData> {
///   final int id;
///   final String name;
///   final DateTime createdAt;
///
///   MyData({required this.id, required this.name, required this.createdAt})
///       : super({'id': id, 'name': name, 'created_at': createdAt.toIso8601String()});
///
///   MyData.fromData(Map<String, dynamic> data)
///       : id = data['id'] as int,
///         name = data['name'] as String,
///         createdAt = DateTime.parse(data['created_at'] as String),
///         super(data);
///
///   @override
///   dynamic get localId => id;
///
///   @override
///   Map<String, dynamic> toJson() => {
///         'id': id,
///         'name': name,
///         'created_at': createdAt.toIso8601String(),
///       };
///
///   @override
///   Map<String, dynamic> toSqlite() => {
///         'id': id,
///         'name': name,
///         'created_at': createdAt.toIso8601String(), // SQLite stores as TEXT
///       };
///
///   @override
///   MyData copyWith({int? id, String? name, DateTime? createdAt}) =>
///       MyData(
///         id: id ?? this.id,
///         name: name ?? this.name,
///         createdAt: createdAt ?? this.createdAt,
///       );
///
///   static MyData fromJson(Map<String, dynamic> json) => MyData(
///         id: json['id'] as int,
///         name: json['name'] as String,
///         createdAt: DateTime.parse(json['created_at'] as String),
///       );
///
///   static MyData fromSqlite(Row row) => MyData(
///         id: row['id'] as int,
///         name: row['name'] as String,
///         createdAt: DateTime.parse(row['created_at'] as String),
///       );
///
///   @override
///   String toString() => 'MyData(id: $id, name: $name, createdAt: $createdAt)';
/// }
/// ```
/// 
/// [T] is the concrete model type (e.g., BookModel)
/// [I] is the corresponding input type (e.g., BookInput)
abstract class TetherModel<T> {
  /// The underlying data map holding the model's properties.
  /// Subclasses should initialize this in their constructors.
  final Map<String, dynamic> data;

  /// Constructs a [TetherModel] with the given `data` map.
  TetherModel(this.data);

  /// Provides access to the local identifier of the model instance.
  /// This typically corresponds to the primary key in the local SQLite database
  /// (e.g., 'id').
  /// Subclasses should override this if their primary key column is named differently.
  dynamic get localId => data['id'];

  /// Serializes the model instance to a JSON-compatible [Map].
  ///
  /// This map is typically used for sending data to a remote server (e.g., Supabase).
  /// It should represent the model in the format expected by the backend.
  Map<String, dynamic> toJson();

  /// Serializes the model instance to a [Map] suitable for insertion or update
  /// into an SQLite database.
  ///
  /// This method should handle any necessary type conversions, such as:
  /// - `DateTime` to ISO8601 `String` or Unix timestamp `int`.
  /// - `bool` to `int` (0 or 1).
  /// - Enums to `String` or `int`.
  /// - Custom objects to a storable format (e.g., JSON string).
  Map<String, dynamic> toSqlite();

  /// Creates a corresponding input object for this model.
  ///
  /// The returned input object can be used for insert, update, and upsert operations
  /// with all fields pre-filled with the values from this model.
  ///
  /// Subclasses must implement this method to return their specific input type.
  /// 
  /// Example:
  /// ```dart
  /// @override
  /// BookInput toInput() {
  ///   return BookInput(
  ///     id: id,
  ///     title: title,
  ///     // other fields...
  ///   );
  /// }
  /// ```
  TetherModelInput toInput();

  /// Creates a new instance of the model [T] with updated properties.
  ///
  /// Subclasses must implement this method, providing specific named, optional
  /// parameters for each field that can be copied/updated.
  ///
  /// Example for a `User` model:
  /// ```dart
  /// User copyWith({String? name, int? age}) {
  ///   return User(
  ///     name: name ?? this.name,
  ///     age: age ?? this.age,
  ///     // other fields...
  ///   );
  /// }
  /// ```
  T copyWith(/* Specific named, optional parameters defined in subclass */);

  /// Provides a string representation of the model instance.
  /// It is recommended that subclasses override this to provide a meaningful output.
  @override
  String toString();

  /// A generic factory constructor to create a `TetherModel` instance from a JSON map.
  ///
  /// **Note:** This default factory returns a `_GenericTetherModel` which provides
  /// basic pass-through serialization. For type-safe deserialization into specific
  /// model types (e.g., `User`, `Product`), each subclass **must** provide its own
  /// `static YourModelType fromJson(Map<String, dynamic> json)` factory.
  /// This generic factory is primarily a placeholder or for internal use where
  /// the specific type `T` is not critical at the point of creation but is expected
  /// to be cast or handled by a more specific mechanism later.
  ///
  /// It is **strongly recommended** to use the specific `fromJson` factories
  /// in your application code: `YourModel.fromJson(json)`.
  factory TetherModel.fromJson(Map<String, dynamic> json) {
    // This acts as a fallback or a way to handle dynamic model creation
    // if the concrete type isn't known at compile time for the factory call.
    // However, direct use of subclass-specific fromJson is preferred.
    return _GenericTetherModel(json) as TetherModel<T>;
  }

  /// A generic factory constructor to create a `TetherModel` instance from an SQLite `Row`.
  ///
  /// **Note:** Similar to `TetherModel.fromJson`, this default factory returns a
  /// `_GenericTetherModel`. For type-safe deserialization from SQLite into specific
  /// model types, each subclass **must** provide its own
  /// `static YourModelType fromSqlite(Row sqliteData)` factory.
  ///
  /// It is **strongly recommended** to use the specific `fromSqlite` factories
  /// in your application code: `YourModel.fromSqlite(row)`.
  factory TetherModel.fromSqlite(Row sqliteData) {
    // The Row object from sqlite_async is already a Map<String, dynamic> like structure.
    // However, to be explicit and ensure we have a standard Map, we can create one from it.
    // If Row itself can be directly used as Map<String, dynamic> in all contexts,
    // this conversion might be simplified, but creating a new map is safer.
    final Map<String, dynamic> mapData = Map<String, dynamic>.from(sqliteData);
    return _GenericTetherModel(mapData) as TetherModel<T>;
  }
}

/// A generic, non-abstract implementation of [TetherModel].
///
/// This class provides basic implementations for `toJson`, `toSqlite`, and `copyWith`.
/// It is used by the default factory constructors in `TetherModel` and can serve
/// as a simple model if no specific subclass behavior (beyond data storage and
/// pass-through serialization) is needed.
///
/// However, for most use cases, you should create specific subclasses of `TetherModel`
/// with strongly-typed fields and tailored `fromJson`/`fromSqlite` factories.
class _GenericTetherModel extends TetherModel<dynamic> {
  /// Creates a `_GenericTetherModel` with the provided `data` map.
  _GenericTetherModel(super.data);

  // No specific localId override, uses TetherModel.data['id'] by default.

  /// Returns a shallow copy of the internal `data` map.
  @override
  Map<String, dynamic> toJson() {
    return Map<String, dynamic>.from(data);
  }

  /// Returns a shallow copy of the internal `data` map.
  /// Assumes data is already in an SQLite-compatible format.
  /// For complex types, subclasses should override `toSqlite` for proper conversion.
  @override
  Map<String, dynamic> toSqlite() {
    return Map<String, dynamic>.from(data);
  }
  
  /// Creates a generic input from this model's data.
  @override
  TetherModelInput toInput() {
    return _GenericTetherModelInput(data);
  }

  /// Creates a new `_GenericTetherModel` by merging the current `data` with `newData`.
  ///
  /// If `newData` is provided, its key-value pairs will overwrite those in the current `data`.
  @override
  _GenericTetherModel copyWith({Map<String, dynamic>? newData}) {
    return _GenericTetherModel({...data, ...?newData});
  }

  @override
  String toString() {
    return '_GenericTetherModel($data)';
  }
}

/// Generic implementation of TetherModelInput for the GenericTetherModel
class _GenericTetherModelInput implements TetherModelInput<_GenericTetherModelInput, _GenericTetherModel> {
  final Map<String, dynamic> data;
  
  _GenericTetherModelInput(this.data);
  
  @override
  _GenericTetherModelInput copyWith() {
    return _GenericTetherModelInput(Map<String, dynamic>.from(data));
  }
  
  @override
  Map<String, dynamic> toJson() {
    return Map<String, dynamic>.from(data);
  }
  
  @override
  Map<String, dynamic> toSqliteMap() {
    return Map<String, dynamic>.from(data);
  }
  
  @override
  String toString() {
    return '_GenericTetherModelInput($data)';
  }
}
