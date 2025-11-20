## 1.0.0

- Initial release of the Tether package.

## 1.0.5

- Changed the User Preferences generator to support number arrays.

## 1.0.7

- Modified the Auth generator to support the new `auth` table structure.

## 1.1.0

- Fixed generation of M2M helper getter in Models
- Added support for `TetherClientReturn` in the Feed Manager

## 1.1.1

- Fixed the generation of M2M getters in Models to correctly handle multiple
  relationships.

## 1.1.3
- Added `TetherModelInput` class to handle input and update operations.

## 1.1.4
- Added an order clause into the `FeedProvider`

## 1.1.6
- Added support for `FeedStreamState` in the Feed Provider.

## 1.1.7
- Added support for `FeedStreamState` in the Feed Manager.

## 1.1.8
- Fixed an error where it was not correctly parsing `json` and `jsonb` array types.

## 1.1.85
- Updated BackgroundJobManager to include passing a message to the front end.

## 1.2.0
- Changed the database provider to be a standard Provider with initialization. The intention is for the user to initialize it so it's ready in the main.dart.

## 1.2.5
- Fix an error with transforming geometry data

## 1.2.9
- Fixed the `copyWith` method generation to ensure it correctly returns the new instance of the model class.

## 1.3.0
- Fixed a breaking issue with the `fromSQLite` method for translating boolean values.
- Added error handling in the `SearchStreamNotifier` to log errors during initial fetch and refresh

## 1.3.5
- Fixed the `fromSqlite` method in the model generator to correctly handle related objects and lists.

## 1.3.6
- Fixed the `fromSqlite` method to serialize related objects and lists correctly using the `createRowFromMap` utility function.

## 1.4.0
- `SupabaseSelectBuilderGenerator` now correctly generates and passes down the SQL statement to the `ClientManager` for execution.

## 1.4.1
- Fixed the `SupabaseSelectBuilderGenerator` to correctly generate and pass down the SQL statement

## 1.4.3
- Made Models, Inputs, and Select Builders Equatable

## 1.4.4
- Updated the Select Builders to conform to the new `qualified` name convention.

## 1.4.5
- Updated Select Builders to use the `fullyQualified` method for column names, ensuring correct handling of table aliases and schemas.

## 1.4.10
- Updated the Feed Provider and Feed Manager to support ordering and filtering enhancements.

## 1.4.34
- Improved performance of the Feed Manager by optimizing database queries.
- Added support for pagination in the Feed Provider.

## 1.5.0
- Updated to work with Riverpod 3.0.3