import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../utils/app_logger.dart';
import 'google_fit_service.dart';
import 'health_service.dart';
import 'mission_service.dart';
import 'native_step_service.dart';
import 'persistent_notifications.dart';
import 'step_service.dart';
import 'step_source_aggregator.dart';
import 'xp_service.dart';

/// Off-UI step syncing.
///
/// The battle *lifecycle* (activation, completion, XP, notifications) runs on
/// the Supabase side via pg_cron — see supabase/migrations/0008. That works no
/// matter what the app is doing. The one thing the server can't do is read the
/// phone's pedometer, so this module keeps `profiles.total_steps_all_time`
/// (and therefore the live battle score) fresh while the UI isn't in front:
///
///   • WorkManager periodic task — the only thing that can run while the app is
///     fully terminated. Best-effort, >=15 min, throttled by Doze / OEM killers.
///   • flutter_foreground_task — a persistent foreground service that syncs on a
///     tight cadence while a battle is active and the app is backgrounded.
///
/// Both delegate to the single isolate-safe [headlessStepSync] entrypoint.

const _periodicTaskName = 'stepbattle-step-sync';
const _periodicTaskTag = 'stepSync';
const _foregroundServiceId = 4401;

/// Hive key (in the existing `step_tracker` box) storing the millisecond
/// timestamp of the foreground service's last tick. Used by the WorkManager
/// dispatcher to skip work while the always-on service is keeping things
/// fresh on its own. Stale beyond [_fgAliveTtl] (e.g., after a swipe-kill),
/// the WorkManager fallback re-engages.
const _fgAliveKey = 'fg_alive_at_ms';
const _fgAliveTtl = Duration(minutes: 10);

void _markForegroundAlive() {
  try {
    Hive.box(NativeStepService.boxName)
        .put(_fgAliveKey, DateTime.now().millisecondsSinceEpoch);
  } catch (_) {}
}

bool _foregroundRecentlyAlive() {
  try {
    final ms = Hive.box(NativeStepService.boxName).get(_fgAliveKey);
    if (ms is! int) return false;
    return DateTime.now().millisecondsSinceEpoch - ms < _fgAliveTtl.inMilliseconds;
  } catch (_) {
    return false;
  }
}

/// Tracks Supabase init *within the current isolate*. Background isolates start
/// fresh, so this resets to false on each cold isolate — exactly what we want
/// (calling Supabase.initialize twice in one isolate throws).
bool _supabaseReadyInThisIsolate = false;

// =============================================================================
// Shared entrypoint — runs in whatever background isolate calls it.
// =============================================================================

/// Initialize the background isolate (Hive + dotenv + Supabase) and return the
/// signed-in user id, or null if env/session is unavailable. Idempotent per
/// isolate.
Future<String?> _ensureBackgroundInitAndUid() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Hive.isBoxOpen(NativeStepService.boxName)) {
    await Hive.initFlutter();
    await Hive.openBox(NativeStepService.boxName);
  }
  if (!dotenv.isInitialized) {
    await dotenv.load(fileName: '.env');
  }
  final url = dotenv.env['SUPABASE_URL'];
  final key = dotenv.env['SUPABASE_ANON_KEY'];
  if (url == null || url.isEmpty || key == null || key.isEmpty) return null;
  if (!_supabaseReadyInThisIsolate) {
    await Supabase.initialize(url: url, anonKey: key);
    _supabaseReadyInThisIsolate = true;
  }
  return Supabase.instance.client.auth.currentUser?.id;
}

/// Soonest `end_time` (UTC) among the user's currently-active battles, or null.
Future<DateTime?> _soonestActiveBattleEnd(String uid) async {
  try {
    final rows = await Supabase.instance.client
        .from('battles')
        .select('end_time, battle_participants!inner(user_id)')
        .eq('status', 'active')
        .eq('battle_participants.user_id', uid)
        .order('end_time', ascending: true)
        .limit(1);
    final list = rows as List;
    if (list.isEmpty) return null;
    final e = (list.first as Map)['end_time'] as String?;
    return e == null ? null : DateTime.parse(e);
  } catch (_) {
    return null;
  }
}

/// Read the best-available step count and push it to Supabase. Fully
/// self-contained (no Riverpod, no widget tree) so it works from a WorkManager
/// callback or a foreground-service isolate. Never throws.
Future<void> headlessStepSync() async {
  try {
    final uid = await _ensureBackgroundInitAndUid();
    if (uid == null) {
      AppLogger.step.w('headlessSync:noSessionOrEnv');
      return;
    }

    // Read steps. Give the native pedometer stream a moment to emit its
    //    first reading; Health Connect reads async and is the preferred source
    //    anyway, so we still get a value even if native is cold.
    final native = NativeStepService();
    final hc = HealthService();
    final fit = GoogleFitService();
    final aggregator = StepSourceAggregator(
      native: native,
      healthService: hc,
      googleFit: fit,
    );
    await aggregator.warmUp();
    await Future<void>.delayed(const Duration(seconds: 2));
    final reading = await aggregator.readWithDebug();
    if (reading.aggregate <= 0) {
      AppLogger.step.i('headlessSync:noSteps', fields: {'uid': uid});
      return;
    }

    final source = reading.healthConnectSteps == reading.aggregate
        ? hc.sourceName
        : (reading.nativeSteps == reading.aggregate
            ? 'native_pedometer'
            : 'google_fit');

    // 5. Push — syncSteps fans out to step_logs, total_steps_all_time, XP,
    //    missions, active battles, clan (StepService handles all of it).
    await StepService(
      missionService: MissionService(),
      xpService: XPService(),
    ).syncSteps(userId: uid, steps: reading.aggregate, source: source);

    // 6. Push fresh values to the home-screen widget. Non-fatal — the sync
    //    is the important bit; widget freshness is best-effort.
    await _pushHomeWidget(uid: uid, steps: reading.aggregate);

    AppLogger.step.i('headlessSync:done',
        fields: {'uid': uid, 'steps': reading.aggregate, 'source': source});
  } catch (e, s) {
    AppLogger.step.e('headlessSync:failed', error: e, stack: s);
  }
}

/// Persist the latest stats into SharedPreferences keys the widget reads,
/// then ask Android to re-render. Reads daily_step_goal from `profiles` so
/// the bar scales correctly. No-op if Supabase isn't ready.
Future<void> _pushHomeWidget({required String uid, required int steps}) async {
  try {
    final profile = await Supabase.instance.client
        .from('profiles')
        .select('daily_step_goal')
        .eq('id', uid)
        .maybeSingle();
    final goal = (profile?['daily_step_goal'] as num?)?.toInt() ?? 8000;
    final kcal = (steps * 0.04).round();
    final distanceKm = (steps * 0.762 / 1000).toStringAsFixed(2);

    await HomeWidget.saveWidgetData<int>('steps', steps);
    await HomeWidget.saveWidgetData<int>('goal', goal);
    await HomeWidget.saveWidgetData<int>('kcal', kcal);
    await HomeWidget.saveWidgetData<String>('distance_km_str', distanceKm);
    await HomeWidget.updateWidget(
      name: 'StepBattleWidgetProvider',
      androidName: 'StepBattleWidgetProvider',
    );
  } catch (e, s) {
    AppLogger.step.w('homeWidget:pushFailed', fields: {'error': e.toString()});
    // Swallow — widget freshness is non-critical.
    if (kDebugMode) AppLogger.step.e('homeWidget:pushFailed', error: e, stack: s);
  }
}

// =============================================================================
// WorkManager — terminated-state periodic sync (Android).
// =============================================================================

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    // Open the box so we can read the foreground-alive flag.
    if (!Hive.isBoxOpen(NativeStepService.boxName)) {
      try {
        await Hive.initFlutter();
        await Hive.openBox(NativeStepService.boxName);
      } catch (_) {}
    }
    if (_foregroundRecentlyAlive()) {
      // Always-on foreground service is keeping things fresh; skip duplicate work.
      AppLogger.step.t('headlessSync:skipped_fg_alive');
      return true;
    }
    await headlessStepSync();
    return true;
  });
}

// =============================================================================
// Foreground service — always-on while signed in. The persistent notification
// adapts to the user's current state (idle / active battle / [later: track]).
// =============================================================================

/// Rendered notification content for the persistent foreground notification.
/// `body` is the single-line collapsed text; Android will use it as the
/// BigTextStyle source when the user pulls the shade down, so we pack it with
/// `\n`-separated lines (steps / distance / kcal / progress).
class _NotifContent {
  final String title;
  final String body;
  final List<NotificationButton> buttons;
  const _NotifContent(this.title, this.body, this.buttons);

  int get dedupeHash =>
      Object.hash(title, body, buttons.map((b) => b.id).join(','));
}

// Stable button ids — also referenced by `onNotificationButtonPressed`.
// Only `open_app` is wired on the FGS summary now; the battle/track
// notifications are owned by PersistentNotifications and have their own
// action ids handled by the flutter_local_notifications tap callback.
const _kBtnOpen = 'open_app';

String _fmtNumber(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _fmtRemaining(Duration d) {
  if (d.isNegative) return 'ending';
  final days = d.inDays;
  final hours = d.inHours % 24;
  final mins = d.inMinutes % 60;
  if (days > 0) return '${days}d ${hours}h left';
  if (hours > 0) return '${hours}h ${mins}m left';
  if (mins > 0) return '${mins}m left';
  return 'ending';
}

String _fmtElapsed(Duration d) {
  final hours = d.inHours;
  final mins = d.inMinutes % 60;
  final secs = d.inSeconds % 60;
  if (hours > 0) return '${hours}h ${mins}m';
  if (mins > 0) return '${mins}m ${secs}s';
  return '${secs}s';
}

/// Daily-summary content for the foreground service's notification. This
/// renders EVERY tick regardless of what else is happening (battle, track) —
/// those get their own separate persistent notifications layered on top via
/// [PersistentNotifications].
Future<_NotifContent> _renderSummary(String uid) async {
  final client = Supabase.instance.client;
  try {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final logRow = await client
        .from('step_logs')
        .select('step_count, calories')
        .eq('user_id', uid)
        .eq('date', today)
        .maybeSingle();
    final profile = await client
        .from('profiles')
        .select('daily_step_goal')
        .eq('id', uid)
        .maybeSingle();
    final steps = (logRow?['step_count'] as num?)?.toInt() ?? 0;
    final kcal = (logRow?['calories'] as num?)?.toInt() ?? 0;
    final goal = (profile?['daily_step_goal'] as num?)?.toInt() ?? 8000;
    final distanceMeters = (steps * 0.762).round(); // stride default
    final distanceKm = (distanceMeters / 1000).toStringAsFixed(2);
    final pct = goal > 0 ? ((steps / goal) * 100).clamp(0, 999).round() : 0;
    // Collapsed (one-line) summary + BigText expansion (multi-line below).
    final body = '${_fmtNumber(steps)} / ${_fmtNumber(goal)} steps · $pct%'
        '\n👟 ${_fmtNumber(steps)} steps · 📏 $distanceKm km · 🔥 $kcal kcal';
    return _NotifContent(
      'StepBattle · today',
      body,
      const [NotificationButton(id: _kBtnOpen, text: 'Open')],
    );
  } catch (_) {
    return const _NotifContent(
      'StepBattle',
      'Tracking your steps',
      [NotificationButton(id: _kBtnOpen, text: 'Open')],
    );
  }
}

/// Content for the SECONDARY battle notification (posted via
/// flutter_local_notifications, separate from the FGS summary).
class _BattleNotifContent {
  final String battleId;
  final String title;
  final String body;
  final String bigText;
  const _BattleNotifContent({
    required this.battleId,
    required this.title,
    required this.body,
    required this.bigText,
  });
}

/// Look up the user's soonest active battle and render a delta-aware
/// notification (ahead/behind for 1v1, rank + leader gap for group).
/// Returns null when there's no active battle the user is part of.
Future<_BattleNotifContent?> _renderBattle(String uid) async {
  final client = Supabase.instance.client;
  try {
    // Find the user's soonest-ending active battle.
    final mine = await client
        .from('battle_participants')
        .select('battle_id, battles!inner(id, type, end_time, status)')
        .eq('user_id', uid)
        .eq('battles.status', 'active')
        .eq('invite_status', 'accepted')
        .order('battles(end_time)', ascending: true)
        .limit(1)
        .maybeSingle();
    if (mine == null) return null;
    final battle = mine['battles'] as Map<String, dynamic>?;
    if (battle == null) return null;

    final battleId = battle['id'] as String? ?? '';
    final type = battle['type'] as String? ?? '1v1';
    final endStr = battle['end_time'] as String?;
    final remaining = endStr == null
        ? null
        : DateTime.parse(endStr).difference(DateTime.now().toUtc());
    final remainingStr =
        remaining == null ? '' : ' · ${_fmtRemaining(remaining)}';

    // Pull all accepted participants for that battle.
    final partRows = await client
        .from('battle_participants')
        .select('user_id, display_name, current_steps')
        .eq('battle_id', battleId)
        .eq('invite_status', 'accepted');

    final participants = (partRows as List)
        .map((r) => {
              'user_id': (r as Map)['user_id'] as String,
              'display_name': r['display_name'] as String? ?? '',
              'current_steps': (r['current_steps'] as num?)?.toInt() ?? 0,
            })
        .toList();
    if (participants.isEmpty) return null;

    final me = participants.firstWhere(
      (p) => p['user_id'] == uid,
      orElse: () => <String, Object>{},
    );
    if (me.isEmpty) return null;
    final mySteps = me['current_steps'] as int;

    String body;
    String bigText;

    if (type == '1v1' && participants.length == 2) {
      // ---- 1v1 — ahead / behind / tied ----
      final opp = participants.firstWhere(
        (p) => p['user_id'] != uid,
        orElse: () => <String, Object>{},
      );
      final oppName = (opp['display_name'] as String?) ?? 'Opponent';
      final oppSteps = (opp['current_steps'] as int?) ?? 0;
      final delta = mySteps - oppSteps;

      final relationLine = delta > 0
          ? "You're ahead by ${_fmtNumber(delta)} steps"
          : delta < 0
              ? "You're behind by ${_fmtNumber(-delta)} steps"
              : "You're tied";

      body = '$relationLine$remainingStr';
      bigText = 'You vs $oppName\n'
          '👟 You: ${_fmtNumber(mySteps)}\n'
          '👟 $oppName: ${_fmtNumber(oppSteps)}\n'
          '$relationLine'
          '${remaining == null ? '' : '\n⏱ ${_fmtRemaining(remaining)}'}';
    } else {
      // ---- Group — rank + gap from leader ----
      participants.sort((a, b) =>
          (b['current_steps'] as int).compareTo(a['current_steps'] as int));
      final myRank =
          participants.indexWhere((p) => p['user_id'] == uid) + 1;
      final leader = participants.first;
      final leaderSteps = leader['current_steps'] as int;
      final gap = leaderSteps - mySteps;

      String rankLine;
      if (myRank == 1) {
        // Lead vs the second place.
        final second = participants.length > 1
            ? participants[1]['current_steps'] as int
            : mySteps;
        final lead = mySteps - second;
        rankLine =
            "Rank 1 of ${participants.length} · Leading by ${_fmtNumber(lead)}";
      } else {
        rankLine =
            'Rank $myRank of ${participants.length} · ${_fmtNumber(gap)} behind leader';
      }
      body = '$rankLine$remainingStr';
      bigText = 'Multi-player battle\n'
          '${participants.take(4).map((p) {
                final isMe = p['user_id'] == uid;
                final marker = isMe ? '🟣' : '⚪';
                return '$marker ${p['display_name']}: ${_fmtNumber(p['current_steps'] as int)}';
              }).join('\n')}\n'
          '$rankLine'
          '${remaining == null ? '' : '\n⏱ ${_fmtRemaining(remaining)}'}';
    }

    return _BattleNotifContent(
      battleId: battleId,
      title: 'Battle in progress',
      body: body,
      bigText: bigText,
    );
  } catch (_) {
    return null;
  }
}

/// Content for the TRACK notification. Just elapsed time for now; the live
/// session screen owns the rich UI. Returns null when no Track is active.
({String title, String body, String bigText})? _renderTrack() {
  try {
    // Hive keys mirror `RunTrackingService.activeTrack*Key` — kept as
    // literals here because importing across the background-service
    // isolate boundary tends to break the plugin's entry-point
    // registration.
    final box = Hive.box(NativeStepService.boxName);
    final startedMs = box.get('active_track_started_at');
    if (startedMs is! int) return null;

    final started = DateTime.fromMillisecondsSinceEpoch(startedMs);
    final elapsed = DateTime.now().difference(started);
    final elapsedStr = _fmtElapsed(elapsed);

    // Read the mirror set. Missing values render as "—" so a race
    // between `start()` and the first `_emit()` doesn't crash the
    // notification with a NaN.
    final steps = (box.get('active_track_steps') as num?)?.toInt() ?? 0;
    final distanceM =
        (box.get('active_track_distance_m') as num?)?.toDouble() ?? 0.0;
    final paceSecKm =
        (box.get('active_track_pace_sec_km') as num?)?.toDouble();

    final distanceStr = _fmtDistance(distanceM);
    final paceStr = _fmtPace(paceSecKm);
    final stepsStr = _fmtSteps(steps);

    // Compact single-line body for the collapsed notification.
    final compactBody =
        '$distanceStr · $elapsedStr · $paceStr · $stepsStr steps';

    // Expanded lock-screen BigText — Strava-style layout the user
    // asked for. Emoji labels give the four values an at-a-glance
    // legend without needing a custom layout XML.
    final bigText = 'Run in progress\n'
        '⏱ Time  $elapsedStr\n'
        '📏 Distance  $distanceStr\n'
        '🏃 Pace  $paceStr\n'
        '👟 Steps  $stepsStr';

    return (
      title: 'Tracking your run',
      body: compactBody,
      bigText: bigText,
    );
  } catch (_) {}
  return null;
}

/// Format metres → "1.11 km" (or "812 m" under 1 km).
String _fmtDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000.0;
  return '${km.toStringAsFixed(km < 10 ? 2 : 1)} km';
}

/// Format seconds/km → "7:34 /km" (or "--/km" when null).
String _fmtPace(double? secPerKm) {
  if (secPerKm == null || secPerKm.isNaN || !secPerKm.isFinite) {
    return '--/km';
  }
  final m = secPerKm ~/ 60;
  final s = (secPerKm % 60).round();
  return '$m:${s.toString().padLeft(2, '0')} /km';
}

/// Thousand-separated integer for the steps line.
String _fmtSteps(int n) {
  if (n == 0) return '0';
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

@pragma('vm:entry-point')
void foregroundTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(_StepSyncTaskHandler());
}

class _StepSyncTaskHandler extends TaskHandler {
  Timer? _finalSyncTimer;
  DateTime? _scheduledEnd;
  int _lastNotifHash = 0;

  /// Faster timer dedicated to re-posting the secondary battle + track
  /// persistent notifications. Survives a swipe-dismiss because every tick
  /// re-issues the show() call. The main `onRepeatEvent` (5 min) is too slow
  /// for "auto-re-show within seconds" UX.
  Timer? _notifTimer;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _markForegroundAlive();
    // This isolate gets a fresh PersistentNotifications instance — initialize
    // with a no-op tap callback (the MAIN isolate's init owns tap routing).
    await PersistentNotifications.instance.init(onTap: (_) {});
    await headlessStepSync();
    await _scheduleFinalSync();
    await _refreshAll(force: true);
    _notifTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshAll(force: true);
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _markForegroundAlive();
    // Fire-and-forget: the interface is synchronous.
    headlessStepSync();
    _scheduleFinalSync();
    _refreshAll();
  }

  /// Nudges from the main isolate (e.g., when a battle accept/complete fires,
  /// or a Track session starts/stops). Triggers a refresh of all three.
  @override
  void onReceiveData(Object data) {
    _refreshAll(force: true);
  }

  /// Android 14+ lets the user swipe-dismiss FGS notifications. We treat the
  /// daily summary as essential UI (it IS the always-on service) and
  /// re-render it immediately so it pops back. (Auto-re-show for the battle
  /// and track notifications relies on `_notifTimer`'s 30s tick.)
  @override
  void onNotificationDismissed() {
    AppLogger.battle.i('persistentNotif:dismissed_reissuing');
    _refreshAll(force: true);
  }

  /// Action-button taps from the FGS notification. Routes to the main
  /// isolate so the UI can react.
  @override
  void onNotificationButtonPressed(String id) {
    AppLogger.battle.i('persistentNotif:buttonPressed', fields: {'id': id});
    FlutterForegroundTask.sendDataToMain('btn:$id');
    FlutterForegroundTask.launchApp();
  }

  /// Refresh all three persistent notifications:
  ///   • Daily summary  — FGS notification, updated via `updateService`.
  ///   • Battle status  — local notification, posted/cancelled per state.
  ///   • Track status   — local notification, posted/cancelled per state.
  Future<void> _refreshAll({bool force = false}) async {
    try {
      final uid = await _ensureBackgroundInitAndUid();
      if (uid == null) return;
      await _refreshSummary(uid, force: force);
      await _refreshBattleNotif(uid, force: force);
      await _refreshTrackNotif(force: force);
    } catch (_) {}
  }

  Future<void> _refreshSummary(String uid, {required bool force}) async {
    try {
      final content = await _renderSummary(uid);
      final hash = content.dedupeHash;
      if (!force && hash == _lastNotifHash) return;
      _lastNotifHash = hash;
      await FlutterForegroundTask.updateService(
        notificationTitle: content.title,
        notificationText: content.body,
        notificationButtons: content.buttons,
      );
    } catch (_) {}
  }

  Future<void> _refreshBattleNotif(String uid, {required bool force}) async {
    final battle = await _renderBattle(uid);
    if (battle == null) {
      await PersistentNotifications.instance.cancelBattle();
      return;
    }
    await PersistentNotifications.instance.showBattle(
      battleId: battle.battleId,
      title: battle.title,
      body: battle.body,
      bigText: battle.bigText,
      force: force,
    );
  }

  Future<void> _refreshTrackNotif({required bool force}) async {
    final track = _renderTrack();
    if (track == null) {
      await PersistentNotifications.instance.cancelTrack();
      return;
    }
    await PersistentNotifications.instance.showTrack(
      title: track.title,
      body: track.body,
      bigText: track.bigText,
      force: force,
    );
  }

  /// Schedule a one-shot sync ~45s before the soonest active battle ends, so
  /// the final steps land before the server's grace freeze (end_time + 90s).
  /// Re-checked each repeat tick; no-ops if already scheduled for that battle.
  Future<void> _scheduleFinalSync() async {
    try {
      final uid = await _ensureBackgroundInitAndUid();
      if (uid == null) return;
      final end = await _soonestActiveBattleEnd(uid);
      if (end == null) return;
      if (_scheduledEnd == end && (_finalSyncTimer?.isActive ?? false)) return;
      final delay = end
          .subtract(const Duration(seconds: 45))
          .difference(DateTime.now().toUtc());
      if (delay.isNegative) return;
      _finalSyncTimer?.cancel();
      _scheduledEnd = end;
      _finalSyncTimer = Timer(delay, () {
        headlessStepSync();
      });
      AppLogger.battle.i('foregroundFinalSync:scheduled',
          fields: {'inSeconds': delay.inSeconds});
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _finalSyncTimer?.cancel();
    _notifTimer?.cancel();
    // Pull down the secondary notifications when the service is being torn
    // down (e.g., the user signed out). Otherwise they linger orphaned.
    await PersistentNotifications.instance.cancelBattle();
    await PersistentNotifications.instance.cancelTrack();
  }
}

// =============================================================================
// Controller — called from the app (main isolate).
// =============================================================================

class BackgroundSync {
  const BackgroundSync._();

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// One-time setup in main(): foreground-task config + WorkManager init.
  static Future<void> initEarly() async {
    if (!_supported) return;
    try {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          // ChannelId kept stable so users who already see this notification
          // don't end up with two channels in Settings.
          channelId: 'stepbattle_battle_sync',
          channelName: 'StepBattle live stats',
          channelDescription:
              'Daily progress, active battles, and run tracking.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          // Sync every 5 minutes while the service runs.
          eventAction: ForegroundTaskEventAction.repeat(5 * 60 * 1000),
          autoRunOnBoot: true,
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );
      await Workmanager().initialize(backgroundSyncDispatcher);
    } catch (e, s) {
      AppLogger.step.e('backgroundSync:initFailed', error: e, stack: s);
    }
  }

  /// Register the periodic (>=15 min) terminated-state sync. Idempotent —
  /// `keep` means re-registering won't reset the schedule. Call after login.
  static Future<void> registerPeriodicSync() async {
    if (!_supported) return;
    try {
      await Workmanager().registerPeriodicTask(
        _periodicTaskName,
        _periodicTaskTag,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } catch (e, s) {
      AppLogger.step.e('backgroundSync:periodicRegisterFailed',
          error: e, stack: s);
    }
  }

  static Future<void> cancelPeriodicSync() async {
    if (!_supported) return;
    try {
      await Workmanager().cancelByUniqueName(_periodicTaskName);
    } catch (_) {}
  }

  /// Start the always-on foreground service. The notification it renders
  /// adapts to the user's current state (idle / battle / [later: track]).
  /// No-op if already running. Call once after sign-in.
  static Future<void> startService() async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: _foregroundServiceId,
        notificationTitle: 'StepBattle',
        notificationText: 'Tracking your steps',
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.stepbattle.notification.icon',
        ),
        callback: foregroundTaskStartCallback,
      );
      AppLogger.battle.i('backgroundSync:fgServiceStarted');
    } catch (e, s) {
      AppLogger.battle.e('backgroundSync:fgServiceStartFailed',
          error: e, stack: s);
    }
  }

  static Future<void> stopService() async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        AppLogger.battle.i('backgroundSync:fgServiceStopped');
      }
    } catch (_) {}
  }

  /// Nudge the running foreground service to immediately refresh its
  /// notification (e.g., after a battle accept/complete in the main isolate).
  /// No-op if the service isn't running.
  static Future<void> nudge() async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        FlutterForegroundTask.sendDataToTask('refresh');
      }
    } catch (_) {}
  }
}
