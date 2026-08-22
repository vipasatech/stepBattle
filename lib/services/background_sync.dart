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
import '../utils/cross_isolate_kv.dart';
import 'google_fit_service.dart';
import 'health_service.dart';
import 'mission_service.dart';
import 'native_step_service.dart';
import 'observability_service.dart';
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

/// SharedPreferences-hosted timestamp of the foreground service's last
/// tick. Used by the WorkManager dispatcher to skip work while the
/// always-on service is keeping things fresh on its own. Stale beyond
/// [_fgAliveTtl] (e.g., after a swipe-kill), the WorkManager fallback
/// re-engages.
///
/// Storage moved from Hive → SharedPreferences in the Level B refactor
/// so the FGS isolate and the WorkManager isolate coordinate through
/// a process-safe primitive instead of racing over the same Hive file.
const _fgAliveTtl = Duration(minutes: 10);

Future<void> _markForegroundAlive() async {
  try {
    await CrossIsolateKV.setInt(
      CrossIsolateKV.fgAliveAtMs,
      DateTime.now().millisecondsSinceEpoch,
    );
  } catch (_) {}
}

Future<bool> _foregroundRecentlyAlive() async {
  try {
    final ms = await CrossIsolateKV.getInt(CrossIsolateKV.fgAliveAtMs);
    if (ms == null) return false;
    return DateTime.now().millisecondsSinceEpoch - ms <
        _fgAliveTtl.inMilliseconds;
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

/// Initialize the background isolate (Hive + dotenv + Supabase + KV) and
/// return the signed-in user id, or null if env/session is unavailable.
/// Idempotent per isolate.
///
/// The BG isolate opens its own [NativeStepService.backgroundBoxName]
/// box, NOT the main-isolate `boxName` — that separation is the Level B
/// fix that eliminates the two-isolates-on-one-file-handle race that
/// was flooding Diagnostics with `FileSystemException: File closed`.
Future<String?> _ensureBackgroundInitAndUid() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Hive.isBoxOpen(NativeStepService.backgroundBoxName)) {
    await Hive.initFlutter();
    await Hive.openBox(NativeStepService.backgroundBoxName);
  }
  // Warm the SharedPreferences singleton for this isolate — sync
  // reads (e.g. _renderTrack) rely on the cached instance.
  await CrossIsolateKV.init();
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
  final stopwatch = Stopwatch()..start();
  ObservabilityService.breadcrumb('headless.start', category: 'bg.stepSync');
  try {
    final uid = await _ensureBackgroundInitAndUid();
    if (uid == null) {
      AppLogger.step.w('headlessSync:noSessionOrEnv');
      ObservabilityService.breadcrumb(
        'headless.skip',
        category: 'bg.stepSync',
        data: {'reason': 'noSessionOrEnv'},
      );
      return;
    }

    // Read steps. Give the native pedometer stream a moment to emit its
    //    first reading; Health Connect reads async and is the preferred source
    //    anyway, so we still get a value even if native is cold.
    //
    // BG-isolate services use the background-scoped Hive box — NOT the
    // main-isolate box — so we don't collide with the main isolate over
    // one file handle. See NativeStepService.backgroundBoxName.
    //
    // GoogleFitService also needs the box passed explicitly; without
    // it, its constructor defaults to `Hive.box(boxName)` which throws
    // `HiveError: Box not found` in the bg isolate (that box is never
    // opened here). HealthService is Hive-free so it needs no arg.
    final bgBox = Hive.box(NativeStepService.backgroundBoxName);
    final native = NativeStepService(box: bgBox);
    final hc = HealthService();
    final fit = GoogleFitService(box: bgBox);
    final aggregator = StepSourceAggregator(
      native: native,
      healthService: hc,
      googleFit: fit,
    );
    await aggregator.warmUp();
    await Future<void>.delayed(const Duration(seconds: 2));
    final reading = await aggregator.readWithDebug();
    if (reading.aggregate <= 0) {
      AppLogger.step.i('headlessSync:noSteps',
          fields: {'uid': uid, 'ms': stopwatch.elapsedMilliseconds});
      ObservabilityService.breadcrumb(
        'headless.noSteps',
        category: 'bg.stepSync',
        data: {'ms': stopwatch.elapsedMilliseconds},
      );
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

    AppLogger.step.i('headlessSync:done', fields: {
      'uid': uid,
      'steps': reading.aggregate,
      'source': source,
      'ms': stopwatch.elapsedMilliseconds,
    });
    ObservabilityService.breadcrumb('headless.done', category: 'bg.stepSync', data: {
      'steps': reading.aggregate,
      'source': source,
      'ms': stopwatch.elapsedMilliseconds,
    });
  } catch (e, s) {
    AppLogger.step.e('headlessSync:failed',
        fields: {'ms': stopwatch.elapsedMilliseconds}, error: e, stack: s);
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
    // Open the BG-scoped box (never the main box — see backgroundBoxName
    // docs). The fg-alive flag now lives in SharedPreferences, but we
    // still need the box open for headlessStepSync's NativeStepService.
    if (!Hive.isBoxOpen(NativeStepService.backgroundBoxName)) {
      try {
        await Hive.initFlutter();
        await Hive.openBox(NativeStepService.backgroundBoxName);
      } catch (_) {}
    }
    // Warm the SharedPreferences singleton so the fg-alive check reads
    // the current value, not null.
    await CrossIsolateKV.init();
    ObservabilityService.breadcrumb(
      'workmanager.tick',
      category: 'bg.stepSync',
      data: {'task': task},
    );
    if (await _foregroundRecentlyAlive()) {
      // Always-on foreground service is keeping things fresh; skip duplicate work.
      AppLogger.step.t('headlessSync:skipped_fg_alive');
      ObservabilityService.breadcrumb(
        'workmanager.skip',
        category: 'bg.stepSync',
        data: {'reason': 'fg_alive'},
      );
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

      // Four branches, ordered by specificity:
      //   1. Fresh battle (both scores 0) → "First move takes the lead"
      //      pre-1.1.6+34 this fell through to `delta == 0 → "You're
      //      tied"`, which read as if we'd been competing but actually
      //      neither user has moved yet.
      //   2. Genuine tie at non-zero → "Tied at N — push ahead"
      //      previously also "You're tied" — now names the score so
      //      the user sees the competitive standoff explicitly.
      //   3. Ahead — unchanged copy.
      //   4. Behind — unchanged copy.
      final relationLine = (mySteps == 0 && oppSteps == 0)
          ? 'First move takes the lead'
          : delta > 0
              ? "You're ahead by ${_fmtNumber(delta)} steps"
              : delta < 0
                  ? "You're behind by ${_fmtNumber(-delta)} steps"
                  : 'Tied at ${_fmtNumber(mySteps)} — push ahead';

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
      // Fresh battle: leaderSteps == 0 means every accepted participant
      // is at 0. Sort order among 0s is planner-arbitrary, so "myRank"
      // and "Leading by 0" are meaningless. Say what's actually true:
      // the battle just started.
      if (leaderSteps == 0) {
        rankLine =
            'Battle just started · ${participants.length} players at the line';
      } else if (myRank == 1) {
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
///
/// Reads from SharedPreferences (via [CrossIsolateKV]) rather than Hive so
/// the main-isolate writes in [RunTrackingService] and this BG-isolate
/// read never collide on the shared Hive file handle.
({String title, String body, String bigText})? _renderTrack() {
  try {
    final startedMs =
        CrossIsolateKV.getIntSync(CrossIsolateKV.activeTrackStartedAt);
    if (startedMs == null) return null;

    final started = DateTime.fromMillisecondsSinceEpoch(startedMs);
    final elapsed = DateTime.now().difference(started);
    final elapsedStr = _fmtElapsed(elapsed);

    // Read the mirror set. Missing values render as "—" so a race
    // between `start()` and the first `_emit()` doesn't crash the
    // notification with a NaN.
    final steps =
        CrossIsolateKV.getIntSync(CrossIsolateKV.activeTrackSteps) ?? 0;
    final distanceM =
        CrossIsolateKV.getDoubleSync(CrossIsolateKV.activeTrackDistanceM) ??
            0.0;
    final paceSecKm =
        CrossIsolateKV.getDoubleSync(CrossIsolateKV.activeTrackPaceSecKm);

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
    unawaited(_markForegroundAlive());
    // This isolate gets a fresh PersistentNotifications instance — initialize
    // with a no-op tap callback (the MAIN isolate's init owns tap routing).
    await PersistentNotifications.instance.init(onTap: (_) {});
    await headlessStepSync();
    await _scheduleFinalSync();
    await _refreshAll(force: true);
    // 30s heartbeat exists SOLELY to re-issue the secondary battle /
    // track notifications quickly if the user swipe-dismisses them
    // (the FGS summary self-heals through `onNotificationDismissed`
    // and doesn't need this). Gate the poll on whether either
    // secondary is currently posted — when the user has no active
    // battle and no live Track session, this is pure waste and the
    // 5-minute `onRepeatEvent` is the right cadence for the summary.
    //
    // Before this gate, the timer fired ~6 Supabase reads/minute
    // for every signed-in Android user regardless of state; now
    // idle sessions do zero periodic reads from this timer.
    _notifTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final pn = PersistentNotifications.instance;
      if (!pn.isBattlePosted && !pn.isTrackPosted) return;
      _refreshAll(force: true);
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_markForegroundAlive());
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

  /// Force-restart the foreground service. Used by the "Live tracking
  /// paused" banner on Home when the FGS heartbeat has gone stale.
  ///
  /// The regular [startService] early-returns when
  /// `FlutterForegroundTask.isRunningService` is true — which reflects
  /// the plugin's INTERNAL record of "we called startService and
  /// haven't called stopService," NOT whether the service is actually
  /// ticking. When Doze / OEM battery-savers / an isolate crash have
  /// silently killed the service's periodic callback, isRunningService
  /// stays true, [startService] no-ops, and the Resume button becomes
  /// a dead click. This method bypasses the guard: it stops
  /// unconditionally (wrapped in try/catch — "not running" throws) and
  /// starts fresh.
  static Future<void> restartService() async {
    if (!_supported) return;
    try {
      // Stop unconditionally. If it wasn't actually running, this
      // throws harmlessly — the try/catch above swallows it.
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
      // Give the plugin's internal state a beat to settle so the
      // subsequent startService doesn't collide with the shutdown.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Start fresh — call the plugin directly so we're not stopped by
      // startService()'s "already running" guard (which may still be
      // stuck at true after the stop above, depending on plugin
      // version).
      await FlutterForegroundTask.startService(
        serviceId: _foregroundServiceId,
        notificationTitle: 'StepBattle',
        notificationText: 'Tracking your steps',
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.stepbattle.notification.icon',
        ),
        callback: foregroundTaskStartCallback,
      );
      AppLogger.battle.i('backgroundSync:fgServiceRestarted');
    } catch (e, s) {
      AppLogger.battle.e('backgroundSync:fgServiceRestartFailed',
          error: e, stack: s);
    }
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
