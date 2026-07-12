import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_model.dart';
import '../utils/app_logger.dart';
import 'background_sync.dart';

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

      AppLogger.auth.i('signInWithGoogle:done', fields: {
        'uid': res.user?.id,
        'email': res.user?.email,
      });
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

  Future<void> signOut() async {
    final uid = _supabase.auth.currentUser?.id;
    AppLogger.auth.i('signOut', fields: {'uid': uid});
    // Tear down the always-on foreground service here (not in MainShell.dispose
    // — that fires on any shell unmount, including transient root-route
    // navigations, and would stop the service while the user is still active).
    await BackgroundSync.stopService();
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Google sign-out is best-effort; never block Supabase sign-out.
    }
    await _supabase.auth.signOut();
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
      final data = await _supabase
          .from('profiles')
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
        if (avatarUrl != null) 'avatar_url': avatarUrl,
      }).eq('id', userId);
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

  /// Update the user's selected 3D character (migration 0027). Id is one
  /// of `Character3D.catalog` — currently 'women' or 'men'. Passing
  /// `null` clears the column and lets the client fall back to the
  /// gender-based default.
  Future<void> updateCharacter3D({
    required String userId,
    required String? characterId,
  }) async {
    try {
      await _supabase
          .from('profiles')
          .update({'character_3d_id': characterId}).eq('id', userId);
      AppLogger.auth.i('updateCharacter3D',
          fields: {'uid': userId, 'id': characterId});
    } catch (e, s) {
      AppLogger.auth.e('updateCharacter3D:failed',
          fields: {'uid': userId, 'id': characterId}, error: e, stack: s);
      rethrow;
    }
  }

  /// Persist the fluttermoji character-avatar spec (see migration 0026
  /// and [UserModel.avatarConfig]). Passing `null` clears the column,
  /// which reverts the client to the URL-based [UserModel.avatarURL]
  /// fallback.
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
