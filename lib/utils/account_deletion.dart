import 'package:flutter/foundation.dart';

/// Process-lifetime marker for "this device just deleted its account".
///
/// ## Why this exists
///
/// Between a successful `POST /api/user-delete` and `authStateProvider`
/// emitting null, the app sits in a state that is **indistinguishable
/// from a fresh signup** by provider values alone:
///
/// ```
///   authStateProvider           → User(non-null)   // token not cleared yet
///   currentUserProvider         → null             // profile row is gone
///   hasCompletedOnboarding      → false            // derived from the above
/// ```
///
/// A fresh Google signup in that exact state must go to `/onboarding`.
/// A just-deleted account must go to `/welcome`. The router could not
/// tell them apart, so it sent both to `/onboarding` and deleted users
/// landed on "What should we call you?" — reported by testers, and the
/// reason this class exists.
///
/// Every earlier attempt at the problem was a race against that window
/// rather than a way out of it:
///
///   * invalidate the three profile providers and hope the redirect
///     reads them in the right order (they're all derived from
///     `authStateProvider`, so they re-create on the auth change
///     anyway — the invalidations were no-ops);
///   * poll `authStateProvider` for up to 5 s before navigating (the
///     sheet is torn down by the redirect long before the poll ends,
///     so the navigation never ran at all);
///   * allow the orphaned state only when the user is already standing
///     on an auth surface (`routes.dart` escape hatch) — which after
///     deletion they never are, because they came from Settings.
///
/// This flag replaces the guessing with a fact the client already knows
/// for certain: *we* issued the delete.
///
/// ## Deliberately not a provider
///
/// The router's redirect has to read this synchronously, and it cannot
/// afford another async value that is itself mid-rebuild during the
/// very window it's trying to describe. A plain static is read-correct
/// at every instant, which is the whole point.
class AccountDeletion {
  AccountDeletion._();

  /// uid whose account was just deleted, or null when no deletion is in
  /// flight.
  ///
  /// Exposed as a [ValueNotifier] so `routerProvider` can re-run its
  /// redirect the moment deletion starts, instead of waiting for
  /// `signOut()` to propagate through the auth stream — sign-out tears
  /// down the foreground service, alarms and the FCM listener first,
  /// which can take a second or two of platform-channel round-trips.
  static final ValueNotifier<String?> deletedUid =
      ValueNotifier<String?>(null);

  /// True while the deletion of [currentUid]'s account is still
  /// settling, i.e. the router should force `/welcome`.
  ///
  /// Scoped to the deleted uid on purpose. If `signOut()` throws and the
  /// session never clears, a later signup on this device gets a
  /// DIFFERENT uid, this returns false, and the stuck flag cannot trap
  /// the new account on `/welcome`. Without that scoping a failed
  /// sign-out would be a worse bug than the one this fixes.
  static bool isSettling(String? currentUid) {
    final deleted = deletedUid.value;
    if (deleted == null) return false;
    return currentUid == null || currentUid == deleted;
  }

  /// Raise the flag. Called from the delete-account sheet immediately
  /// after the server confirms deletion, synchronously, so no redirect
  /// pass can observe the orphaned session without knowing why it
  /// exists.
  static void begin(String uid) => deletedUid.value = uid;

  /// Lower the flag. Called from `routerProvider` once the session
  /// actually clears (or a different user signs in) — from that point
  /// the redirect's ordinary signed-out branch routes to `/welcome` on
  /// its own and the flag would only mask real state.
  static void end() => deletedUid.value = null;
}
