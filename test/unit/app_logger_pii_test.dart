import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/utils/app_logger.dart';

/// PII redaction is enforced inside [AppLogger._write], so we assert
/// against the ring buffer's [LogEntry.formatted] output — that's exactly
/// what will be shipped to any upstream log sink (Sentry, in-app viewer,
/// stdout). If a raw email or phone shows up in `formatted()`, redaction
/// failed.

void main() {
  group('AppLogger PII redaction', () {
    setUp(AppLogger.clearBuffer);

    test('email in event is redacted', () {
      AppLogger.auth.i('signInFailed for jane.doe@example.com');
      final entry = AppLogger.recent().single;
      expect(entry.event, 'signInFailed for <email>');
      expect(entry.formatted(), contains('<email>'));
      expect(entry.formatted(), isNot(contains('jane.doe@example.com')));
    });

    test('email in field value is redacted', () {
      AppLogger.auth.i('signIn', fields: {'email': 'a.b+tag@sub.example.co'});
      final entry = AppLogger.recent().single;
      expect(entry.fields!['email'], '<email>');
    });

    test('E.164 phone in field value is redacted', () {
      AppLogger.auth.i('otpRequest',
          fields: {'phone': '+1 415 555 0123', 'attempt': 2});
      final entry = AppLogger.recent().single;
      expect(entry.fields!['phone'], '<phone>');
      // Non-string values are NOT touched.
      expect(entry.fields!['attempt'], 2);
    });

    test('JWT token is redacted', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
          'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4iLCJpYXQiOjE1MTZ9.'
          'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      AppLogger.auth.d('refresh', fields: {'token': jwt});
      final entry = AppLogger.recent().single;
      expect(entry.fields!['token'], '<jwt>');
    });

    test('nested map values are redacted recursively', () {
      AppLogger.notification.i('push', fields: {
        'user': {'id': 'u1', 'email': 'x@y.com'},
        'meta': [
          'ok',
          {'contact': '+1 415 555 0987'}
        ],
      });
      final entry = AppLogger.recent().single;
      final user = entry.fields!['user'] as Map;
      expect(user['id'], 'u1');
      expect(user['email'], '<email>');
      final meta = entry.fields!['meta'] as List;
      expect(meta[0], 'ok');
      expect((meta[1] as Map)['contact'], '<phone>');
    });

    test('non-PII strings pass through untouched', () {
      AppLogger.battle
          .i('cinematic', fields: {'topSlot': 5, 'src': 'city_arena.glb'});
      final entry = AppLogger.recent().single;
      expect(entry.fields!['topSlot'], 5);
      expect(entry.fields!['src'], 'city_arena.glb');
    });

    test('short numeric strings are NOT flagged as phones', () {
      // 6-digit OTPs, HTTP status codes, and other short digit strings
      // shouldn't get mangled — the phone regex requires ≥8 digits.
      AppLogger.auth.i('otp', fields: {'code': '123456', 'status': '200'});
      final entry = AppLogger.recent().single;
      expect(entry.fields!['code'], '123456');
      expect(entry.fields!['status'], '200');
    });

    test('redaction is idempotent', () {
      AppLogger.auth.i('duplicated <email> <phone>');
      final entry = AppLogger.recent().single;
      expect(entry.event, 'duplicated <email> <phone>');
    });

    test('phone inside JSON-shaped string is redacted (quote boundary)',
        () {
      // Regression guard for the lookbehind gap that used to allow
      // `"`, `'`, `=`, `>` to slip through. A Postgrest error body that
      // echoes a request payload would previously leak the raw phone.
      AppLogger.auth.i(
        'Failed request: {"phone":"+12345678901","attempt":1}',
      );
      final entry = AppLogger.recent().single;
      expect(entry.formatted(), contains('<phone>'));
      expect(entry.formatted(), isNot(contains('+12345678901')));
    });

    test('UUIDs are NOT mangled by the phone regex', () {
      // Regression guard for an over-broad lookbehind. Supabase user
      // ids are UUIDs; the middle segments have 8 digits with dashes,
      // which a `[^A-Za-z0-9]` lookbehind used to allow through.
      const uid = 'eda26926-2318-4166-a9ee-b0d8703607df';
      AppLogger.auth.i('syncSteps', fields: {'userId': uid, 'steps': 1555});
      final entry = AppLogger.recent().single;
      expect(entry.fields!['userId'], uid);
      expect(entry.formatted(), contains(uid));
      expect(entry.formatted(), isNot(contains('<phone>')));
    });

    test('ISO timestamps are NOT redacted', () {
      AppLogger.auth
          .i('tick at 2026-07-13T10:22:42.034128Z', fields: {'ok': true});
      final entry = AppLogger.recent().single;
      expect(entry.event, contains('2026-07-13T10:22:42.034128Z'));
      expect(entry.formatted(), isNot(contains('<phone>')));
    });
  });
}
