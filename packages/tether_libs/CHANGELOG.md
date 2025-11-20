## 1.0.0

- Initial release of the Tether Libraries.

## 1.0.5

- Changed how the query and realtime are accessed in the CLient Manager.

## 1.0.6

- Modified the Auth signin and signout methods to more closely mirror Supabase.

## 1.1.0

- Changed the Client Manager to use the new `TetherClientReturn` class for all
  results.

## 1.1.2
- Add `TetherModelInput` class to handle input and update operations

## 1.1.3
- Fixed the `delete` method on the `ClientManager` to accept either String or int

## 1.1.4
- Updated the `TetherModelInput` class to include validation logic for required fields.

## 1.1.85
- Updated BackgroundJobManager to include passing a mesage to the front end.

## 1.2.2
- Added support for GeoJSON serialization and deserialization.

## 1.3.1
- Introduced `createRowFromMap` utility function to simplify Row creation from Maps.

## 1.3.2
- Fixed the `fromSqlite` method in the model generator to correctly handle "IS NOT" and "IS" conditions for boolean values.

## 1.3.3
- Fixed optimistic updating in the `ClientManager` to ensure it correctly updates the local database after a successful remote operation.

## 1.3.4
- Fixed optimistic updating in the `ClientManager` to ensure it correctly updates the local database after a successful remote operation.

## 1.3.5
- Added a `RETURNING` clause to the `mutation` methods in the `ClientManager` to return the newly inserted or updated row.

## 1.3.6
- Added `select` to mutations in the `ClientManager` to allow for returning the modified row after an insert or update operation.

## 1.3.9
- When generating the SQL for Sqlite, it now correctly adds the alias for the table if it is provided in the `fromAlias` parameter.

## 1.3.10
- When generating the SQL for Sqlite, it now correctly adds the alias for the table if it is provided in the `fromAlias` parameter.

## 1.4.0
- Rewrote hos the SQLStatement is built in the `ClientManager` to use a more structured approach so it handles table aliases and schemas correctly.

## 1.4.1
- Fixed the `SupabaseSelectBuilderGenerator` to correctly generate and pass down the SQL statement

## 1.4.2
- Fixed error where empty rows were passed to the `fromSqlite` method, causing issues with related objects and lists.

## 1.4.4
- For 'jsobjects' in the `fromSqlite` method, it now uses the `createRowFromMap` utility function to ensure correct serialization of related objects and lists.

## 1.4.5
- Parsed the `jsobjects` field in the `fromSqlite` method to ensure it correctly handles JSON strings and deserializes them into the appropriate model instances.

## 1.4.6
- Made Select Builders, Models, and Inputs Equatable to improve comparison and testing capabilities.

## 1.4.7
- Now `fullyQualified` returns the fully qualified name of the column, including the table alias if provided.

## 1.4.8
- Changed the `fullyQualified` method to accept an optional prefix parameter, allowing for more flexible column name generation in queries.

## 1.4.9
- Fixed the `fullyQualified` method to correctly handle cases where the column is from a related table, ensuring the alias is applied correctly.

## 1.4.10
- Updated the `ClientManager` to handle related tables more gracefully, ensuring that aliases are applied correctly when building SQL statements.

## 1.4.11
- Updated how alias is applied in the `ClientManager` to ensure that related tables are handled correctly, especially when building SQL statements with conditions on related columns.

## 1.4.12
- Created a `deleteJobsByPriority` method in the `BackgroundServiceManager` to allow for selective deletion of jobs based on their priority level.

## 1.4.13
- Add the ability to search by joined tables in the `ClientManager` by allowing conditions on related tables via an `!inner` parameter in the `where` method.

## 1.4.14
- Fixed the inner join condition in the `ClientManagerFilterBuilder` to correctly reference the related table's original name and column names, ensuring that the SQL generated is valid and works as expected.

## 1.4.15
- Reverting some changes as it's not possible to use `!inner` in the `where` method for related tables in the current implementation. Instead, we will use a separate `select` method to handle related table queries.

## 1.4.17
- Fixed a bug where the PostgrestTransformBuilder was not correctly handling the `Prefer: count=exact` header, leading to incorrect row counts being returned in some cases.

## 1.4.18
- Added a baseSupabase property to the ClientManager to correct for the query rerunning and having Prefer: count=exact header added multiple times.

## 1.4.19
- Added a `foreignTable` parameter to the `orderBy` method in the `ClientManagerTransformBuilder` to allow for ordering by columns in related tables.

## 1.4.20
- Modified the orderBy method in the ClientManagerTransformBuilder to use the foreignTable parameter instead of referencedTable for clarity and consistency with Supabase terminology.

## 1.4.22
- Changed the RPC methods in the ClientManager to better conform to Supabase's conventions and best practices.

## 1.4.23
- Improved error handling in the ClientManager to provide more informative messages when queries fail.

## 1.4.24
- Fixed bug where `jsobjects` were not being correctly deserialized in the ClientManager, leading to potential data loss or corruption.

## 1.4.25
- Refactored the RealtimeManager to allow chaining of filter and order configurations.

## 1.4.26
- Fixed issue where many-to-many relationships were not being correctly handled in the ClientManager, ensuring proper serialization and deserialization of related models.

## 1.4.27
- Fixed the delete rollback in the ClientManager to correctly handle errors and maintain data consistency.

## 1.4.28
- Added `awaitSync` method to the ClientManagerBase to explicitly trigger query execution and ensure synchronization with the local database.

## 1.4.29
- Reverted changes related to the `awaitSync` method in the ClientManagerBase to address synchronization issues.

## 1.4.30
- Make sure local db is awaited properly in ClientManagerBase methods to prevent race conditions.

## 1.4.31
- Updated `asStream` method in ClientManagerBase to improve error handling and logging.

## 1.4.34
- Updated the `ClientManager` so that upserts and updates handle dynamic indexes properly.

## 1.4.36
- Fixed `GeoJson` serialization to correctly handle null values.

## 1.4.37
- Improved `ClientManager` to better upserts of a lot of data into the local database.

## 1.5.0
- Refactor upsert logic in ClientManager to improve performance and reliability when handling large datasets.

## 1.5.3
- Updated various `buildUpsertSql` calls to `buildUpsertSqlForModels` to ensure proper handling of model serialization and table schemas.