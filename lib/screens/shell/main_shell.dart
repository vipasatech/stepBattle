import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/step_provider.dart';
import '../../widgets/permission_gate.dart';

/// Main shell with 5-tab bottom nav.
/// On first build after sign-in:
///   - Runs schema backfill (ensures userCode + XP fields exist)
/// Continuously:
///   - Listens to local step changes and auto-syncs to Firestore
class MainShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;

  const MainShell({super.key, required this.navigationShell});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  bool _backfillTriggered = false;

  Future<void> _runInitialSync(String uid) async {
    // 1. Backfill missing user doc fields (userCode, etc.)
    await ref.read(authServiceProvider).ensureUserDataComplete(uid);

    // 2. Force a step sync using current device step count — this pushes
    //    today's steps to every downstream (step_logs, missions, battles, clan).
    //    Needed because ref.listen only fires on CHANGE, not on first load.
    try {
      final health = ref.read(healthServiceProvider);
      final steps = await health.getTodaySteps();
      if (steps > 0) {
        await ref.read(stepServiceProvider).syncSteps(
              userId: uid,
              steps: steps,
              source: health.sourceName,
            );
      }
    } catch (_) {
      // Health not authorized or offline — ignore silently.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Run one-time schema backfill + force initial step sync when auth confirms.
    // Non-blocking: fires and forgets.
    final uid = ref.watch(authStateProvider).valueOrNull?.uid;
    if (uid != null && !_backfillTriggered) {
      _backfillTriggered = true;
      _runInitialSync(uid);
    }

    // Auto-sync step count to Firestore whenever local device reading changes.
    // This fans out to: step_logs, users.totalStepsAllTime,
    // user_mission_progress, active battles, clan members.
    ref.listen<AsyncValue<int>>(localTodayStepsProvider, (prev, next) {
      final newSteps = next.valueOrNull;
      if (newSteps == null || newSteps <= 0) return;
      if (prev?.valueOrNull == newSteps) return;

      final uid = ref.read(authStateProvider).valueOrNull?.uid;
      if (uid == null) return;

      final healthService = ref.read(healthServiceProvider);
      ref.read(stepServiceProvider).syncSteps(
            userId: uid,
            steps: newSteps,
            source: healthService.sourceName,
          );
    });

    final shell = widget.navigationShell;
    return PermissionGate(
      child: Scaffold(
        body: shell,
        extendBody: true,
        bottomNavigationBar: _BottomNavBar(
          currentIndex: shell.currentIndex,
          onTap: (index) => shell.goBranch(
            index,
            initialLocation: index == shell.currentIndex,
          ),
        ),
      ),
    );
  }
}

class _BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNavBar({required this.currentIndex, required this.onTap});

  static const _items = [
    _NavItem(icon: Icons.sports_score, activeIcon: Icons.sports_score, label: 'Home'),
    _NavItem(icon: Icons.bolt_outlined, activeIcon: Icons.bolt, label: 'Battles'),
    _NavItem(icon: Icons.military_tech_outlined, activeIcon: Icons.military_tech, label: 'Missions'),
    _NavItem(icon: Icons.shield_outlined, activeIcon: Icons.shield, label: 'Clan'),
    _NavItem(icon: Icons.leaderboard_outlined, activeIcon: Icons.leaderboard, label: 'Ranks'),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.background.withValues(alpha: 0.8),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrand.withValues(alpha: 0.15),
                blurRadius: 20,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(_items.length, (i) {
                  final item = _items[i];
                  final isActive = i == currentIndex;
                  return _NavButton(
                    item: item,
                    isActive: isActive,
                    onTap: () => onTap(i),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final _NavItem item;
  final bool isActive;
  final VoidCallback onTap;

  const _NavButton({
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: isActive
            ? BoxDecoration(
                color: AppColors.primaryBrand.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.3),
                    blurRadius: 15,
                  ),
                ],
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? item.activeIcon : item.icon,
              color: isActive ? AppColors.primary : Colors.grey,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: isActive ? AppColors.primary : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}
