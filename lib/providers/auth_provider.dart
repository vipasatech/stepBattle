import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_model.dart';
import '../repositories/profile_repository.dart';
import '../services/supabase_auth_service.dart';

/// Singleton Supabase-backed auth service.
final authServiceProvider = Provider<SupabaseAuthService>((ref) {
  return SupabaseAuthService();
});

/// Cache-then-network profile repository. Emits the last-known profile
/// row from Hive on cold boot before Supabase's realtime stream lands.
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository();
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
/// **`preferred_name` is NOT part of this gate.** Previously we treated
/// a null preferred_name as "not onboarded" on every fresh session so
/// we could re-prompt. Testers reported it as a bug: they skipped the
/// nickname step (it's optional), and every subsequent app open forced
/// them back through onboarding starting at the preferred-name page.
/// If the user wants to add / change a nickname later, they do it from
/// Settings → Preferred name.
final hasCompletedOnboardingProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return false;
  // Consume the shared realtime stream instead of issuing a fresh
  // `select().eq().maybeSingle()` — that fetch was firing on every auth
  // tick + every router `refreshListenable` cycle, duplicating work
  // [currentUserProvider] already does. `.future` blocks until the
  // stream produces its first non-null (or null) row, so onboarding
  // status still resolves before the redirect gate runs.
  final profile = await ref.watch(currentUserProvider.future);
  if (profile == null) return false;
  return profile.displayName.isNotEmpty &&
      profile.dateOfBirth != null &&
      profile.gender != null &&
      profile.fitnessLevel != null;
});

/// Stream of the current user's profile row.
///
/// Backed by [ProfileRepository] so the UI paints the Hive-cached row
/// on frame 1 (cold boot) and updates to the live Supabase row as soon
/// as it arrives. See [profileRepositoryProvider].
final currentUserProvider = StreamProvider<UserModel?>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value(null);
  return ref.read(profileRepositoryProvider).watch(user.id);
});
