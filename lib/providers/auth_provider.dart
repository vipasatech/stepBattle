import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_model.dart';
import '../services/supabase_auth_service.dart';

/// Singleton Supabase-backed auth service.
final authServiceProvider = Provider<SupabaseAuthService>((ref) {
  return SupabaseAuthService();
});

/// Stream of the Supabase auth user (or null when signed out).
///
/// `onAuthStateChange` emits an initial `AuthChangeEvent.initialSession`
/// snapshot when first listened, so consumers get the cached session
/// without a manual seed. We map down to the underlying [User] and
/// dedupe so identical-id ticks (e.g. token refresh) don't churn the UI.
final authStateProvider = StreamProvider<User?>((ref) {
  return ref
      .watch(authServiceProvider)
      .authStateChanges()
      .map((state) => state.session?.user)
      .distinct((a, b) => a?.id == b?.id);
});

/// Per-session flag: has the user been asked to set a preferred name
/// during the current sign-in session?
///
/// We watch the signed-in user id so the flag auto-resets whenever
/// the user changes (sign-in, sign-out, sign-in-as-someone-else) —
/// meaning every login starts with the flag `false`. The flag is
/// flipped `true` when the user submits onboarding, so a subsequent
/// redirect pass doesn't send them back through the same screen in
/// an infinite loop.
///
/// Note: this only persists in memory. An app kill / cold restart
/// resets the flag, so a signed-in user who quits the app WILL be
/// prompted again on next launch until they enter a preferred name.
/// That matches the user's spec ("for every login if preferred name
/// didn't given we should ask") — cold restart with a saved session
/// is effectively "logging in again."
final preferredNameAskedThisSessionProvider = StateProvider<bool>((ref) {
  // Rebuild whenever the signed-in user id changes so the flag
  // resets on sign-in / sign-out.
  ref.watch(authStateProvider.select((s) => s.valueOrNull?.id));
  return false;
});

/// Whether the current user has completed onboarding.
///
/// A user is "onboarded" when the core survey is present:
///   • `display_name` non-empty
///   • `date_of_birth`, `gender`, `fitness_level` all present
///
/// `preferred_name` gets a second-chance rule: if it's still NULL AND
/// we haven't asked in this session, the user is treated as NOT
/// onboarded so the redirect gate sends them back to the onboarding
/// screen (which lands on the preferred-name step because everything
/// else is already answered). Once they submit onboarding
/// [preferredNameAskedThisSessionProvider] flips to true and this
/// provider returns true even with a null preferred_name, breaking
/// the same-session redirect loop. Next login resets the flag and we
/// ask again.
final hasCompletedOnboardingProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return false;
  final profile = await ref.read(authServiceProvider).getProfile(user.id);
  if (profile == null) return false;
  final coreDone = profile.displayName.isNotEmpty &&
      profile.dateOfBirth != null &&
      profile.gender != null &&
      profile.fitnessLevel != null;
  if (!coreDone) return false;
  if (profile.preferredName != null) return true;
  // Core survey is done, preferred_name is NULL. Escape hatch: if
  // we've asked this session (user tapped Continue on the preferred-
  // name step and moved on), treat them as onboarded so the redirect
  // doesn't loop. Otherwise mark as unonboarded so we ask.
  return ref.watch(preferredNameAskedThisSessionProvider);
});

/// Stream of the current user's profile row from Supabase.
final currentUserProvider = StreamProvider<UserModel?>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value(null);
  return ref.read(authServiceProvider).watchProfile(user.id);
});
