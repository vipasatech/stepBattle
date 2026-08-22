import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../services/observability_service.dart';
import '../utils/app_logger.dart';
import '../utils/cross_isolate_kv.dart';
import '../screens/shell/main_shell.dart';
import '../screens/home/home_screen.dart';
import '../screens/battles/all_completed_battles_screen.dart';
import '../screens/battles/battles_screen.dart';
import '../screens/battles/discover_battles_screen.dart';
import '../screens/battles/pending_battles_screen.dart';
import '../screens/battle_ground/battle_ground_screen.dart';
import '../screens/battle_ground/battle_status_screen.dart';
import '../screens/clan/clan_screen.dart';
import '../screens/clan/clan_details_screen.dart';
import '../screens/family/manage_family_screen.dart';
import '../screens/day_summary/day_summary_screen.dart';
import '../screens/leaderboard/leaderboard_screen.dart';
import '../screens/missions/missions_page.dart';
import '../screens/auth/email_otp_verify_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/onboarding_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/welcome_screen.dart';
import '../screens/clan_battle/create_clan_battle_screen.dart';
import '../screens/clan_battle/join_clan_battle_screen.dart';
// Cinematic map screen (`/map`) is unwired from the router while the
// feature waits for a future version. Keeping the import here would
// defeat tree-shaking and drop MapScreen + map_provider + related
// helpers into every release build. The source stays at
// `lib/screens/map/map_screen.dart`; re-add this import and the
// `/map` GoRoute below when the feature ships.
// import '../screens/map/map_screen.dart';
import '../screens/onboarding/health_setup_screen.dart';
import '../screens/team_lobby/team_lobby_page.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/profile/public_profile_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/profile/step_sources_screen.dart';
import '../screens/track/all_track_sessions_screen.dart';
import '../screens/track/edit_session_screen.dart';
import '../screens/track/save_activity_screen.dart';
import '../screens/track/track_hub_screen.dart';
import '../screens/track/track_live_screen.dart';
import '../screens/track/track_session_detail_screen.dart';
import 'route_transitions.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

/// NavigatorObserver that logs every push/pop/replace to AppLogger.nav.
/// Keeps a record of which screen the user is on at every tap so we can
/// correlate downstream service events with the current UI surface.
class _NavLoggingObserver extends NavigatorObserver {
  @override
  void didPush(Route route, Route? previousRoute) {
    AppLogger.nav.i('push', fields: {
      'to': route.settings.name ?? route.settings.toString(),
      'from': previousRoute?.settings.name,
    });
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    AppLogger.nav.i('pop', fields: {
      'from': route.settings.name ?? route.settings.toString(),
      'to': previousRoute?.settings.name,
    });
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    AppLogger.nav.i('replace', fields: {
      'old': oldRoute?.settings.name,
      'new': newRoute?.settings.name,
    });
  }
}

/// GoRouter provider.
///
/// **CRITICAL:** Do not `ref.watch` providers inside this builder. Watching
/// makes Riverpod rebuild the entire `Provider` (and thus the `GoRouter`)
/// every time the watched provider ticks. A fresh `GoRouter` resets to its
/// `initialLocation` ('/splash'), which produces the
/// splash → home → splash → home flicker loop on auth/onboarding emits.
///
/// Instead we build the router **once** and drive redirect re-evaluation via
/// a `refreshListenable` that ticks whenever auth or onboarding state
/// changes. The redirect callback reads providers via `ref.read` at call
/// time, so it always sees the latest values.
///
/// Motion policy for every push: use [RouteTransitions] helpers via
/// `pageBuilder:` — never `builder:`. Tab-branch ROOT routes (`/home`,
/// `/battles`, `/track`, `/clan`, `/leaderboard`) keep `builder:` because
/// tab switches are driven by the shell's `IndexedStack` and don't push
/// — so no page-transition ever runs on them.
final routerProvider = Provider<GoRouter>((ref) {
  // Bumps every time we want GoRouter to re-run its redirect. Subscribed
  // listeners (the router) react; this provider itself does NOT rebuild.
  final refreshNotifier = ValueNotifier<int>(0);
  ref.listen(authStateProvider, (_, __) => refreshNotifier.value++);
  ref.listen(hasCompletedOnboardingProvider, (_, __) => refreshNotifier.value++);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/splash',
    observers: [_NavLoggingObserver(), ObservabilityRouteObserver()],
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final authState = ref.read(authStateProvider);
      final hasOnboarded = ref.read(hasCompletedOnboardingProvider);

      final location = state.matchedLocation;
      final isOnSplash = location == '/splash';

      // The splash screen owns the routing decision for the cold-launch
      // window — it waits for auth + onboarding to resolve then calls
      // context.go itself. Don't second-guess it from here.
      if (isOnSplash) return null;

      // While Supabase is still restoring the persisted session on cold
      // start, `authState` is in AsyncLoading and `valueOrNull` is null.
      // Treating that as "signed out" briefly flashes /login for users
      // who actually ARE signed in. Stay wherever we are until we know.
      if (authState.isLoading) {
        return null;
      }

      final user = authState.valueOrNull;
      final isLoggedIn = user != null;
      final isOnLoginPage = location == '/login';
      final isOnSignupPage = location == '/signup';
      final isOnWelcomePage = location == '/welcome';
      final isOnOnboarding = location == '/onboarding';
      // `/verify-otp` is the passwordless OTP entry step reached
      // after the email is submitted on signup/login. `verifyOTP`
      // establishes a session mid-flow so this route stays allowed
      // for either auth state — the signed-in redirect below skips
      // it. After a successful verify the redirect gate routes to
      // /home or /onboarding without needing explicit navigation.
      final isOnOtpVerify = location == '/verify-otp';

      // Not logged in → OTP restore FIRST (takes priority over the
      // auth-surface allowlist), then default auth-surface routing.
      //
      // Why OTP restore fires ahead of the allowlist: cold-start
      // routes users to /welcome by default (see splash → welcome
      // sequence). /welcome IS on the allowlist, so if we checked
      // the allowlist first the restore would NEVER fire for the
      // exact case it exists to fix — user backgrounded on /verify-otp,
      // OS killed the app, user reopens → cold-start defaults to
      // /welcome → allowlist says "you're fine here" → user loses
      // their mid-flow OTP state.
      //
      // The restore payload is cleared explicitly on: successful
      // verify, "Use a different email", back arrow, X close. So a
      // present payload always means "the user WAS actively verifying
      // when the app died." 15-minute TTL prevents stale entries
      // from resurrecting the screen days later. Guard against
      // infinite-redirect on /verify-otp itself.
      if (!isLoggedIn) {
        final pending = CrossIsolateKV.getPendingOtpSync();
        if (pending != null && !isOnOtpVerify) {
          AppLogger.nav.i('otpRestore:redirecting', fields: {
            'mode': pending.mode,
            'from': location,
          });
          return '/verify-otp'
              '?email=${Uri.encodeQueryComponent(pending.email)}'
              '&mode=${Uri.encodeQueryComponent(pending.mode)}';
        }
        // Standard auth-surface allowlist. Signed-out users are only
        // permitted on these four routes; everything else bounces to
        // /welcome (the entry point that mirrors first-install).
        if (isOnWelcomePage ||
            isOnLoginPage ||
            isOnSignupPage ||
            isOnOtpVerify) {
          return null;
        }
        return '/welcome';
      }

      // Just-deleted account escape hatch. When the user completes
      // the delete-account flow, the profile row is removed
      // server-side and `currentUserProvider` briefly returns null
      // BEFORE `authStateProvider` catches up to signed-out. In that
      // window, `hasCompletedOnboardingProvider` returns false and
      // the block below would send them to /onboarding — the exact
      // "stuck on 'What should we call you?'" bug testers reported.
      // If we're already ON /welcome, /login, or /signup and the
      // user is technically still authenticated, DON'T pull them
      // to /home — that starts the onboarding bounce. Let them stay
      // on the current auth surface; the pending signOut will
      // complete within a beat and the gate resolves cleanly.
      //
      // /verify-otp is DELIBERATELY excluded from this escape hatch.
      // Reaching /verify-otp requires an in-flight signup/login
      // OTP flow (see PermissionCoordinator + email_otp_verify).
      // A logged-in user standing on /verify-otp always means "OTP
      // was just verified successfully" — never the delete-account
      // race — so trapping them here (as this hatch previously did)
      // stranded fresh signups whose profile wasn't yet marked
      // onboarded. That was the "verified but stayed on OTP screen"
      // bug reproduced in the 2026-08-10 logs.
      final onboarded = hasOnboarded.valueOrNull;
      final isOnAuthSurface = isOnLoginPage || isOnSignupPage ||
          isOnWelcomePage || isOnOtpVerify;
      final isOnAuthSurfaceExceptOtp =
          isOnLoginPage || isOnSignupPage || isOnWelcomePage;
      if (isOnAuthSurfaceExceptOtp && onboarded == false) {
        // Orphaned auth session — profile is gone but session hasn't
        // cleared yet. Stay on the current auth surface.
        return null;
      }

      // After sign-in we leave the auth surfaces. Optimistically route
      // to /home — the onboarding check below will catch unfinished
      // profiles on the next redirect pass. Sending everyone straight
      // to /onboarding here re-prompts the name-entry screen on every
      // login for users who already onboarded.
      if (isOnAuthSurface) {
        return '/home';
      }

      // Onboarding gate. `valueOrNull` is null while the profile fetch is
      // in-flight — we leave the user where they are during that brief
      // window rather than guessing.
      if (onboarded == false && !isOnOnboarding) {
        return '/onboarding';
      }
      // Already-onboarded user landed on /onboarding (deep link, race, or
      // legacy nav) — send them home instead of re-prompting for a name.
      if (onboarded == true && isOnOnboarding) {
        return '/home';
      }

      // All other pages allowed
      return null;
    },
    routes: [
      // Cold-launch splash. Renders the running-character animation +
      // pulsing rings while Supabase restores the persisted session, then
      // routes to /home, /onboarding, or /login itself via context.go.
      // Kept on `builder:` (no push transition — this is the initial
      // location on cold-start).
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),

      // Auth routes — peer-level swaps (welcome ↔ login ↔ signup ↔
      // verify-otp). Fade-through reads correctly for a flow where
      // one auth surface replaces another.
      GoRoute(
        path: '/welcome',
        name: 'welcome',
        pageBuilder: (context, state) => RouteTransitions.fadeThroughPage(
          key: state.pageKey,
          name: state.name,
          child: const WelcomeScreen(),
        ),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        pageBuilder: (context, state) => RouteTransitions.fadeThroughPage(
          key: state.pageKey,
          name: state.name,
          child: const LoginScreen(),
        ),
      ),
      GoRoute(
        path: '/signup',
        name: 'signup',
        pageBuilder: (context, state) => RouteTransitions.fadeThroughPage(
          key: state.pageKey,
          name: state.name,
          child: const SignupScreen(),
        ),
      ),
      GoRoute(
        path: '/verify-otp',
        name: 'verifyOtp',
        pageBuilder: (context, state) {
          final email = state.uri.queryParameters['email'];
          final mode = state.uri.queryParameters['mode'] ?? 'login';
          if (email == null || email.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => context.go('/welcome'));
            return RouteTransitions.fadeThroughPage(
              key: state.pageKey,
              name: state.name,
              child: const Scaffold(body: SizedBox.shrink()),
            );
          }
          return RouteTransitions.fadeThroughPage(
            key: state.pageKey,
            name: state.name,
            child: EmailOtpVerifyScreen(email: email, mode: mode),
          );
        },
      ),
      GoRoute(
        path: '/onboarding',
        name: 'onboarding',
        pageBuilder: (context, state) => RouteTransitions.fadeThroughPage(
          key: state.pageKey,
          name: state.name,
          child: const OnboardingScreen(),
        ),
      ),

      // Family Pass management — full-screen scale-fade so the "leave
      // the shell" moment is deliberate.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/family',
        name: 'family',
        pageBuilder: (context, state) => RouteTransitions.scaleFadePage(
          key: state.pageKey,
          name: state.name,
          child: const ManageFamilyScreen(),
        ),
      ),

      // Public profile — drill-down from leaderboard rows / arena
      // avatars. Shared-axis Y reads as "one level deeper".
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/users/:userId',
        name: 'publicProfile',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: PublicProfileScreen(
            userId: state.pathParameters['userId']!,
          ),
        ),
      ),

      // Featured missions — drill-down from the Home tab's stacked
      // mission deck.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/missions',
        name: 'missions',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: const MissionsPage(),
        ),
      ),

      // Battle Ground — immersive full-screen arena. Scale-fade so
      // entering feels like stepping into an environment.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/battle-ground/:id',
        name: 'battleGround',
        pageBuilder: (context, state) => RouteTransitions.scaleFadePage(
          key: state.pageKey,
          name: state.name,
          child: BattleGroundScreen(
            battleId: state.pathParameters['id']!,
          ),
        ),
      ),

      // Team lobby — full-screen sheet-like page. Scale-fade for the
      // same "own world" reason as battle ground.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/team-lobby/:battleId',
        name: 'teamLobby',
        pageBuilder: (context, state) => RouteTransitions.scaleFadePage(
          key: state.pageKey,
          name: state.name,
          child: TeamLobbyPage(
            battleId: state.pathParameters['battleId']!,
          ),
        ),
      ),

      // Battle Status — reached by tapping a completed battle card.
      // Shared-axis Y AS THE PAGE FALLBACK. The BattleCard uses a
      // Hero morph on top; the shared-axis motion handles the rest
      // of the page (background, chrome) while Hero handles the
      // card-to-header morph.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/battle-status/:id',
        name: 'battleStatus',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: BattleStatusScreen(
            battleId: state.pathParameters['id']!,
          ),
        ),
      ),

      // Full-history overflow for the Battles tab's Completed section.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/battles/completed',
        name: 'allCompletedBattles',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: const AllCompletedBattlesScreen(),
        ),
      ),

      // Day Summary — drill-down from the streak strip.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/day-summary/:date',
        name: 'daySummary',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: DaySummaryScreen(
            dateIso: state.pathParameters['date']!,
          ),
        ),
      ),

      // Map — full-screen cinematic map. Currently OFF: no path in the
      // app navigates here and the route + import are commented out
      // so `MapScreen`, `map_provider`, and their exclusive
      // dependencies get tree-shaken out of release builds. Restore
      // the import at the top of this file AND uncomment this block
      // to re-enable when the feature ships. Would use scaleFadePage.

      // Live Track recording — immersive. Scale-fade.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/live',
        name: 'trackLive',
        pageBuilder: (context, state) => RouteTransitions.scaleFadePage(
          key: state.pageKey,
          name: state.name,
          child: const TrackLiveScreen(),
        ),
      ),

      // Save Activity — drill from live.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/save',
        name: 'trackSave',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: const SaveActivityScreen(),
        ),
      ),

      // Saved-session detail — drill from Track hub row.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/session/:id',
        name: 'trackSessionDetail',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: TrackSessionDetailScreen(
            sessionId: state.pathParameters['id']!,
          ),
        ),
      ),

      // Full-history overflow for Track hub's Recent Sessions section.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/history',
        name: 'trackHistory',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: const AllTrackSessionsScreen(),
        ),
      ),

      // Edit saved session — drill from session detail.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/session/:id/edit',
        name: 'trackSessionEdit',
        pageBuilder: (context, state) => RouteTransitions.sharedAxisYPage(
          key: state.pageKey,
          name: state.name,
          child: EditSessionScreen(
            sessionId: state.pathParameters['id']!,
          ),
        ),
      ),

      // Main app shell with 5 tabs. Tab-root routes below intentionally
      // use `builder:` (no page transition) because the shell's
      // IndexedStack handles tab switches without pushing.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainShell(navigationShell: navigationShell);
        },
        branches: [
          // Tab 0: Home. Tab-root uses `builder:`; sub-routes push
          // shared-axis-Y (drill-downs).
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                name: 'home',
                builder: (context, state) => const HomeScreen(),
              ),
              GoRoute(
                path: '/profile',
                name: 'profile',
                pageBuilder: (context, state) =>
                    RouteTransitions.sharedAxisYPage(
                  key: state.pageKey,
                  name: state.name,
                  child: const ProfileScreen(),
                ),
              ),
              GoRoute(
                path: '/settings',
                name: 'settings',
                pageBuilder: (context, state) =>
                    RouteTransitions.sharedAxisYPage(
                  key: state.pageKey,
                  name: state.name,
                  child: const SettingsScreen(),
                ),
              ),
              GoRoute(
                path: '/profile/step-sources',
                name: 'stepSources',
                pageBuilder: (context, state) =>
                    RouteTransitions.sharedAxisYPage(
                  key: state.pageKey,
                  name: state.name,
                  child: const StepSourcesScreen(),
                ),
              ),
              GoRoute(
                path: '/profile/health-setup',
                name: 'healthSetup',
                pageBuilder: (context, state) {
                  final firstRun = (state.uri.queryParameters['firstRun'] ??
                          'false') ==
                      'true';
                  return RouteTransitions.sharedAxisYPage(
                    key: state.pageKey,
                    name: state.name,
                    child: HealthSetupScreen(isFirstRun: firstRun),
                  );
                },
              ),
            ],
          ),
          // Tab 1: Battles. Tab root uses `builder:`; sub-routes drill.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/battles',
                name: 'battles',
                builder: (context, state) => const BattlesScreen(),
                routes: [
                  GoRoute(
                    path: 'pending',
                    name: 'pendingBattles',
                    pageBuilder: (context, state) =>
                        RouteTransitions.sharedAxisYPage(
                      key: state.pageKey,
                      name: state.name,
                      child: const PendingBattlesScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'discover',
                    name: 'discoverBattles',
                    pageBuilder: (context, state) =>
                        RouteTransitions.sharedAxisYPage(
                      key: state.pageKey,
                      name: state.name,
                      child: const DiscoverBattlesScreen(),
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Tab 2: Track. Hub uses `builder:` (tab root).
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/track',
                name: 'trackTab',
                builder: (context, state) => const TrackHubScreen(),
              ),
            ],
          ),
          // Tab 3: Clan. Tab root uses `builder:`; sub-routes drill.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/clan',
                name: 'clan',
                builder: (context, state) => const ClanScreen(),
                routes: [
                  GoRoute(
                    path: 'create-battle',
                    name: 'createClanBattle',
                    pageBuilder: (context, state) =>
                        RouteTransitions.sharedAxisYPage(
                      key: state.pageKey,
                      name: state.name,
                      child: const CreateClanBattleScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'join-battle',
                    name: 'joinClanBattle',
                    pageBuilder: (context, state) =>
                        RouteTransitions.sharedAxisYPage(
                      key: state.pageKey,
                      name: state.name,
                      child: const JoinClanBattleScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'details',
                    name: 'clanDetails',
                    pageBuilder: (context, state) =>
                        RouteTransitions.sharedAxisYPage(
                      key: state.pageKey,
                      name: state.name,
                      child: const ClanDetailsScreen(),
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Tab 4: Leaderboard. Tab root uses `builder:`.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/leaderboard',
                name: 'leaderboard',
                builder: (context, state) => const LeaderboardScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
