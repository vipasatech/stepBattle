import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_model.dart';
import '../repositories/battle_repository.dart';
import '../repositories/leaderboard_repository.dart';
import '../repositories/mission_repository.dart';
import '../repositories/profile_repository.dart';
import '../utils/app_logger.dart';
import 'alarm_wake_scheduler.dart';
import 'background_sync.dart';
import 'notification_service.dart';
import 'observability_service.dart';

/// Auth service backed by Supabase.
///
/// On Android we use the native Google Sign-In SDK (no browser redirect)
/// because Supabase's hosted OAuth flow opens a Chrome Custom Tab, which is
/// jarring inside a native app. The native flow:
///
///   1. `GoogleSignIn` (with `serverClientId` = the **Web** client ID we
///      configured under Supabase's Google provider) prompts the user and
///      returns an ID token whose `aud` claim is that Web client ID.
///   2. We hand the ID token to `auth.signInWithIdToken(provider: google)`.
///      Supabase validates it against the same Web client ID and issues a
///      session.
///
/// On iOS we'd configure `clientId` instead of `serverClientId`; the rest
/// of the flow is identical.
class SupabaseAuthService {
  static const String _googleWebClientId =
      '83248241496-dikb87f4jockcn1m2nnvusj90nmuq32h.apps.googleusercontent.com';

  final SupabaseClient _supabase;
  final GoogleSignIn _googleSignIn;

  SupabaseAuthService({
    SupabaseClient? supabase,
    GoogleSignIn? googleSignIn,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _googleSignIn = googleSignIn ??
            GoogleSignIn(
              serverClientId: _googleWebClientId,
              scopes: const ['email', 'profile'],
            );

  // ---------------------------------------------------------------------------
  // Auth state
  // ---------------------------------------------------------------------------

  /// Current Supabase auth user (or null if signed out).
  User? get currentUser => _supabase.auth.currentUser;

  /// Stream of auth state changes — emits on sign-in / sign-out / token refresh.
  Stream<AuthState> authStateChanges() => _supabase.auth.onAuthStateChange;

  // ---------------------------------------------------------------------------
  // Sign in
  // ---------------------------------------------------------------------------

  Future<AuthResponse> signInWithGoogle() async {
    AppLogger.auth.i('signInWithGoogle:start');
    try {
      // Force a clean prompt — leftover Google sessions from earlier
      // Firebase-based signs-ins would otherwise short-circuit the picker.
      await _googleSignIn.signOut();

      final account = await _googleSignIn.signIn();
      if (account == null) {
        AppLogger.auth.w('signInWithGoogle:cancelled');
        throw const _AuthCancelled('Google sign-in cancelled');
      }

      final googleAuth = await account.authentication;
      final idToken = googleAuth.idToken;
      final accessToken = googleAuth.accessToken;
      if (idToken == null) {
        AppLogger.auth.e('signInWithGoogle:noIdToken');
        throw StateError('Google returned no ID token');
      }

      final res = await _supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );

      // Ensure a profile row exists for the returning user. Testers
      // reported: delete account → re-sign in with the same Google
      // account → signup bonus (500 XP) didn't land. Root cause is
      // the `on_auth_user_created` trigger only fires on auth.users
      // INSERT. If the server-side delete removed the profile row
      // but the auth.users row was already re-used (or an admin
      // wipe left it in place), the trigger doesn't refire on the
      // subsequent sign-in, so no profile → no `profiles_signup_grant`
      // trigger → no bonus. Reconciling here fixes both the missing-
      // profile crash on Home AND the missing signup bonus (INSERT
      // fires the trigger, which credits the 500 XP idempotently).
      final signedInUid = res.user?.id;
      if (signedInUid != null && signedInUid.isNotEmpty) {
        await _ensureProfileRow(
          userId: signedInUid,
          email: res.user?.email,
          userMetadata: res.user?.userMetadata,
        );
      }

      AppLogger.auth.i('signInWithGoogle:done', fields: {
        'uid': res.user?.id,
        'email': res.user?.email,
      });
      // Identify + funnel event. `identify` attributes every subsequent
      // event/error to this uid on Sentry and PostHog. `sign_in` fires
      // for both first-time and returning users; `signup` is fired
      // elsewhere when the mandatory-onboarding survey is submitted.
      final uid = res.user?.id;
      if (uid != null && uid.isNotEmpty) {
        await ObservabilityService.identify(uid);
        ObservabilityService.trackEvent('sign_in',
            properties: {'provider': 'google'});
      }
      return res;
    } catch (e, s) {
      if (e is! _AuthCancelled) {
        AppLogger.auth.e('signInWithGoogle:failed', error: e, stack: s);
      }
      rethrow;
    }
  }

  /// Apple sign-in stub. The current Phase-1 cut hasn't wired Sign-In With
  /// Apple to Supabase yet (it needs Apple Developer team config + a
  /// Services ID + a per-project private key uploaded to Supabase). The UI
  /// button only appears on iOS; throw a clear error if it's pressed.
  Future<AuthResponse> signInWithApple() async {
    AppLogger.auth.w('signInWithApple:notImplemented');
    throw UnimplementedError(
        'Apple sign-in is not configured for Supabase yet.');
  }

  // Password-based email signIn/signUp were removed when we moved to
  // fully passwordless (OTP) auth. See `sendEmailOtp` +
  // `verifyEmailOtp` below for the current path. Existing accounts
  // that were created with a password still work through the OTP
  // flow — Supabase accepts an OTP for any email-registered user.

  // ---------------------------------------------------------------------------
  // Passwordless (OTP) email auth
  //
  // Strava-style login/signup: user types email → Supabase emails a
  // 6-digit code → user enters code → session created. Same code path
  // handles both first-time signup AND repeat login — Supabase's
  // `signInWithOtp` will create the auth user if they don't exist, or
  // just re-sign an existing one. The client-side flow uses one screen
  // for each phase (email input + code entry).
  // ---------------------------------------------------------------------------

  /// Send a 6-digit sign-in OTP to [email]. Works for both signup and
  /// login — no branch on our side. Returns silently on success.
  Future<void> sendEmailOtp(String email) async {
    AppLogger.auth.i('sendEmailOtp:start', fields: {'email': email});
    try {
      await _supabase.auth.signInWithOtp(email: email);
      AppLogger.auth.i('sendEmailOtp:done', fields: {'email': email});
    } catch (e, s) {
      AppLogger.auth.e('sendEmailOtp:failed',
          fields: {'email': email}, error: e, stack: s);
      rethrow;
    }
  }

  /// Verify the OTP from [sendEmailOtp]. On success the returned
  /// [AuthResponse] carries an active session and the redirect gate
  /// routes to /onboarding (fresh signup) or /home (returning user).
  Future<AuthResponse> verifyEmailOtp({
    required String email,
    required String otp,
  }) async {
    AppLogger.auth.i('verifyEmailOtp:start', fields: {'email': email});
    try {
      final res = await _supabase.auth.verifyOTP(
        email: email,
        token: otp,
        type: OtpType.email,
      );
      AppLogger.auth
          .i('verifyEmailOtp:done', fields: {'uid': res.user?.id});
      return res;
    } catch (e, s) {
      AppLogger.auth.e('verifyEmailOtp:failed',
          fields: {'email': email}, error: e, stack: s);
      rethrow;
    }
  }

  // Password-reset methods were removed alongside the switch to
  // passwordless OTP auth — there's no password to reset. If we ever
  // add a "change email" flow, `signInWithOtp` on the new address is
  // the replacement.

  /// Reconciles a missing `profiles` row after sign-in. No-op when the
  /// row already exists. When we DO insert (returning-user-with-deleted-
  /// profile case), the `profiles_signup_grant` trigger fires and
  /// idempotently credits the signup bonus (500 XP per migration 0049).
  ///
  /// Safe to call unconditionally on every sign-in — the SELECT is
  /// cheap and the INSERT path only ever runs for the rare re-signup-
  /// after-delete edge case. Failures are non-fatal: the caller still
  /// gets a valid session; the app will retry on the next sign-in.
  Future<void> _ensureProfileRow({
    required String userId,
    String? email,
    Map<String, dynamic>? userMetadata,
  }) async {
    try {
      final existing = await _supabase
          .from('profiles')
          .select('id')
          .eq('id', userId)
          .maybeSingle();
      if (existing != null) return;

      // Profile is missing — recreate it. Values match the shape the
      // `handle_new_user` DB trigger uses so downstream code sees a
      // row indistinguishable from a first-time signup. `on conflict
      // do nothing` in case a concurrent path (auth trigger racing our
      // check) already inserted between the SELECT and this INSERT.
      final displayName = (userMetadata?['name'] ??
              userMetadata?['full_name'] ??
              '') as String?;
      final avatarUrl = userMetadata?['avatar_url'] as String?;
      await _supabase.from('profiles').upsert(
        {
          'id': userId,
          'display_name': displayName ?? '',
          'email': email ?? '',
          if (avatarUrl != null) 'avatar_url': avatarUrl,
        },
        onConflict: 'id',
        ignoreDuplicates: true,
      );
      AppLogger.auth.i('ensureProfileRow:reconciled',
          fields: {'uid': userId});
    } catch (e) {
      // Non-fatal: sign-in already succeeded. If the reconciliation
      // fails (transient network, RLS blip), the user will just see
      // Home render empty until the next sign-in retries.
      AppLogger.auth.w('ensureProfileRow:failed',
          fields: {'uid': userId, 'err': e.toString()});
    }
  }

  Future<void> signOut() async {
    final uid = _supabase.auth.currentUser?.id;
    AppLogger.auth.i('signOut', fields: {'uid': uid});
    // Tear down the always-on foreground service here (not in MainShell.dispose
    // — that fires on any shell unmount, including transient root-route
    // navigations, and would stop the service while the user is still active).
    await BackgroundSync.stopService();
    // Cancel the exact-time alarm wake schedule too — otherwise the
    // signed-out isolate would keep firing headlessStepSync every few
    // hours against a null user session.
    await AlarmWakeScheduler.cancelAll();
    // Cancel the FCM token-refresh listener so it doesn't attempt to
    // write the outgoing user's fcm_token if FCM rotates during the
    // signed-out window. The listener re-arms on the next sign-in.
    await NotificationService().disposeTokenRefreshListener();
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Google sign-out is best-effort; never block Supabase sign-out.
    }
    await _supabase.auth.signOut();
    // Wipe every repository's local cache so the next sign-in on this
    // device (possibly a different account) doesn't briefly paint the
    // previous user's rows before the new ones land.
    await Future.wait([
      ProfileRepository.clearAllCached(),
      MissionRepository.clearAllCached(),
      BattleRepository.clearAllCached(),
      LeaderboardRepository.clearAllCached(),
    ]);
    // Fire sign_out FIRST while identity is still set, so PostHog
    // attributes the event to the user who's actually leaving. Then
    // reset — subsequent events belong to no one (crucial when a device
    // is shared). Swapping the order dropped attribution on the churn
    // event which is exactly the one funnel dashboards want.
    ObservabilityService.trackEvent('sign_out');
    await ObservabilityService.resetIdentity();
  }

  // ---------------------------------------------------------------------------
  // Profile
  // ---------------------------------------------------------------------------

  /// One-shot read of the current user's profile row. Returns null if not
  /// signed in or the row hasn't been created yet (the on_auth_user_created
  /// trigger usually beats us to it, but during early sign-in there's a
  /// small race we tolerate).
  Future<UserModel?> getProfile(String userId) async {
    try {
      // Read from profiles_public — RLS on the underlying profiles
      // table is self-only (Migration 0036 / H3 lockdown), so any
      // cross-user read via `.from('profiles')` returns empty. The
      // public view exposes safe columns (no email/phone/DOB/home
      // coords/fcm_token) and is definer-mode so all rows are visible
      // to any authenticated caller.
      final data = await _supabase
          .from('profiles_public')
          .select()
          .eq('id', userId)
          .maybeSingle();
      if (data == null) {
        AppLogger.auth.w('getProfile:notFound', fields: {'uid': userId});
        return null;
      }
      return UserModel.fromSupabaseRow(data);
    } catch (e, s) {
      AppLogger.auth.e('getProfile:failed',
          fields: {'uid': userId}, error: e, stack: s);
      rethrow;
    }
  }

  /// Live stream of the user's profile row. Used by `currentUserProvider`
  /// so the UI updates whenever XP / level / streak / steps change.
  Stream<UserModel?> watchProfile(String userId) {
    return _supabase
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('id', userId)
        .map((rows) => rows.isEmpty ? null : UserModel.fromSupabaseRow(rows.first));
  }

  // ---------------------------------------------------------------------------
  // Onboarding
  // ---------------------------------------------------------------------------

  /// Fill in the onboarding-collected fields on the profile row (which the
  /// auth trigger already created). We never INSERT — the trigger handles
  /// that — we only UPDATE.
  ///
  /// As of migration 0016 the survey is **mandatory**: every new user
  /// must provide DOB + gender + fitness_level so the personalized step
  /// goal formula has the inputs it needs.
  Future<void> completeOnboarding({
    required String userId,
    required String displayName,
    required int dailyStepGoal,
    required DateTime dateOfBirth,
    required String gender,
    required String fitnessLevel,
    /// `preferred_name` — casual/friendly name shown in place of
    /// `display_name` (see [UserModel.friendlyName]). We persist NULL
    /// when the user tapped Continue with an empty field so we can
    /// distinguish "user has explicitly provided a nickname" from
    /// "user hasn't chosen one yet" and re-prompt them on the next
    /// login. The DB CHECK constraint (char_length BETWEEN 1 AND 40)
    /// passes on NULL — Postgres CHECK is skipped when the expression
    /// is NULL.
    String? preferredName,
    String? avatarUrl,

    /// Seeded battle-ground runner id — computed by the caller from
    /// `Avatar.defaultForUser(gender, fitnessLevel, ageYears)`. Only
    /// written when non-null so an existing user who re-enters
    /// onboarding without a mapped default doesn't wipe out a manual
    /// pick they made from the avatar-picker sheet.
    String? battleAvatarId,
  }) async {
    AppLogger.auth.i('completeOnboarding:start', fields: {
      'uid': userId,
      'displayName': displayName,
      'preferredName': preferredName,
      'gender': gender,
      'fitnessLevel': fitnessLevel,
    });
    try {
      // Generate a unique user code (retry up to 5 times on collision).
      final userCode = await _generateUniqueUserCode();
      // Fetch existing total_xp AND avatar_url:
      //   • total_xp — so we can detect whether the sign-up bonus has
      //     already been paid (re-onboarding must not pay it twice).
      //   • avatar_url — so we can skip writing the Google OAuth
      //     avatar over a photo the user explicitly uploaded via
      //     LocalProfilePhotoService. Testers reported the Google
      //     picture overriding their saved photo on re-login; the
      //     fix is "OAuth avatar is only allowed to LAND on first
      //     setup — never overwrite a value that's already there."
      final existing = await _supabase
          .from('profiles')
          .select('total_xp, avatar_url')
          .eq('id', userId)
          .maybeSingle();
      final currentTotalXp =
          (existing?['total_xp'] as num?)?.toInt() ?? 0;
      final shouldAwardSignUpBonus = currentTotalXp == 0;
      final existingAvatarUrl = existing?['avatar_url'] as String?;
      // Only accept the passed OAuth avatar when the profile has no
      // photo yet. Any prior value (uploaded photo, previously-set
      // Google URL) wins over a fresh onboarding pass.
      final shouldWriteAvatar =
          avatarUrl != null &&
              (existingAvatarUrl == null || existingAvatarUrl.isEmpty);

      await _supabase.from('profiles').update({
        'display_name': displayName,
        // `preferred_name` may be null — pass it through verbatim so
        // we clear the column when the user goes through onboarding
        // again with a cleared field.
        'preferred_name': preferredName,
        'daily_step_goal': dailyStepGoal,
        'user_code': userCode,
        'date_of_birth': dateOfBirth.toIso8601String().split('T').first,
        'gender': gender,
        'fitness_level': fitnessLevel,
        if (shouldWriteAvatar) 'avatar_url': avatarUrl,
        if (battleAvatarId != null) 'battle_avatar_id': battleAvatarId,
      }).eq('id', userId);

      if (avatarUrl != null && !shouldWriteAvatar) {
        AppLogger.auth.i('completeOnboarding:avatarPreserved',
            fields: {'uid': userId, 'kept': existingAvatarUrl});
      }

      // Sign-up bonus — call the server RPC (migration 0055). Prior to
      // 0055 the grant relied solely on the `grant_signup_xp` trigger
      // on `profiles` INSERT (migration 0020), which:
      //   • hard-coded 100 XP (client constant is 500), and
      //   • didn't fire when the profile row pre-existed migration
      //     0020, leaving those users at 0 XP forever with no retry.
      // `award_signup_bonus_v2()` is idempotent (guards on
      // xp_ledger.reason='signup_grant') and returns the amount
      // ACTUALLY credited: 500 on first call for this user, 0 if the
      // bonus was already granted. We log what the server tells us —
      // the previous log line asserted "granted" based on nothing but
      // a client-side pre-read of total_xp==0, which meant the log
      // was cheerfully lying every time the trigger silently skipped.
      //
      // Failure is non-fatal: onboarding must still complete even if
      // the bonus call errors (network / RLS glitch). The next foreground
      // open re-reads the profile via realtime; the bonus can be
      // re-attempted from a settings entry or the next mission flow.
      if (shouldAwardSignUpBonus) {
        try {
          final credited = await _supabase.rpc('award_signup_bonus_v2');
          final creditedInt = (credited as num?)?.toInt() ?? 0;
          // Routed to AppLogger.xp (was auth) so signup bonus credits
          // show up under the Diagnostics "xp" filter — the same tab
          // testers use to watch battle-win / mission / streak XP land.
          if (creditedInt > 0) {
            AppLogger.xp.i('signupBonus:credited',
                fields: {'uid': userId, 'xp': creditedInt});
          } else {
            AppLogger.xp.i('signupBonus:alreadyGranted',
                fields: {'uid': userId});
          }
          // Re-read total_xp so the log tells us the true post-credit
          // balance — if credited=500 but total_xp still shows 0, we've
          // caught a silent RLS / trigger failure that would otherwise
          // hide behind the RPC's optimistic return value.
          final verify = await _supabase
              .from('profiles')
              .select('total_xp')
              .eq('id', userId)
              .maybeSingle();
          final postXp = (verify?['total_xp'] as num?)?.toInt() ?? 0;
          AppLogger.xp.i('signupBonus:xpVerified',
              fields: {'uid': userId, 'totalXp': postXp});
        } catch (e, s) {
          AppLogger.xp.w('signupBonus:rpcFailed',
              fields: {'uid': userId, 'err': e.toString()});
          // Suppress the stack in fields to keep the log line small,
          // but attach via error/stack so DevTools + Sentry keep it.
          AppLogger.xp.e('signupBonus:rpcFailed_stack',
              fields: {'uid': userId}, error: e, stack: s);
        }
      }

      AppLogger.auth.i('completeOnboarding:done',
          fields: {'uid': userId, 'userCode': userCode});
    } catch (e, s) {
      AppLogger.auth.e('completeOnboarding:failed',
          fields: {'uid': userId}, error: e, stack: s);
      rethrow;
    }
  }

  /// Update only the user's selected battle-ground avatar (migration
  /// 0019). The id is one of the catalog strings ('avatar_01' …
  /// 'avatar_12'); we don't validate the value here because the catalog
  /// is closed and the picker UI only ever passes a known id.
  Future<void> updateBattleAvatar({
    required String userId,
    required String avatarId,
  }) async {
    try {
      await _supabase
          .from('profiles')
          .update({'battle_avatar_id': avatarId}).eq('id', userId);
      AppLogger.auth
          .i('updateBattleAvatar', fields: {'uid': userId, 'id': avatarId});
    } catch (e, s) {
      AppLogger.auth.e('updateBattleAvatar:failed',
          fields: {'uid': userId, 'id': avatarId}, error: e, stack: s);
      rethrow;
    }
  }

  // [3D-DISABLED-2026-08-21] — updateCharacter3D commented out. The
  // profiles.character_3d_id DB column is preserved; the only caller was
  // the picker sheet in lib/sheets/character_3d_picker_sheet.dart (also
  // disabled). See lib/models/character_3d.dart header for re-enable.
  //
  // /// Update the user's selected 3D character (migration 0027). Id is one
  // /// of `Character3D.catalog` — currently 'women' or 'men'. Passing
  // /// `null` clears the column and lets the client fall back to the
  // /// gender-based default.
  // Future<void> updateCharacter3D({
  //   required String userId,
  //   required String? characterId,
  // }) async {
  //   try {
  //     await _supabase
  //         .from('profiles')
  //         .update({'character_3d_id': characterId}).eq('id', userId);
  //     AppLogger.auth.i('updateCharacter3D',
  //         fields: {'uid': userId, 'id': characterId});
  //     // Analytics: only send the character id — user id is threaded via
  //     // Sentry/PostHog identify(), not per-event, so we don't double up.
  //     ObservabilityService.trackEvent('avatar_pick',
  //         properties: {'character_id': characterId ?? 'cleared'});
  //   } catch (e, s) {
  //     AppLogger.auth.e('updateCharacter3D:failed',
  //         fields: {'uid': userId, 'id': characterId}, error: e, stack: s);
  //     rethrow;
  //   }
  // }

  /// Legacy — persists the character-avatar spec column from migration
  /// 0026. Kept for API compatibility even though the fluttermoji
  /// customizer was removed from the app. Nothing in the current UI
  /// calls this.
  Future<void> updateAvatarConfig({
    required String userId,
    required Map<String, dynamic>? config,
  }) async {
    try {
      await _supabase
          .from('profiles')
          .update({'avatar_config': config}).eq('id', userId);
      AppLogger.auth.i('updateAvatarConfig', fields: {
        'uid': userId,
        'set': config != null,
      });
    } catch (e, s) {
      AppLogger.auth.e('updateAvatarConfig:failed',
          fields: {'uid': userId}, error: e, stack: s);
      rethrow;
    }
  }

  /// Update only the survey-derived profile fields (DOB / gender /
  /// fitness level). Used by the "Complete your profile" sheet for
  /// pre-survey users who already have a display_name and goal set —
  /// we don't want to overwrite their existing user_code or goal here.
  Future<void> updateSurveyFields({
    required String userId,
    required DateTime dateOfBirth,
    required String gender,
    required String fitnessLevel,
    String? preferredName,
    int? heightCm,
    double? weightKg,
  }) async {
    AppLogger.auth.i('updateSurveyFields:start', fields: {
      'uid': userId,
      'gender': gender,
      'fitnessLevel': fitnessLevel,
      'preferredNameSet': preferredName != null,
      'heightSet': heightCm != null,
      'weightSet': weightKg != null,
    });
    try {
      // Empty string collapses to null so the CHECK constraint on
      // preferred_name (1..40 chars) can't reject a blank save.
      final trimmed = preferredName?.trim();
      final nameForDb = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
      await _supabase.from('profiles').update({
        'date_of_birth': dateOfBirth.toIso8601String().split('T').first,
        'gender': gender,
        'fitness_level': fitnessLevel,
        'preferred_name': nameForDb,
        // Height / weight are optional; null-passthrough lets the user
        // clear the fields if they want (empty numeric input → null).
        'height_cm': heightCm,
        'weight_kg': weightKg,
      }).eq('id', userId);
      AppLogger.auth
          .i('updateSurveyFields:done', fields: {'uid': userId});
    } catch (e, s) {
      AppLogger.auth.e('updateSurveyFields:failed',
          fields: {'uid': userId}, error: e, stack: s);
      rethrow;
    }
  }

  /// Update arbitrary profile fields. Caller passes already-snake_cased keys.
  Future<void> updateProfile(
      String userId, Map<String, dynamic> changes) async {
    try {
      await _supabase.from('profiles').update(changes).eq('id', userId);
    } catch (e, s) {
      AppLogger.auth.e('updateProfile:failed',
          fields: {'uid': userId, 'keys': changes.keys.toList()},
          error: e,
          stack: s);
      rethrow;
    }
  }

  Future<String> _generateUniqueUserCode() async {
    for (var i = 0; i < 5; i++) {
      final code = UserModel.generateUserCode();
      final existing = await _supabase
          .from('profiles')
          .select('id')
          .eq('user_code', code)
          .limit(1)
          .maybeSingle();
      if (existing == null) return code;
    }
    // Extremely unlikely — fall back to timestamp.
    return '#${DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase().substring(0, 5)}';
  }
}

class _AuthCancelled implements Exception {
  final String message;
  const _AuthCancelled(this.message);
  @override
  String toString() => message;
}
