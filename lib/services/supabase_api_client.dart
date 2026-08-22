import 'dart:async';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';

/// Signature for the request passed to [SupabaseApiClient.run] — a
/// zero-arg callable that produces the actual Supabase future to run
/// (and, if it fails transiently, to re-run).
typedef SupabaseCall<T> = Future<T> Function();

/// Thin call-site wrapper over Supabase RPC/CRUD calls.
///
/// Wraps a single request with retry-with-backoff on transient failures,
/// tags every call with a [LogCategory] so latency + failure lines flow
/// into the per-domain log files, and — since [AppLogger] error-level
/// entries fan out to Sentry via the observability hook — every failed
/// request also lands in Sentry with the op name in scope.
///
/// This is a *helper*, not a required abstraction. Existing code that
/// calls `supabase.from(...)` directly keeps working; new code (starting
/// with the repository layer) opts in when it wants retry + timing.
///
/// Typical use:
/// ```dart
/// final row = await SupabaseApiClient.instance.run(
///   () => supabase.from('profiles').select().eq('id', uid).maybeSingle(),
///   category: LogCategory.auth,
///   name: 'profiles.getById',
///   fields: {'uid': uid},
/// );
/// ```
class SupabaseApiClient {
  SupabaseApiClient._();
  static final SupabaseApiClient instance = SupabaseApiClient._();

  /// Requests that don't complete within this window are aborted and
  /// (if retryable) retried. Wide enough that a cold Supabase edge-cache
  /// miss doesn't false-fire, tight enough that we don't hang the UI
  /// on a network stall.
  static const Duration defaultTimeout = Duration(seconds: 12);

  /// Retry ladder for transient errors — network drop, 5xx, timeout.
  /// Auth and RLS failures short-circuit and re-throw immediately.
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 300),
    Duration(milliseconds: 900),
    Duration(milliseconds: 2400),
  ];

  /// Run a Supabase request with retry + timing + logging.
  ///
  /// - [op] is the operation to run.
  /// - [category] routes log lines into the per-domain file.
  /// - [name] is a stable identifier like `profiles.getById` used in log
  ///   events and Sentry breadcrumb names.
  /// - [fields] optional extra context (user id, filter key). Values
  ///   pass through [AppLogger]'s PII redactor.
  /// - [timeout] overrides [defaultTimeout] for slow operations
  ///   (bulk upserts, RPCs that fan out).
  /// - [retry] set to `false` for mutations that MUST NOT run twice.
  ///
  /// ## Retry safety warning
  ///
  /// `Future.timeout` cancels only the *Dart* future — the underlying
  /// HTTP request keeps flying. If the server has already committed
  /// the write when the client aborts, the retry will send a duplicate.
  ///
  /// - Reads are safe with the default `retry: true` — a duplicate
  ///   SELECT is a wasted round-trip, nothing more.
  /// - Writes MUST pass `retry: false` unless they are truly idempotent
  ///   (composite-PK upserts against a stable payload are OK; INSERTs,
  ///   append-style mutations, and XP grants are not).
  /// - Storage uploads with `upsert: false` are especially unsafe —
  ///   a retry after a partially-succeeded upload will 409, and the
  ///   generic catch here does retry non-terminal errors, so you get
  ///   a runaway loop. Use `retry: false` OR ensure the caller passes
  ///   `upsert: true` for the retry to be idempotent.
  Future<T> run<T>(
    SupabaseCall<T> op, {
    required LogCategory category,
    required String name,
    Map<String, dynamic>? fields,
    Duration? timeout,
    bool retry = true,
  }) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    final logger = AppLogger.forCategory(category);
    final stopwatch = Stopwatch()..start();
    final maxAttempts = retry ? _retryDelays.length + 1 : 1;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final result = await op().timeout(effectiveTimeout);
        stopwatch.stop();
        logger.d('$name:ok', fields: {
          ...?fields,
          'ms': stopwatch.elapsedMilliseconds,
          if (attempt > 0) 'attempt': attempt + 1,
        });
        return result;
      } on AuthException catch (e, s) {
        // Session expired, wrong key, JWT invalid — retrying makes it
        // worse (rate-limits, lockouts). Bail immediately.
        stopwatch.stop();
        logger.e('$name:auth',
            fields: {
              ...?fields,
              'ms': stopwatch.elapsedMilliseconds,
              'code': e.statusCode,
            },
            error: e,
            stack: s);
        rethrow;
      } on PostgrestException catch (e, s) {
        // Postgrest surfaces both retryable (5xx, timeout) and terminal
        // (RLS denial, constraint violation) as the same type. Discriminate
        // via SQLSTATE-like `code`: retry server classes, bail client ones.
        final isTransient = _isTransientPostgrestCode(e.code);
        if (!isTransient || attempt == maxAttempts - 1) {
          stopwatch.stop();
          logger.e('$name:pgError',
              fields: {
                ...?fields,
                'ms': stopwatch.elapsedMilliseconds,
                'code': e.code,
                'hint': e.hint,
                'transient': isTransient,
              },
              error: e,
              stack: s);
          rethrow;
        }
      } on TimeoutException catch (e, s) {
        if (attempt == maxAttempts - 1) {
          stopwatch.stop();
          logger.e('$name:timeout',
              fields: {
                ...?fields,
                'ms': stopwatch.elapsedMilliseconds,
                'attempt': attempt + 1,
              },
              error: e,
              stack: s);
          rethrow;
        }
      } catch (e, s) {
        // SocketException / dart:io network errors surface here.
        if (attempt == maxAttempts - 1) {
          stopwatch.stop();
          logger.e('$name:failed',
              fields: {
                ...?fields,
                'ms': stopwatch.elapsedMilliseconds,
                'attempt': attempt + 1,
              },
              error: e,
              stack: s);
          rethrow;
        }
      }

      // Backoff. Log so flapping ops are visible.
      final delay = _retryDelays[math.min(attempt, _retryDelays.length - 1)];
      logger.w('$name:retry', fields: {
        ...?fields,
        'attempt': attempt + 1,
        'delayMs': delay.inMilliseconds,
      });
      await Future.delayed(delay);
    }

    // Unreachable — the loop always returns or rethrows on the last attempt.
    throw StateError('SupabaseApiClient.run: retries exhausted for $name');
  }

  bool _isTransientPostgrestCode(String? code) {
    if (code == null) return true;
    if (code.startsWith('5')) return true;
    if (code == '08000' || code == '08003' || code == '08006') return true;
    if (code == '40001' || code == '40P01') return true;
    return false;
  }
}
