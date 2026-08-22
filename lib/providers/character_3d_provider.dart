import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/character_3d.dart';
import '../models/user_model.dart';
import 'auth_provider.dart';
import 'user_provider.dart';

/// Resolved 3D character for the current user, in this order of preference:
///   1. Explicit pick in `profiles.character_3d_id` (migration 0027).
///   2. Gender-based default via [Character3D.defaultForGender] on the
///      onboarding-survey gender field.
///   3. [Character3D.amy] as the ultimate fallback for pre-survey / null
///      profiles.
///
/// The picker writes the id via [SupabaseAuthService.updateCharacter3D];
/// the invalidated [currentUserProvider] then triggers a rebuild of any
/// UI watching this provider. Server-backed means opponents see the same
/// value we do — that's how the arena band renders their character.
final currentCharacter3DProvider = Provider<Character3D>((ref) {
  final user = ref.watch(userProfileProvider).valueOrNull;
  if (user == null) return Character3D.amy;
  if (user.character3dId != null) {
    return Character3D.byId(user.character3dId);
  }
  return Character3D.defaultForGender(user.gender);
});

/// Same resolver but parameterised by another user's [UserModel]. Used by
/// the arena band to render the opponent's character. Passing `null` (no
/// profile fetched yet) yields the default female fallback.
Character3D character3DForUser(UserModel? user) {
  if (user == null) return Character3D.amy;
  if (user.character3dId != null) {
    return Character3D.byId(user.character3dId);
  }
  return Character3D.defaultForGender(user.gender);
}

/// Fetches another user's picked 3D character by userId. Used by the arena
/// band so the opponent's chip mirrors their own picker choice. Falls back
/// through the same order as [currentCharacter3DProvider] on lookup miss /
/// fetch failure — you always get a valid character, never a spinner.
final character3DForUserIdProvider =
    FutureProvider.autoDispose.family<Character3D, String>((ref, userId) async {
  try {
    final repo = ref.read(profileRepositoryProvider);
    // Try cache first — if we've ever fetched this opponent's profile
    // (they're in one of our recent battles) the arena chip renders on
    // the very next frame instead of after a round-trip.
    final cached = repo.readCached(userId);
    if (cached != null) return character3DForUser(cached);
    final profile = await repo.fetch(userId);
    return character3DForUser(profile);
  } catch (_) {
    return Character3D.amy;
  }
});
