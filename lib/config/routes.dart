import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../utils/app_logger.dart';
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
import '../screens/day_summary/day_summary_screen.dart';
import '../screens/leaderboard/leaderboard_screen.dart';
import '../screens/auth/email_otp_verify_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/onboarding_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/welcome_screen.dart';
import '../screens/clan_battle/create_clan_battle_screen.dart';
import '../screens/clan_battle/join_clan_battle_screen.dart';
import '../screens/map/map_screen.dart';
import '../screens/onboarding/health_setup_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/profile/public_profile_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/profile/step_sources_screen.dart';
import '../screens/track/all_track_sessions_screen.dart';
import '../screens/track/edit_session_screen.dart';
import '../screens/track/save_activity_screen.dart';
import '../screens/track/track_hub_screen.dart';
import '../screens/track/track_live_screen.dart';
import '../screens/track/track_session_detail_screen.dart';

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
    observers: [_NavLoggingObserver()],
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

      // Not logged in → force to one of the auth surfaces. Any of
      // /welcome, /login, /signup, or /verify-otp are allowed; a
      // signed-out user landing anywhere else gets bounced to
      // /welcome (the entry point that mirrors first-install).
      if (!isLoggedIn) {
        if (isOnWelcomePage ||
            isOnLoginPage ||
            isOnSignupPage ||
            isOnOtpVerify) {
          return null;
        }
        return '/welcome';
      }

      // After sign-in we leave the auth surfaces. Optimistically route
      // to /home — the onboarding check below will catch unfinished
      // profiles on the next redirect pass. Sending everyone straight
      // to /onboarding here re-prompts the name-entry screen on every
      // login for users who already onboarded.
      if (isOnLoginPage || isOnSignupPage || isOnWelcomePage ||
          isOnOtpVerify) {
        return '/home';
      }

      // Onboarding gate. `valueOrNull` is null while the profile fetch is
      // in-flight — we leave the user where they are during that brief
      // window rather than guessing.
      final onboarded = hasOnboarded.valueOrNull;
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
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),

      // Auth routes
      //
      // Flow for a fresh install:
      //   /splash → (no session) → /welcome
      //     → tap "Join for free" → /signup → after signUp, redirect
      //       moves them to /home which the onboarding gate below
      //       bounces to /onboarding.
      //     → tap "Log in"        → /login → after signIn, redirect
      //       moves them to /home (or /onboarding if profile is
      //       incomplete).
      GoRoute(
        path: '/welcome',
        name: 'welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/signup',
        name: 'signup',
        builder: (context, state) => const SignupScreen(),
      ),
      // Passwordless OTP verify — reached from /signup or /login
      // after the user tapped "Send code". Supabase's signInWithOtp
      // handles signup and login in one call, so this single screen
      // covers both flows; the `mode` query param is cosmetic (drives
      // the header copy only).
      GoRoute(
        path: '/verify-otp',
        name: 'verifyOtp',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'];
          final mode = state.uri.queryParameters['mode'] ?? 'login';
          if (email == null || email.isEmpty) {
            // Direct nav / deep link with no email → bounce to the
            // welcome page rather than render a broken screen.
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => context.go('/welcome'));
            return const Scaffold(body: SizedBox.shrink());
          }
          return EmailOtpVerifyScreen(email: email, mode: mode);
        },
      ),
      GoRoute(
        path: '/onboarding',
        name: 'onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),

      // Profile (full screen, not a tab — uses root navigator)
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/profile',
        name: 'profile',
        builder: (context, state) => const ProfileScreen(),
      ),

      // Public profile for OTHER users — reached from leaderboard
      // rows, friend list rows, arena avatars, etc. `/users/:userId`
      // (root navigator so the destination covers the shell nav bar).
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/users/:userId',
        name: 'publicProfile',
        builder: (context, state) => PublicProfileScreen(
          userId: state.pathParameters['userId']!,
        ),
      ),

      // Step source diagnostics (developer / support screen)
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/profile/step-sources',
        name: 'stepSources',
        builder: (context, state) => const StepSourcesScreen(),
      ),

      // OEM-aware step tracking setup wizard. Reachable from the
      // post-permission auto-show, the Home "Steps not flowing" banner,
      // and the Profile setup tile.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/profile/health-setup',
        name: 'healthSetup',
        builder: (context, state) {
          final firstRun =
              (state.uri.queryParameters['firstRun'] ?? 'false') == 'true';
          return HealthSetupScreen(isFirstRun: firstRun);
        },
      ),

      // Battle Ground — full-screen immersive arena for an active battle.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/battle-ground/:id',
        name: 'battleGround',
        builder: (context, state) => BattleGroundScreen(
          battleId: state.pathParameters['id']!,
        ),
      ),

      // Battle Status — post-battle, drag-to-arrange cards + winner
      // particle effect + customisable background. Opens from the
      // Completed section of the Battles tab.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/battle-status/:id',
        name: 'battleStatus',
        builder: (context, state) => BattleStatusScreen(
          battleId: state.pathParameters['id']!,
        ),
      ),

      // Full-history overflow for the Battles tab's "Completed"
      // section. Reached via the chevron on the section header when
      // the completed count is > 5.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/battles/completed',
        name: 'allCompletedBattles',
        builder: (context, state) => const AllCompletedBattlesScreen(),
      ),

      // Day Summary — per-date view of steps, XP, battles, and track
      // sessions. Reached from the home-screen streak strip when the
      // user taps a past day.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/day-summary/:date',
        name: 'daySummary',
        builder: (context, state) => DaySummaryScreen(
          dateIso: state.pathParameters['date']!,
        ),
      ),

      // Map — full-screen cinematic map. Auto-redirects to Set Home
      // sheet when the user hasn't set a home district.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/map',
        name: 'map',
        builder: (context, state) => const MapScreen(),
      ),

      // (The old full-screen `/track` route was removed when Track became a
      // dedicated bottom-nav tab — see the StatefulShellBranch below at
      // `/track`. Existing `context.go('/track')` callers now switch to the
      // Track tab instead of pushing a full-screen page.)

      // Live Track recording. Reached from the FAB when a session is active,
      // or right after Start. The session keeps running in the foreground
      // service when the user navigates away from this screen.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/live',
        name: 'trackLive',
        builder: (context, state) => const TrackLiveScreen(),
      ),

      // Save Activity — pushed when the user taps "End run" on the live
      // screen. Lets them caption the session and attach up to 5 photos
      // before the row is persisted. "Resume" pops back to the live
      // screen with the session still running.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/save',
        name: 'trackSave',
        builder: (context, state) => const SaveActivityScreen(),
      ),

      // Saved-session detail. Reached by tapping a row in the Track hub's
      // "Recent sessions" list. Read-only stats + GPS route + share.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/session/:id',
        name: 'trackSessionDetail',
        builder: (context, state) => TrackSessionDetailScreen(
          sessionId: state.pathParameters['id']!,
        ),
      ),

      // Full-history overflow for the Track hub's "RECENT SESSIONS"
      // section. Reached via the chevron on the section header when
      // the history count is > 5.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/history',
        name: 'trackHistory',
        builder: (context, state) => const AllTrackSessionsScreen(),
      ),

      // Edit an already-saved session — reached from the pencil icon on
      // the session detail screen. Update name / description / media.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/track/session/:id/edit',
        name: 'trackSessionEdit',
        builder: (context, state) => EditSessionScreen(
          sessionId: state.pathParameters['id']!,
        ),
      ),

      // Main app shell with 5 tabs
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return MainShell(navigationShell: navigationShell);
        },
        branches: [
          // Tab 0: Home
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                name: 'home',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          // Tab 1: Battles
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
                    builder: (context, state) =>
                        const PendingBattlesScreen(),
                  ),
                  GoRoute(
                    path: 'discover',
                    name: 'discoverBattles',
                    builder: (context, state) =>
                        const DiscoverBattlesScreen(),
                  ),
                ],
              ),
            ],
          ),
          // Tab 2: Track (replaces the old Missions tab in the bottom nav).
          // The hub lists past Track sessions + a Start CTA; tapping into a
          // live or past session pushes /track/live or /track/session/:id
          // over the shell as full-screen routes.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/track',
                name: 'trackTab',
                builder: (context, state) => const TrackHubScreen(),
              ),
            ],
          ),
          // Tab 3: Clan
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
                    builder: (context, state) =>
                        const CreateClanBattleScreen(),
                  ),
                  GoRoute(
                    path: 'join-battle',
                    name: 'joinClanBattle',
                    builder: (context, state) =>
                        const JoinClanBattleScreen(),
                  ),
                  GoRoute(
                    path: 'details',
                    name: 'clanDetails',
                    builder: (context, state) =>
                        const ClanDetailsScreen(),
                  ),
                ],
              ),
            ],
          ),
          // Tab 4: Leaderboard
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
