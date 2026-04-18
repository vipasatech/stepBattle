import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../screens/shell/main_shell.dart';
import '../screens/home/home_screen.dart';
import '../screens/battles/battles_screen.dart';
import '../screens/battles/pending_battles_screen.dart';
import '../screens/missions/missions_screen.dart';
import '../screens/clan/clan_screen.dart';
import '../screens/clan/clan_details_screen.dart';
import '../screens/leaderboard/leaderboard_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/onboarding_screen.dart';
import '../screens/clan_battle/create_clan_battle_screen.dart';
import '../screens/clan_battle/join_clan_battle_screen.dart';
import '../screens/profile/profile_screen.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

/// GoRouter provider — rebuilds when auth state changes for redirect logic.
final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);
  final hasOnboarded = ref.watch(hasCompletedOnboardingProvider);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/home',
    redirect: (context, state) {
      final user = authState.valueOrNull;
      final isLoggedIn = user != null;
      final location = state.matchedLocation;
      final isOnLoginPage = location == '/login';
      final isOnOnboarding = location == '/onboarding';

      // Not logged in → force login
      if (!isLoggedIn) {
        return isOnLoginPage ? null : '/login';
      }

      // Logged in but on login page → go to onboarding or home
      if (isOnLoginPage) {
        return '/onboarding';
      }

      // Check if user has completed onboarding (Firestore doc exists)
      final onboarded = hasOnboarded.valueOrNull;
      if (onboarded == false && !isOnOnboarding) {
        // User is authenticated but no Firestore doc → force onboarding
        return '/onboarding';
      }

      // All other pages allowed
      return null;
    },
    routes: [
      // Auth routes
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
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
                ],
              ),
            ],
          ),
          // Tab 2: Missions
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/missions',
                name: 'missions',
                builder: (context, state) => const MissionsScreen(),
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
