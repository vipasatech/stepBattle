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

  Future<AuthResponse> signInWithEmail(String email, String password) async {
    AppLogger.auth.i('signInWithEmail:start', fields: {'email': email});
    try {
      final res = await _supabase.auth
          .signInWithPassword(email: email, password: password);
      AppLogger.auth.i('signInWithEmail:done', fields: {'uid': res.user?.id});
      return res;
    } catch (e, s) {
      AppLogger.auth.e('signInWithEmail:failed',
          fields: {'email': email}, error: e, stack: s);
      rethrow;
    }
  }

  Future<AuthResponse> signUpWithEmail(String email, String password) async {
    AppLogger.auth.i('signUpWithEmail:start', fields: {'email': email});
    try {
      final res = await _supabase.auth.signUp(email: email, password: password);
      AppLogger.auth.i('signUpWithEmail:done', fields: {'uid': res.user?.id});
      return res;
    } catch (e, s) {
      AppLogger.auth.e('signUpWithEmail:failed',
          fields: {'email': email}, error: e, stack: s);
      rethrow;
    }
  }

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
    String? avatarUrl,
  }) async {
    AppLogger.auth.i('completeOnboarding:start', fields: {
      'uid': userId,
      'displayName': displayName,
      'gender': gender,
      'fitnessLevel': fitnessLevel,
    });
    try {
      // Generate a unique user code (retry up to 5 times on collision).
      final userCode = await _generateUniqueUserCode();
      await _supabase.from('profiles').update({
        'display_name': displayName,
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

  /// Update only the survey-derived profile fields (DOB / gender /
  /// fitness level). Used by the "Complete your profile" sheet for
  /// pre-survey users who already have a display_name and goal set —
  /// we don't want to overwrite their existing user_code or goal here.
  Future<void> updateSurveyFields({
    required String userId,
    required DateTime dateOfBirth,
    required String gender,
    required String fitnessLevel,
  }) async {
    AppLogger.auth.i('updateSurveyFields:start', fields: {
      'uid': userId,
      'gender': gender,
      'fitnessLevel': fitnessLevel,
    });
    try {
      await _supabase.from('profiles').update({
        'date_of_birth': dateOfBirth.toIso8601String().split('T').first,
        'gender': gender,
        'fitness_level': fitnessLevel,
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
