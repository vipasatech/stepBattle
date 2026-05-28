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

/// Whether the current user has completed onboarding.
/// We treat "has display_name set" as the signal — the auth trigger creates
/// the profile row with an empty display_name; onboarding fills it in.
final hasCompletedOnboardingProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return false;
  final profile = await ref.read(authServiceProvider).getProfile(user.id);
  return profile != null && profile.displayName.isNotEmpty;
});

/// Stream of the current user's profile row from Supabase.
final currentUserProvider = StreamProvider<UserModel?>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value(null);
  return ref.read(authServiceProvider).watchProfile(user.id);
});
