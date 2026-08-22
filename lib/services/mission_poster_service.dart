import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_logger.dart';

/// Device-local dismissal tracking for mission posters.
///
/// When a mission has an admin-uploaded `poster_url`, the client shows
/// a full-screen popup on cold-start and every foreground resume until
/// the user taps [X]. That dismissal is stored HERE — one boolean per
/// mission id, in SharedPreferences.
///
/// Local by design: reinstalling the app or switching devices RE-shows
/// the poster once. For a campaign-scoped mission that's mostly a
/// non-event (the admin will retire the mission after the campaign).
/// If we ever want cross-device sync, add a
/// `user_mission_poster_dismissals` table server-side and mirror both
/// paths — client can then check server first, fall back to local.
class MissionPosterService {
  MissionPosterService._();

  static const _prefix = 'mission_poster_dismissed_';

  /// True when the user has already tapped [X] on this mission's
  /// poster on this device. Safe to call from any surface — hits
  /// SharedPreferences (in-memory after first load).
  static Future<bool> isDismissed(String missionId) async {
    if (missionId.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('$_prefix$missionId') ?? false;
    } catch (e) {
      // Prefs load can fail on cold start on very old Androids; treat
      // as "not dismissed" to be safe — user can dismiss again.
      AppLogger.mission.w('poster.isDismissed:failed',
          fields: {'missionId': missionId, 'err': e.toString()});
      return false;
    }
  }

  /// Persist that the user closed this poster. Idempotent.
  static Future<void> markDismissed(String missionId) async {
    if (missionId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_prefix$missionId', true);
      AppLogger.mission
          .i('poster.dismissed', fields: {'missionId': missionId});
    } catch (e) {
      AppLogger.mission.e('poster.markDismissed:failed',
          fields: {'missionId': missionId, 'err': e.toString()});
    }
  }

  /// Testing hook — wipe all poster-dismissal flags. Not called from
  /// prod paths (dismissals are meant to be permanent per install).
  static Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
