import 'dart:async';
import 'package:flutter/foundation.dart'; // For ValueNotifier
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqlite_async/sqlite_async.dart'; // For SqliteConnection
import 'package:tether_libs/models/table_info.dart';
import 'package:tether_libs/models/tether_model.dart';
import 'package:tether_libs/client_manager/manager/client_manager_models.dart';
import 'package:tether_libs/utils/logger.dart';

/// A typedef for a factory function that creates an instance of [TModel] from a JSON map.
///
/// This is typically used for deserializing data fetched from a remote source (like Supabase)
/// or a local database into a specific [TetherModel] type.
///
/// Example:
/// ```dart
/// class MyModel extends TetherModel<MyModel> {
///   // ... model properties and methods
///
///   static MyModel fromJson(Map<String, dynamic> json) {
///     return MyModel(id: json['id'], name: json['name']);
///   }
///
///   // ... other methods
/// }
///
/// // Usage with AuthManager or other services:
/// final authManager = AuthManager<MyModel>(
///   // ... other parameters
///   profileFromJsonFactory: MyModel.fromJson,
/// );
/// ```
typedef FromJsonFactory<T extends TetherModel<T>> =
    T Function(Map<String, dynamic> json);

/// Manages user authentication and profile data synchronization with Supabase and a local SQLite database.
///
/// The `AuthManager` handles:
/// - User sign-up, sign-in (password, OTP), and sign-out.
/// - Listening to Supabase authentication state changes.
/// - Fetching the user's profile from a specified Supabase table upon successful authentication.
/// - Storing and updating the user's profile in a local SQLite table.
/// - Clearing local profile data on sign-out or authentication errors.
/// - Providing [ValueNotifier]s for the current [User] and the user's profile ([TProfileModel])
///   to enable reactive UI updates.
///
/// It requires a [SupabaseClient] for interacting with Supabase, a [SqliteConnection]
/// for local database operations, and details about the profile table (both in Supabase
/// and locally), along with a `fromJson` factory for the profile model.
///
/// Example:
/// ```dart
/// // Assuming MyProfileModel.fromJson exists and MyProfileModel extends TetherModel<MyProfileModel>
/// final authManager = AuthManager<MyProfileModel>(
///   supabaseClient: supabaseInstance,
///   localDb: localSqliteConnection,
///   supabaseProfileTableName: 'profiles', // Name of your Supabase profiles table
///   localProfileTableName: 'user_profile', // Name of your local SQLite profile table
///   profileFromJsonFactory: MyProfileModel.fromJson,
///   tableSchemas: myAppTableSchemas, // Map<String, SupabaseTableInfo>
/// );
///
/// // Listen to user changes
/// authManager.currentUserNotifier.addListener(() {
///   print('Current Supabase User: \${authManager.currentUserNotifier.value}');
/// });
///
/// // Listen to profile changes
/// authManager.currentProfileNotifier.addListener(() {
///   print('Current User Profile: \${authManager.currentProfileNotifier.value}');
/// });
///
/// // Sign in
/// try {
///   await authManager.signInWithPassword(email: 'user@example.com', password: 'password');
/// } catch (e) {
///   print('Sign-in error: $e');
/// }
///
/// // Sign out
/// await authManager.signOut();
/// ```
class AuthManager<TProfileModel extends TetherModel<TProfileModel>> {
  final SupabaseClient _supabaseClient;
  final SqliteConnection _localDb;
  final String _supabaseProfileTableName;
  final String _localProfileTableName;
  final FromJsonFactory<TProfileModel> _profileFromJsonFactory;
  final Map<String, SupabaseTableInfo> _tableSchemas;
  late StreamSubscription<AuthState> _authSubscription;

  /// Notifies listeners about changes to the current Supabase [User].
  ///
  /// Emits `null` if no user is signed in.
  final ValueNotifier<User?> currentUserNotifier = ValueNotifier(null);

  /// Notifies listeners about changes to the current user's profile ([TProfileModel]).
  ///
  /// Emits `null` if no profile is loaded (e.g., user signed out, profile not found, or error).
  final ValueNotifier<TProfileModel?> currentProfileNotifier = ValueNotifier(
    null,
  );

  final Logger _logger = Logger('AuthManager');

  /// Creates an instance of [AuthManager].
  ///
  /// Parameters:
  /// - `supabaseClient`: The [SupabaseClient] instance for backend communication.
  /// - `localDb`: The [SqliteConnection] for local data persistence.
  /// - `supabaseProfileTableName`: The name of the table in Supabase that stores user profiles.
  /// - `localProfileTableName`: The name of the table in the local SQLite database to store the user profile.
  /// - `profileFromJsonFactory`: A function that can convert a JSON map into an instance of [TProfileModel].
  /// - `tableSchemas`: A map containing schema information for tables, used to correctly
  ///   interact with the local database, particularly for upserting the profile. The key should
  ///   be in the format 'schema.table_name' (e.g., 'public.profiles').
  AuthManager({
    required SupabaseClient supabaseClient,
    required SqliteConnection localDb,
    required String supabaseProfileTableName,
    required String localProfileTableName,
    required FromJsonFactory<TProfileModel> profileFromJsonFactory,
    required Map<String, SupabaseTableInfo> tableSchemas,
  }) : _supabaseClient = supabaseClient,
       _localDb = localDb,
       _supabaseProfileTableName = supabaseProfileTableName,
       _localProfileTableName = localProfileTableName,
       _profileFromJsonFactory = profileFromJsonFactory,
       _tableSchemas = tableSchemas {
    _authSubscription = _supabaseClient.auth.onAuthStateChange.listen(
      _onAuthStateChanged,
    );
    // Initialize with current state
    final currentSession = _supabaseClient.auth.currentSession;
    final initialAuthState =
        currentSession == null
            ? AuthState(AuthChangeEvent.signedOut, null)
            : AuthState(AuthChangeEvent.signedIn, currentSession);
    _onAuthStateChanged(initialAuthState);
  }

  /// Gets the current authenticated Supabase [User].
  ///
  /// Returns `null` if no user is signed in.
  User? get currentUser => _supabaseClient.auth.currentUser;

  /// Gets the current Supabase [Session].
  ///
  /// Returns `null` if no user is signed in or the session is invalid.
  Session? get currentSession => _supabaseClient.auth.currentSession;

  /// A stream of [AuthState] changes from the Supabase client.
  ///
  /// This can be used to react to authentication events like sign-in, sign-out,
  /// token refresh, etc., in more detail if needed.
  Stream<AuthState> get onAuthStateChange =>
      _supabaseClient.auth.onAuthStateChange;

  /// Signs up a new user with email and password.
  ///
  /// Optionally, `data` can be provided to store additional user metadata.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   final response = await authManager.signUp(
  ///     email: 'newuser@example.com',
  ///     password: 'securepassword123',
  ///     data: {'username': 'newbie'},
  ///   );
  ///   if (response.user != null) {
  ///     print('Sign-up successful for user: \${response.user!.id}');
  ///   } else {
  ///     print('Sign-up successful, but user object is null. Check email verification settings.');
  ///   }
  /// } on AuthException catch (e) {
  ///   print('Sign-up error: \${e.message}');
  /// }
  /// ```
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) {
    return _supabaseClient.auth.signUp(
      email: email,
      password: password,
      data: data,
    );
  }

  /// Signs in an existing user with email and password.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   final response = await authManager.signInWithPassword(
  ///     email: 'user@example.com',
  ///     password: 'password123',
  ///   );
  ///   if (response.user != null) {
  ///     print('Sign-in successful for user: \${response.user!.id}');
  ///     // AuthManager will automatically fetch and store the profile.
  ///   }
  /// } on AuthException catch (e) {
  ///   print('Sign-in error: \${e.message}');
  /// }
  /// ```
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) {
    return _supabaseClient.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  Future<void> signInWithPhone({
    String? email,
    String? phone,
    String? emailRedirectTo,
    bool? shouldCreateUser,
    Map<String, dynamic>? data,
    String? captchaToken,
    OtpChannel channel = OtpChannel.sms,
  }) {
    return _supabaseClient.auth.signInWithOtp(
      email: email,
      phone: phone,
      emailRedirectTo: emailRedirectTo,
      shouldCreateUser: shouldCreateUser,
      data: data,
      captchaToken: captchaToken,
      channel: channel,
    );
  }

  /// Signs in a user using a one-time password (OTP) received via email or other methods.
  ///
  /// Example (after user receives OTP):
  /// ```dart
  /// try {
  ///   // First, you might have requested an OTP, e.g., via _supabaseClient.auth.signInWithOtp
  ///   // For this example, assume OTP was sent and received by the user.
  ///   final response = await authManager.signInWithOtp(
  ///     email: 'user@example.com',
  ///     token: '123456', // The OTP token entered by the user
  ///   );
  ///   if (response.user != null) {
  ///     print('OTP Sign-in successful for user: \${response.user!.id}');
  ///   }
  /// } on AuthException catch (e) {
  ///   print('OTP Sign-in error: \${e.message}');
  /// }
  /// ```
  Future<AuthResponse> verifyOtp({
    String? email,
    String? phone,
    String? token,
    required OtpType type,
    String? redirectTo,
    String? captchaToken,
    String? tokenHash,
  }) {
    // Note: Supabase uses verifyOTP for this flow after an initial signInWithOtp call
    // that sends the token. This method assumes the token has been sent and is being verified.
    return _supabaseClient.auth.verifyOTP(
      email: email,
      phone: phone,
      token: token,
      type: type,
      redirectTo: redirectTo,
      captchaToken: captchaToken,
      tokenHash: tokenHash,
    );
  }

  /// Resends an OTP to the user's email for a specified [OtpType].
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await authManager.resendOtp(email: 'user@example.com', type: OtpType.signup);
  ///   print('OTP resent successfully.');
  /// } on AuthException catch (e) {
  ///   print('Error resending OTP: \${e.message}');
  /// }
  /// ```
  Future<void> resendOtp({required String email, required OtpType type}) {
    return _supabaseClient.auth.resend(type: type, email: email);
  }

  /// Signs out the current user.
  ///
  /// This will trigger an [AuthStateChangeEvent.signedOut] event, leading to
  /// the clearing of local profile data.
  ///
  /// Example:
  /// ```dart
  /// await authManager.signOut();
  /// print('User signed out.');
  /// // currentUserNotifier.value will be null
  /// // currentProfileNotifier.value will be null
  /// ```
  Future<void> signOut() async {
    await _supabaseClient.auth.signOut();
    // The listener _onAuthStateChanged will handle clearing local data.
  }

  /// Internal handler for Supabase authentication state changes.
  ///
  /// Updates [currentUserNotifier] and triggers profile fetching/clearing
  /// based on the authentication event.
  Future<void> _onAuthStateChanged(AuthState authState) async {
    final session = authState.session;
    final user = session?.user;
    currentUserNotifier.value = user;

    _logger.info('Auth state changed: \${authState.event}, User: \${user?.id}');

    if (authState.event == AuthChangeEvent.signedIn ||
        authState.event == AuthChangeEvent.tokenRefreshed ||
        authState.event == AuthChangeEvent.userUpdated) {
      if (user != null) {
        await _fetchAndStoreProfile(user.id);
      } else {
        _logger.warning(
          'Auth event \${authState.event} received but user is null. Clearing local profile.',
        );
        await _clearLocalProfileData();
      }
    } else if (authState.event == AuthChangeEvent.signedOut) {
      await _clearLocalProfileData();
    }
  }

  /// Fetches the user's profile from Supabase and stores it locally.
  ///
  /// If the profile is not found or an error occurs, local profile data is cleared.
  Future<void> _fetchAndStoreProfile(String userId) async {
    _logger.info('Fetching profile for user: $userId');
    try {
      final response =
          await _supabaseClient
              .from(_supabaseProfileTableName)
              .select()
              .eq(
                'id', // Assuming the profile table's primary key column is named 'id'
                // and it matches the Supabase auth user's ID.
                userId,
              )
              .maybeSingle();

      if (response != null) {
        final profileModel = _profileFromJsonFactory(response);
        await _upsertProfileToLocalDb(profileModel);
        currentProfileNotifier.value = profileModel;
        _logger.info(
          'Profile for user $userId fetched and stored successfully.',
        );
      } else {
        _logger.warning(
          'Profile not found for user $userId in table \'$_supabaseProfileTableName\'. Clearing local profile.',
        );
        await _clearLocalProfileData(); // Clear if profile doesn't exist
      }
    } catch (e, s) {
      _logger.severe(
        'Error fetching/storing profile for user $userId: $e\\n$s',
      );
      await _clearLocalProfileData(); // Clear local data on error
    }
  }

  /// Upserts (inserts or updates) the user's profile into the local SQLite database.
  ///
  /// It first deletes any existing profile to ensure only one is present.
  Future<void> _upsertProfileToLocalDb(TProfileModel profileModel) async {
    // Construct the key for tableSchemas, typically 'public.tableName'
    final profileTableSchemaKey = 'public.$_supabaseProfileTableName';
    final profileTableInfo = _tableSchemas[profileTableSchemaKey];

    if (profileTableInfo == null) {
      _logger.severe(
        "Configuration error: Table info for '$_supabaseProfileTableName' (key: '$profileTableSchemaKey') not found in provided tableSchemas. Cannot upsert profile.",
      );
      return;
    }

    try {
      // Clear existing profile data first to ensure only one profile is stored locally.
      // This simplifies logic by always inserting, effectively an upsert for a single-row table.
      await _localDb.execute('DELETE FROM $_localProfileTableName');
      _logger.info(
        'Cleared existing data from local profile table: $_localProfileTableName',
      );

      // Use ClientManagerSqlUtils.buildInsertSql for consistency,
      // even though it's a single record. It expects a list.

      final insertStatement = ClientManagerSqlUtils.buildInsertSqlFromModel(
        [profileModel],
        _localProfileTableName, // Use the designated local table name
      );
      final finalSql = insertStatement.build();
      await _localDb.execute(finalSql.sql, finalSql.arguments);
      _logger.info(
        'Profile successfully upserted to local DB table: $_localProfileTableName.',
      );
    } catch (e, s) {
      _logger.severe(
        'Error upserting profile to local DB table $_localProfileTableName: $e\\n$s',
      );
    }
  }

  /// Clears all data from the local profile table and resets [currentProfileNotifier].
  Future<void> _clearLocalProfileData() async {
    _logger.info(
      'Clearing local profile data from table: $_localProfileTableName',
    );
    try {
      await _localDb.execute('DELETE FROM $_localProfileTableName');
      currentProfileNotifier.value = null;
      _logger.info(
        'Local profile data successfully cleared from table $_localProfileTableName.',
      );
    } catch (e, s) {
      _logger.severe(
        'Error clearing local profile data from table $_localProfileTableName: $e\\n$s',
      );
    }
  }

  /// Disposes of the [AuthManager] and its resources.
  ///
  /// This should be called when the [AuthManager] is no longer needed to prevent
  /// memory leaks, for example, in a Riverpod provider's `onDispose` callback.
  /// It cancels the auth state subscription and disposes the [ValueNotifier]s.
  void dispose() {
    _logger.info('Disposing AuthManager.');
    _authSubscription.cancel();
    currentUserNotifier.dispose();
    currentProfileNotifier.dispose();
  }
}
