import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:stepbattle/services/supabase_api_client.dart';
import 'package:stepbattle/utils/app_logger.dart';

/// The whole Phase-1/2 data layer now depends on [SupabaseApiClient.run].
/// These tests pin its retry semantics so a future refactor can't
/// silently break the invariants the repositories rely on:
///
///   1. First-try success returns immediately (no retry cost paid).
///   2. Transient errors retry, then eventually succeed within budget.
///   3. Non-retryable errors (Auth, terminal Postgrest) short-circuit
///      and do NOT retry.
///   4. Timeout retries respect the retry-off toggle for mutations.
///   5. Retry budget is bounded — a permanently broken call throws
///      after the last attempt, not forever.
void main() {
  group('SupabaseApiClient.run', () {
    // Every test uses distinct fields so parallel log entries can be
    // distinguished — otherwise the ring buffer is shared across tests.
    setUp(AppLogger.clearBuffer);

    test('returns immediately on first-try success', () async {
      var calls = 0;
      final result = await SupabaseApiClient.instance.run<String>(
        () async {
          calls++;
          return 'ok';
        },
        category: LogCategory.auth,
        name: 'test.firstTry',
      );
      expect(result, 'ok');
      expect(calls, 1);
    });

    test('retries transient error then succeeds', () async {
      var calls = 0;
      final result = await SupabaseApiClient.instance.run<String>(
        () async {
          calls++;
          if (calls < 3) {
            // A 5xx-class code is treated as transient by the client.
            throw PostgrestException(
              message: 'gateway timeout',
              code: '504',
            );
          }
          return 'ok';
        },
        category: LogCategory.friend,
        name: 'test.transientThenSucceed',
      );
      expect(result, 'ok');
      expect(calls, 3);
    });

    test('AuthException does NOT retry', () async {
      var calls = 0;
      await expectLater(
        SupabaseApiClient.instance.run<String>(
          () async {
            calls++;
            throw AuthException('session expired');
          },
          category: LogCategory.auth,
          name: 'test.authNoRetry',
        ),
        throwsA(isA<AuthException>()),
      );
      expect(calls, 1);
    });

    test('Terminal Postgrest error (RLS denial 42501) does NOT retry',
        () async {
      var calls = 0;
      await expectLater(
        SupabaseApiClient.instance.run<String>(
          () async {
            calls++;
            throw PostgrestException(
              message: 'rls denied',
              code: '42501',
            );
          },
          category: LogCategory.battle,
          name: 'test.rlsNoRetry',
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(calls, 1);
    });

    test('retry: false bypasses retry loop entirely for transient error',
        () async {
      var calls = 0;
      await expectLater(
        SupabaseApiClient.instance.run<String>(
          () async {
            calls++;
            throw PostgrestException(
              message: 'gateway timeout',
              code: '504',
            );
          },
          category: LogCategory.mission,
          name: 'test.retryOffTransient',
          retry: false,
        ),
        throwsA(isA<PostgrestException>()),
      );
      expect(calls, 1);
    });

    test('exhausted retries eventually throw (do not loop forever)',
        () async {
      var calls = 0;
      await expectLater(
        SupabaseApiClient.instance.run<String>(
          () async {
            calls++;
            throw PostgrestException(
              message: 'always broken',
              code: '503',
            );
          },
          category: LogCategory.leaderboard,
          name: 'test.exhausted',
        ),
        throwsA(isA<PostgrestException>()),
      );
      // Retry ladder is 3 delays → 4 total attempts.
      expect(calls, 4);
    });

    test('timeout with retry: false surfaces TimeoutException on first try',
        () async {
      var calls = 0;
      await expectLater(
        SupabaseApiClient.instance.run<String>(
          () async {
            calls++;
            // Never completes — the timeout wrapper fires.
            await Future.delayed(const Duration(seconds: 30));
            return 'unreachable';
          },
          category: LogCategory.track,
          name: 'test.timeoutNoRetry',
          timeout: const Duration(milliseconds: 30),
          retry: false,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls, 1);
    });

    test('log line records ms and attempt count on success', () async {
      await SupabaseApiClient.instance.run<int>(
        () async => 42,
        category: LogCategory.xp,
        name: 'test.metricEmit',
        fields: {'note': 'metrics'},
      );
      final entry = AppLogger.recent(category: LogCategory.xp).single;
      expect(entry.event, 'test.metricEmit:ok');
      expect(entry.fields!.containsKey('ms'), isTrue);
      // On a first-try success there's no `attempt` field (only added
      // when attempt > 0 to keep the happy-path log compact).
      expect(entry.fields!.containsKey('attempt'), isFalse);
      expect(entry.fields!['note'], 'metrics');
    });
  });
}
