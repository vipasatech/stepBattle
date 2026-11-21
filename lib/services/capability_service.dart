import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';

import '../utils/app_logger.dart';
import '../utils/cross_isolate_kv.dart';
import '../utils/step_permission.dart';
import 'google_fit_service.dart';
import 'health_service.dart';
import 'native_step_service.dart';
import 'step_source_aggregator.dart';

/// Whether the lock-based permission model is active on this platform.
///
/// Enabled on both platforms as of 2026-11-21, after the model was proven
/// on iPhone through builds 1.1.7+44 to +47.
///
/// Turning it on retires three separate pieces of the old model at once:
/// the two mandatory permission pages in onboarding, [NoSourceGate]'s
/// unescapable "Set up" dialog, and PermissionGate's "Almost Ready!"
/// primer. All three interrupted the user to ask for something before
/// they had any reason to care; the locks ask in context, on the metric
/// each permission unlocks.
///
/// What does NOT change on Android: steps still unlock on ANY single
/// source. The "require Motion AND Health" rule is iOS-only, because
/// Apple Health is always present on an iPhone and the device populates
/// it unprompted, whereas plenty of Android phones have no step-source
/// app feeding Health Connect at all. Requiring it there would lock out
/// working installs.
///
/// Kept as a flag rather than deleted so the old paths can be restored
/// in one edit if this turns out badly for the ~140 existing Android
/// users. Delete both the flag and the dead branches once it has a
/// release behind it.
class CapabilityLocks {
  CapabilityLocks._();

  static bool get enabled => true;
}

/// A thing the user can't see or do until the OS grants us something.
enum AppCapability {
  /// Reading the step count. Powers Home's metrics, streaks, battles,
  /// missions, leaderboards — essentially the whole app.
  steps,

  /// Push + local notifications. Battle invites, streak-at-risk warnings.
  notifications,

  /// Foreground location. Track sessions and the home-city lookup.
  location,
}

/// What happened when the user tapped a lock.
enum LockOutcome {
  /// The capability is now available — swap the lock for the real value.
  unlocked,

  /// We asked and were refused, but can ask again later.
  refused,

  /// The OS will not prompt again, so we sent the user to Settings.
  sentToSettings,
}

/// Decides whether a metric is readable, and resolves it when it isn't.
///
/// The central idea: **locks key on capability, not on permission.**
///
/// Steps are the clearest case. Two independent sources can supply them —
/// Apple Health and the native pedometer — and either alone is enough. A
/// lock keyed on "is Motion granted" would sit over a number we can already
/// display from Health. Worse, iOS deliberately refuses to tell us whether
/// HealthKit *read* access was granted, so "permission granted" is not even
/// observable there. What is observable is whether a source answers.
///
/// This is the same availability test [NoSourceGate] settled on after it
/// shipped a version that conflated "no step source" with "you haven't
/// walked yet" and hard-blocked working installs (see its header). Zero
/// steps at 6am is not a locked metric.
class CapabilityService {
  CapabilityService({
    required HealthService health,
    required NativeStepService native,
    required GoogleFitService fit,
    required StepSourceAggregator aggregator,
  })  : _health = health,
        _native = native,
        _fit = fit,
        _aggregator = aggregator;

  final HealthService _health;
  final NativeStepService _native;
  final GoogleFitService _fit;
  final StepSourceAggregator _aggregator;

  /// Hive keys recording that we have already put a prompt on screen.
  ///
  /// Needed because the OS gives us no way back. Once iOS has shown the
  /// HealthKit sheet it never shows it again, and `requestAuthorization`
  /// returns silently — indistinguishable from success. Without a record
  /// of having asked, a lock tap would call a no-op request forever and
  /// look broken. With it, the second tap goes to Settings.
  /// Set the first time HealthKit / Health Connect returns a non-zero
  /// count. On iOS this is the ONLY evidence we can ever get that Health
  /// access was granted — `hasPermissions()` reports false there whether
  /// the user allowed or denied, because telling an app it was denied is
  /// itself a disclosure about the user. Data arriving is proof; nothing
  /// else is.
  static const _healthDataSeenKey = 'cap_health_data_seen';

  static const _askedStepsKey = 'cap_asked_steps';

  /// Separate from [_askedStepsKey] on purpose. Steps need two prompts on
  /// iOS — Motion, then Health — and one shared flag meant asking for the
  /// first marked the second as asked, so the Health sheet could never
  /// appear on a later lock tap.
  static const _askedHealthKey = 'cap_asked_health';
  static const _askedNotificationsKey = 'cap_asked_notifications';
  static const _askedLocationKey = 'cap_asked_location';

  static String _askedKey(AppCapability c) => switch (c) {
        AppCapability.steps => _askedStepsKey,
        AppCapability.notifications => _askedNotificationsKey,
        AppCapability.location => _askedLocationKey,
      };

  bool _hasAsked(AppCapability c) =>
      CrossIsolateKV.getBoolSync(_askedKey(c)) ?? false;

  Future<void> _markAsked(AppCapability c) =>
      CrossIsolateKV.setBool(_askedKey(c), true);

  // ---------------------------------------------------------------------
  // Availability
  // ---------------------------------------------------------------------

  Future<bool> isUnlocked(AppCapability capability) async {
    switch (capability) {
      case AppCapability.steps:
        return _stepsAvailable();
      case AppCapability.notifications:
        return Permission.notification.isGranted;
      case AppCapability.location:
        return Permission.locationWhenInUse.isGranted;
    }
  }

  /// True when we can show a step count.
  ///
  /// Order matters here, and the first rule is the one that was missing in
  /// the first cut (2026-11-20): **data beats every probe.**
  ///
  /// That version asked `health.hasPermissions()` and trusted the answer.
  /// On iOS that call reports false whether or not access was granted —
  /// Apple deliberately hides HealthKit *read* status, because telling an
  /// app "you were denied" is itself a disclosure about the user. So an
  /// iPhone happily feeding us 3,545 steps was reported as having no step
  /// source, and the hero showed a padlock directly above a mission card
  /// counting those same steps.
  ///
  /// The lesson is the one this class's own header claims: key on the
  /// capability, not the permission. A number on screen IS the capability.
  Future<bool> _stepsAvailable() async {
    try {
      final reading = await _aggregator.readWithDebug();

      // Record Health evidence whenever we see it. Once true this stays
      // true — a user who grants Health and then walks zero steps the
      // next day has not revoked anything.
      if (reading.healthConnectSteps > 0 &&
          !(CrossIsolateKV.getBoolSync(_healthDataSeenKey) ?? false)) {
        await CrossIsolateKV.setBool(_healthDataSeenKey, true);
      }

      if (Platform.isIOS) {
        // iOS requires BOTH sources (product decision, 2026-11-21).
        //
        // Apple Health is always present on an iPhone and the device
        // writes steps into it unprompted, so unlike Android there is no
        // "user has no step-source app" case to accommodate — asking for
        // both is reasonable here in a way it would not be there.
        //
        // The Health half cannot be checked directly: `hasPermissions()`
        // is false on iOS whether access was granted or denied. Data
        // having arrived is the only proof available, so that is what we
        // use. A denial therefore keeps the lock on, which is the point.
        final motionGranted = await stepPermission.isGranted;
        final healthEvidence = reading.healthConnectSteps > 0 ||
            (CrossIsolateKV.getBoolSync(_healthDataSeenKey) ?? false);
        return motionGranted && healthEvidence;
      }

      // Android: any single source is enough. Health Connect is optional
      // there and plenty of devices have no step-source app feeding it,
      // so requiring it would lock out working installs.

      // 1. Any source produced a count — we can display a number.
      if (reading.aggregate > 0 ||
          reading.healthConnectSteps > 0 ||
          reading.nativeSteps > 0) {
        return true;
      }

      // Zero steps is legitimate for part of every single day (the gate
      // this replaces once hard-blocked working installs over exactly
      // that), so fall through to asking whether a source COULD answer.
      if (await stepPermission.isGranted) return true;
      if (await _health.hasPermissions()) return true;

      // The pedometer stream has actually emitted. Deliberately NOT
      // `nativeError == null`: a stream that never started reports no
      // error either, which would make this always true and the lock
      // would never appear at all.
      if (_native.isAvailable) return true;

      if (_fit.isEnabled && reading.googleFitSteps != null) return true;

      return false;
    } catch (e) {
      AppLogger.step.w('capability:stepsProbeFailed', fields: {
        'err': e.toString(),
      });
      // Fail open. A probe that throws is our problem, not the user's, and
      // showing a lock over a working metric is worse than the reverse.
      return true;
    }
  }

  // ---------------------------------------------------------------------
  // Resolution — what a lock tap does
  // ---------------------------------------------------------------------

  /// Request whatever [capability] needs. Returns what the user should see
  /// next. Callers open Settings themselves on [LockOutcome.sentToSettings]
  /// so the navigation stays in the widget layer.
  Future<LockOutcome> resolve(AppCapability capability) async {
    AppLogger.permission.i('capability:resolve', fields: {
      'capability': capability.name,
      'askedBefore': _hasAsked(capability),
    });

    final outcome = switch (capability) {
      AppCapability.steps => await _resolveSteps(),
      AppCapability.notifications => await _resolveNotifications(),
      AppCapability.location => await _resolveLocation(),
    };

    AppLogger.permission.i('capability:resolved', fields: {
      'capability': capability.name,
      'outcome': outcome.name,
    });
    return outcome;
  }

  /// Walks the prompts steps needs, cheapest first, stopping as soon as
  /// the metric is readable.
  ///
  /// Motion is a plain system alert answered without leaving the app.
  /// HealthKit is a full-screen sheet with per-type toggles and, on iOS,
  /// strictly one-shot — once answered it never appears again and
  /// `requestAuthorization` becomes a silent no-op. That one-shot nature
  /// is why [_askedHealthKey] exists: without a record of having asked,
  /// a lock tap would call a no-op forever and look broken.
  Future<LockOutcome> _resolveSteps() async {
    // --- Motion -------------------------------------------------------
    var motion = await stepPermission.status;
    if (!motion.isGranted) {
      if (motion.isPermanentlyDenied) return LockOutcome.sentToSettings;
      motion = await stepPermission.request();
      await _markAsked(AppCapability.steps);
      if (!motion.isGranted) {
        return motion.isPermanentlyDenied
            ? LockOutcome.sentToSettings
            : LockOutcome.refused;
      }
    }

    if (await _stepsAvailable()) return LockOutcome.unlocked;

    // --- Health -------------------------------------------------------
    final askedHealth = CrossIsolateKV.getBoolSync(_askedHealthKey) ?? false;
    if (!askedHealth) {
      await _health.requestPermissions();
      await CrossIsolateKV.setBool(_askedHealthKey, true);
      if (await _stepsAvailable()) return LockOutcome.unlocked;

      // Granted-but-no-data is indistinguishable from denied on iOS, and
      // both land here. Treat it as refused rather than shipping the user
      // to Settings: if they did grant, their first steps of the day
      // resolve it on their own, and a pointless Settings trip for
      // someone who already said yes is the worse outcome.
      return LockOutcome.refused;
    }

    // Asked before and still nothing. The sheet will not reappear, so
    // Settings is the only route left.
    return LockOutcome.sentToSettings;
  }

  /// Notifications are requested at launch by AppDelegate on iOS, so by the
  /// time a lock is tappable the system has usually already asked. That
  /// makes Settings the normal destination here rather than the exception.
  Future<LockOutcome> _resolveNotifications() async {
    final status = await Permission.notification.status;
    if (status.isGranted) return LockOutcome.unlocked;

    if (!status.isPermanentlyDenied && !_hasAsked(AppCapability.notifications)) {
      final result = await Permission.notification.request();
      await _markAsked(AppCapability.notifications);
      if (result.isGranted) return LockOutcome.unlocked;
      if (!result.isPermanentlyDenied) return LockOutcome.refused;
    }
    return LockOutcome.sentToSettings;
  }

  Future<LockOutcome> _resolveLocation() async {
    final status = await Permission.locationWhenInUse.status;
    if (status.isGranted) return LockOutcome.unlocked;

    if (!status.isPermanentlyDenied) {
      final result = await Permission.locationWhenInUse.request();
      await _markAsked(AppCapability.location);
      if (result.isGranted) return LockOutcome.unlocked;
      if (!result.isPermanentlyDenied) return LockOutcome.refused;
    }
    return LockOutcome.sentToSettings;
  }
}
