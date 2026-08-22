import 'dart:io' show Platform;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../utils/app_logger.dart';
import 'background_sync.dart';

/// Android-only exact-time wake scheduler.
///
/// **Why this exists:** WorkManager's periodic tasks are BEST-effort —
/// aggressive OEM battery savers (Xiaomi, Realme, OnePlus with Battery
/// Saver on, etc.) block them for hours. Doze mode also defers them.
/// This means users on those devices see hours-long gaps in cloud sync
/// even when they've been walking all day. Backfill on next foreground
/// open covers the daily TOTAL correctly, but hourly resolution is lost.
///
/// AlarmManager's `setExactAndAllowWhileIdle` is Android's blessed
/// mechanism for waking apps at PRECISE times, even in Doze. Google
/// specifically carves out fitness tracking as a valid use case for the
/// `USE_EXACT_ALARM` install-time permission (see Play policy). We
/// schedule 4 wakes/day — early morning, midday, evening, before-midnight
/// — each firing [alarmWakeCallback] which delegates to
/// [headlessStepSync]. Combined with the existing FGS + WorkManager
/// paths, this gives us at MOST a 6-hour gap in cloud sync even in the
/// worst-case aggressive-OEM scenario.
///
/// **Not on iOS.** iOS has no equivalent primitive; silent APNS pushes
/// are the closest analogue there, staged in PENDING_MIGRATIONS.md as
/// a separate initiative.
class AlarmWakeScheduler {
  AlarmWakeScheduler._();

  /// Stable alarm ids. Must stay constant across app versions — if we
  /// bumped these we'd end up with the OLD alarms still scheduled AND
  /// duplicates for the NEW ids, doubling wake-ups. Never renumber.
  static const int _idEarlyMorning = 4801;
  static const int _idMidday = 4802;
  static const int _idEvening = 4803;
  static const int _idBeforeMidnight = 4804;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// Initialize the plugin. Call once from main() before scheduling.
  /// No-op on non-Android platforms.
  static Future<void> initialize() async {
    if (!_supported) return;
    try {
      await AndroidAlarmManager.initialize();
    } catch (e, s) {
      AppLogger.step.e('alarmWake:initFailed', error: e, stack: s);
    }
  }

  /// Schedule (or re-schedule) the 4 daily wakes. Idempotent — calling
  /// again with the same ids REPLACES the existing schedule, so we can
  /// call this on every app foreground without duplication.
  ///
  /// Wake times are chosen to bracket typical walking windows:
  ///   • 06:00 — captures overnight-to-morning steps
  ///   • 12:00 — midday snapshot; catches morning walks / commutes
  ///   • 18:00 — early evening; catches lunch-time walks
  ///   • 23:45 — pre-midnight; ensures yesterday's total is fresh
  ///             in Supabase before the day boundary
  ///
  /// Each wake fires [alarmWakeCallback] in a background isolate. That
  /// callback calls [headlessStepSync] which reads sources + pushes to
  /// Supabase — the exact same code path WorkManager uses, but triggered
  /// deterministically at these clock times instead of "sometime in the
  /// next 15 minutes."
  static Future<void> scheduleDaily() async {
    if (!_supported) return;
    try {
      await _scheduleOne(_idEarlyMorning, const _WakeTime(hour: 6,  minute: 0));
      await _scheduleOne(_idMidday,       const _WakeTime(hour: 12, minute: 0));
      await _scheduleOne(_idEvening,      const _WakeTime(hour: 18, minute: 0));
      await _scheduleOne(_idBeforeMidnight, const _WakeTime(hour: 23, minute: 45));
      AppLogger.step.i('alarmWake:scheduled', fields: {'count': 4});
    } catch (e, s) {
      AppLogger.step.e('alarmWake:scheduleFailed', error: e, stack: s);
    }
  }

  /// Cancel every scheduled wake. Call on sign-out or when the user
  /// disables background tracking in settings.
  static Future<void> cancelAll() async {
    if (!_supported) return;
    try {
      await AndroidAlarmManager.cancel(_idEarlyMorning);
      await AndroidAlarmManager.cancel(_idMidday);
      await AndroidAlarmManager.cancel(_idEvening);
      await AndroidAlarmManager.cancel(_idBeforeMidnight);
      AppLogger.step.i('alarmWake:cancelledAll');
    } catch (_) {}
  }

  static Future<void> _scheduleOne(int id, _WakeTime t) async {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    // If today's target has already passed, schedule for tomorrow.
    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }
    await AndroidAlarmManager.periodic(
      const Duration(days: 1),
      id,
      alarmWakeCallback,
      startAt: target,
      // Fire even during Doze / Idle mode. This is the key flag —
      // without it Doze can delay the wake for hours.
      allowWhileIdle: true,
      // Wake the device from sleep if needed.
      wakeup: true,
      // Re-register automatically on device reboot.
      rescheduleOnReboot: true,
      // exact: false — we DELIBERATELY use inexact alarms
      // (`setAndAllowWhileIdle` under the hood) so we don't need
      // SCHEDULE_EXACT_ALARM / USE_EXACT_ALARM permissions. Google
      // Play's exact-alarm policy restricts USE_EXACT_ALARM to
      // alarm-clock / timer / calendar apps only; fitness-sync
      // doesn't qualify. The 4×/day cadence tolerates ±10 min drift
      // just fine — see AndroidManifest.xml comment for the full
      // reasoning. Prior versions (1.1.5) had `exact: true` and the
      // permissions declared, which failed Play policy review on
      // the 1.1.6 upload attempt (2026-08-11).
      exact: false,
    );
  }
}

/// Simple hh:mm pair. Not exposed publicly; local convenience type.
class _WakeTime {
  final int hour;
  final int minute;
  const _WakeTime({required this.hour, required this.minute});
}

/// Entry point invoked by the AlarmManager at each scheduled wake time.
/// Runs in a fresh background isolate — no Flutter widget tree, no
/// Riverpod, no ambient services. All we can safely do is initialize
/// enough to reach [headlessStepSync], which is designed exactly for
/// this "no ambient context" invocation.
///
/// The `@pragma('vm:entry-point')` annotation is REQUIRED — without it,
/// the Dart tree-shaker drops this function in release builds and the
/// alarm fires against an unresolved symbol.
@pragma('vm:entry-point')
Future<void> alarmWakeCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    AppLogger.step.i('alarmWake:tick');
    await headlessStepSync();
  } catch (e, s) {
    AppLogger.step.e('alarmWake:tickFailed', error: e, stack: s);
  }
}
