import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';

/// Result payload from [ReferralService.redeem]. Mirrors the JSON
/// returned by the `redeem_referral` SECURITY DEFINER RPC.
class ReferralRedeemResult {
  final bool ok;
  /// Reason string on failure. Known values:
  ///   * `code_not_found`   — user_code doesn't match anyone
  ///   * `self_referral`    — user tried to enter their own code
  ///   * `already_redeemed` — user already redeemed a code once
  ///   * `network`          — client-side transport failure
  ///   * `server_error`     — unexpected RPC failure
  final String? reason;

  const ReferralRedeemResult._({required this.ok, this.reason});

  factory ReferralRedeemResult.success() =>
      const ReferralRedeemResult._(ok: true);
  factory ReferralRedeemResult.failure(String reason) =>
      ReferralRedeemResult._(ok: false, reason: reason);

  /// User-facing message. Keep short — the sheet shows it inline.
  String get userMessage {
    if (ok) {
      return "Referral saved! You'll receive 50 XP and your friend will "
          "receive 100 XP once you've completed 500 steps and been on "
          "the app for 24 hours.";
    }
    return switch (reason) {
      'code_not_found' => "We couldn't find a user with that code. Check "
          "the code and try again.",
      'self_referral' => "You can't use your own referral code.",
      'already_redeemed' => "You've already redeemed a referral code.",
      'network' =>
        "Couldn't reach the server. Check your connection and try again.",
      _ =>
        "Something went wrong on our end. Please try again in a moment.",
    };
  }
}

/// Client-side wrapper for the referral RPCs. Never touches XP directly
/// — all reward crediting happens server-side in
/// `qualify_pending_referrals` (delayed until the referee has completed
/// 500 steps AND been on the app for 24 hours).
class ReferralService {
  final SupabaseClient _supabase;
  ReferralService(this._supabase);

  /// Redeem a referral code for the currently-signed-in user. The RPC
  /// enforces: authenticated caller, code exists, no self-referral,
  /// referee hasn't redeemed before.
  ///
  /// On success the referee's `profiles.referred_by` is set and a
  /// `referral_events` row is inserted with status='pending'. Actual
  /// XP crediting happens later via `qualify_pending_referrals` once
  /// the anti-fraud conditions are met.
  Future<ReferralRedeemResult> redeem(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      return ReferralRedeemResult.failure('code_not_found');
    }
    try {
      final res = await _supabase.rpc(
        'redeem_referral',
        params: {'p_code': trimmed},
      );
      final map = res as Map<String, dynamic>?;
      final ok = (map?['ok'] as bool?) ?? false;
      final reason = map?['reason'] as String?;
      AppLogger.auth.i('referral:redeem',
          fields: {'code': trimmed, 'ok': ok, 'reason': reason});
      return ok
          ? ReferralRedeemResult.success()
          : ReferralRedeemResult.failure(reason ?? 'server_error');
    } catch (e, s) {
      AppLogger.auth.e('referral:redeem_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      // Best-effort network classifier — if the string looks like a
      // socket failure, surface the network reason so the UI shows
      // the "check your connection" copy.
      final msg = e.toString().toLowerCase();
      final looksNetwork = msg.contains('socket') ||
          msg.contains('failed host lookup') ||
          msg.contains('network');
      return ReferralRedeemResult.failure(
          looksNetwork ? 'network' : 'server_error');
    }
  }

  /// Fire-and-forget: nudge the server to check whether any of the
  /// current user's pending referrals now qualify (referee walked 500+
  /// steps AND is 24h+ old). Idempotent — safe to call on every Home
  /// open. Errors are swallowed; the cron will pick things up next
  /// hour anyway.
  Future<void> nudgeQualification() async {
    try {
      await _supabase.rpc('qualify_pending_referrals');
    } catch (e) {
      AppLogger.auth
          .w('referral:qualify_nudge_failed', fields: {'err': e.toString()});
    }
  }
}
