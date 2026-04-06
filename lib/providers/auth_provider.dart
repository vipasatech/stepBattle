import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';

/// Singleton auth service instance.
final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});

/// Stream of Firebase auth state (signed in / signed out).
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authStateChanges();
});

/// Whether the current user has completed onboarding (Firestore doc exists).
final hasCompletedOnboardingProvider = FutureProvider<bool>((ref) async {
  final authState = ref.watch(authStateProvider);
  final user = authState.valueOrNull;
  if (user == null) return false;
  return ref.read(authServiceProvider).userDocExists(user.uid);
});

/// Stream of the current user's Firestore profile.
final currentUserProvider = StreamProvider<UserModel?>((ref) {
  final authState = ref.watch(authStateProvider);
  final user = authState.valueOrNull;
  if (user == null) return Stream.value(null);
  return ref.read(authServiceProvider).watchUser(user.uid);
});
