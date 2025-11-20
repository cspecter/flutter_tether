import 'dart:convert';
import 'package:sqlite_async/sqlite3_common.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:tether_libs/background_service/background_job_model.dart';

/// Manages interactions with the `background_service_jobs` table.
///
/// This class provides methods to query, update, and delete background jobs.
/// It requires an [SqliteConnection] to perform database operations.
class BackgroundJobManager {
  final SqliteConnection db;

  /// Creates a new instance of [BackgroundJobManager].
  ///
  /// Requires an active [SqliteConnection].
  BackgroundJobManager({required this.db});

  /// Fetches a single job by its ID.
  ///
  /// Returns the [BackgroundJob] if found, otherwise `null`.
  Future<BackgroundJob?> getJobById(int id) async {
    final List<Map<String, Object?>> result = await db.getAll(
      "SELECT * FROM background_service_jobs WHERE id = ? LIMIT 1",
      [id],
    );
    if (result.isNotEmpty) {
      return BackgroundJob.fromMap(result.first);
    }
    return null;
  }

  /// Fetches jobs by their status.
  ///
  /// - [status]: The [BackgroundJobStatus] to filter by.
  /// - [limit]: Optional limit on the number of jobs to return.
  /// - [offset]: Optional offset for pagination.
  /// - [orderByCreation]: Optional sort order by `created_at` ('ASC' or 'DESC').
  Future<List<BackgroundJob>> getJobsByStatus(
    BackgroundJobStatus status, {
    int? limit,
    int? offset,
    String orderByCreation = 'ASC', // ASC for older first, DESC for newer first
  }) async {
    String query =
        "SELECT * FROM background_service_jobs WHERE status = ? ORDER BY created_at $orderByCreation";
    final params = <Object?>[status.name.toUpperCase()];

    if (limit != null) {
      query += " LIMIT ?";
      params.add(limit);
      if (offset != null) {
        query += " OFFSET ?";
        params.add(offset);
      }
    }

    final List<Map<String, Object?>> results = await db.getAll(query, params);
    return results.map((map) => BackgroundJob.fromMap(map)).toList();
  }

  /// Fetches jobs by their `jobKey`.
  ///
  /// - [jobKey]: The specific job key to filter by.
  /// - [status]: Optional [BackgroundJobStatus] to further filter by.
  /// - [limit]: Optional limit on the number of jobs to return.
  /// - [offset]: Optional offset for pagination.
  Future<List<BackgroundJob>> getJobsByJobKey(
    String jobKey, {
    BackgroundJobStatus? status,
    int? limit,
    int? offset,
  }) async {
    String query = "SELECT * FROM background_service_jobs WHERE job_key = ?";
    final params = <Object?>[jobKey];

    if (status != null) {
      query += " AND status = ?";
      params.add(status.name.toUpperCase());
    }
    query += " ORDER BY created_at DESC"; // Default to newest first

    if (limit != null) {
      query += " LIMIT ?";
      params.add(limit);
      if (offset != null) {
        query += " OFFSET ?";
        params.add(offset);
      }
    }
    final List<Map<String, Object?>> results = await db.getAll(query, params);
    return results.map((map) => BackgroundJob.fromMap(map)).toList();
  }

  /// Fetches all jobs, with optional pagination.
  Future<List<BackgroundJob>> getAllJobs({int? limit, int? offset}) async {
    String query =
        "SELECT * FROM background_service_jobs ORDER BY created_at DESC";
    final params = <Object?>[];
    if (limit != null) {
      query += " LIMIT ?";
      params.add(limit);
      if (offset != null) {
        query += " OFFSET ?";
        params.add(offset);
      }
    }
    final List<Map<String, Object?>> results = await db.getAll(query, params);
    return results.map((map) => BackgroundJob.fromMap(map)).toList();
  }

  /// Watches all jobs in the database, emitting a new list whenever the
  /// `background_service_jobs` table changes.
  ///
  /// Jobs are sorted by creation date, with the newest jobs first.
  Stream<List<BackgroundJob>> watchAllJobs() {
    final stream = db.watch(
      "SELECT * FROM background_service_jobs ORDER BY created_at DESC",
    );
    return stream.map(
      (results) => results.map((map) => BackgroundJob.fromMap(map)).toList(),
    );
  }

  /// Updates the status of a specific job.
  ///
  /// - [id]: The ID of the job to update.
  /// - [newStatus]: The new [BackgroundJobStatus].
  /// - [lastError]: Optional error message if the status is [BackgroundJobStatus.failed].
  /// Returns the number of rows affected (should be 1 if successful).
  Future<int> updateJobStatus(
    int id,
    BackgroundJobStatus newStatus, {
    String? lastError,
  }) async {
    final ResultSet result = await db.execute(
      "UPDATE background_service_jobs SET status = ?, last_error = ?, last_attempt_at = STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW') WHERE id = ?",
      [newStatus.name.toUpperCase(), lastError, id],
    );
    return result.length;
  }

  /// Updates the status and message for all jobs with a specific jobKey.
  ///
  /// - [jobKey]: The key of the jobs to update.
  /// - [newStatus]: The new [BackgroundJobStatus].
  /// - [message]: The new message for the jobs.
  /// Returns the number of rows affected.
  Future<int> updateJobStatusByJobKey(
    String jobKey,
    BackgroundJobStatus newStatus, {
    required String message,
  }) async {
    final ResultSet result = await db.execute(
      "UPDATE background_service_jobs SET status = ?, message = ? WHERE job_key = ?",
      [newStatus.name.toUpperCase(), message, jobKey],
    );
    return result.length;
  }

  /// Resets a job to 'PENDING' status for a retry attempt.
  ///
  /// This typically clears the `last_error` and updates `last_attempt_at`.
  /// It does not automatically increment `attempts`; the job processing logic handles that.
  ///
  /// - [id]: The ID of the job to reset.
  /// Returns the number of rows affected.
  Future<int> resetJobForRetry(int id) async {
    final job = await getJobById(id);
    if (job == null) return 0;

    // if (job.attempts >= job.maxAttempts) { // Logic for max attempts is handled by the service
    // }

    final ResultSet result = await db.execute(
      "UPDATE background_service_jobs SET status = 'PENDING', last_error = NULL, last_attempt_at = STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW') WHERE id = ?",
      [id],
    );
    return result.length;
  }

  /// Deletes a specific job by its ID.
  ///
  /// Returns the number of rows affected.
  Future<int> deleteJob(int id) async {
    final ResultSet result = await db.execute(
      "DELETE FROM background_service_jobs WHERE id = ?",
      [id],
    );
    return result.length;
  }

  /// Deletes jobs by their status, optionally older than a specific date.
  ///
  /// - [status]: The [BackgroundJobStatus] of jobs to delete (e.g., 'COMPLETED' or 'FAILED').
  /// - [olderThan]: If provided, only jobs created before this [DateTime] will be deleted.
  /// Returns the number of rows affected.
  Future<int> deleteJobsByStatus(
    BackgroundJobStatus status, {
    DateTime? olderThan,
  }) async {
    String query = "DELETE FROM background_service_jobs WHERE status = ?";
    final params = <Object?>[status.name.toUpperCase()];

    if (olderThan != null) {
      query += " AND created_at < ?";
      params.add(olderThan.toIso8601String());
    }

    final ResultSet result = await db.execute(query, params);
    return result.length;
  }
  
  Future<int> deleteJobsByPriority(int priority, {
    DateTime? olderThan,
  }) async {
    String query = "DELETE FROM background_service_jobs WHERE priority <= ?";
    final params = <Object?>[priority];

    if (olderThan != null) {
      query += " AND created_at < ?";
      params.add(olderThan.toIso8601String());
    }

    final ResultSet result = await db.execute(query, params);
    return result.length;
  }

  /// Gets the count of jobs with a specific status.
  Future<int> getJobCountByStatus(BackgroundJobStatus status) async {
    final result = await db.get(
      "SELECT COUNT(*) as count FROM background_service_jobs WHERE status = ?",
      [status.name.toUpperCase()],
    );
    return (result['count'] as int?) ?? 0;
  }

  /// Enqueues a new job.
  ///
  /// This mirrors the logic in `GenericBackgroundService.enqueueJob` but is part
  /// of this manager for completeness if direct management is needed.
  /// It's generally recommended to use `GenericBackgroundService.enqueueJob`
  /// as it also signals the running service.
  ///
  /// - [jobKey]: Identifier for the function/task.
  /// - [payload]: Optional data for the job (will be JSON encoded).
  /// - [priority]: Job priority (0 = normal).
  /// - [maxAttempts]: Maximum number of retries.
  /// Returns the ID of the newly inserted job row if successful, otherwise `null`.
  Future<void> enqueueJob({
    required String jobKey,
    Map<String, dynamic>? payload,
    int priority = 1,
    int maxAttempts = 3,
  }) async {
    try {
      final String? encodedPayload =
          payload != null ? jsonEncode(payload) : null;
      await db.execute(
        '''
        INSERT INTO background_service_jobs (job_key, payload, priority, max_attempts, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'PENDING', STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW'), STRFTIME('%Y-%m-%dT%H:%M:%fZ', 'NOW'))
        ''',
        [jobKey, encodedPayload, priority, maxAttempts],
      );
      return;
    } catch (e) {
      // Consider logging the error
      // print('BackgroundJobManager: Error enqueuing job "$jobKey": $e');
      return;
    }
  }
}
