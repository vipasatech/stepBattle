import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/notification_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/notifications_sheet.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/buy_xp_cta.dart';
import '../../widgets/friends_app_bar_button.dart';
import '../../widgets/no_steps_banner.dart';
import 'widgets/overview_card.dart';
import 'widgets/stat_pills_row.dart';
import 'widgets/active_battle_card.dart';
import 'widgets/daily_target_card.dart';
import 'widgets/map_preview_card.dart';
import 'widgets/streak_strip.dart';
import 'widgets/todays_session_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final unreadCount = ref.watch(unreadNotificationCountProvider);

    // The `CompleteProfileSheet` catch-up modal used to pop here to
    // ask users who onboarded before migration 0016 for DOB / gender
    // / fitness. It's been retired: the current onboarding flow
    // collects those same fields (plus preferred_name), and
    // `hasCompletedOnboardingProvider` bounces any signed-in user
    // with a missing field back to `/onboarding` before they ever
    // reach Home. No fallback surface is needed here.

    // New top-bar topology (replaces the old wordmark + 5-action row):
    //
    //   ┌─ leading ──────────────┐ ┌── title ──┐ ┌── actions ─┐
    //   │ (Profile)(Friends)     │ │  +XP CTA  │ │   🔔²      │
    //   └────────────────────────┘ └───────────┘ └────────────┘
    //
    //   • Profile + Friends sit in the hardest-to-reach corner (low-
    //     frequency identity actions).
    //   • +XP CTA gets the center slot for maximum visual pull, paired
    //     with a 1.2 s sweep animation around its border that fires once
    //     on every Home mount (the user explicitly asked for this).
    //   • Notification bell with its badge stays right — that's where
    //     the eye expects it and the thumb finds it easily.
    return Scaffold(
      appBar: AppBar(
        // Make room for the Profile avatar + Friends button in the
        // leading slot — defaults to 56 which only fits one.
        leadingWidth: 100,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => context.push('/profile'),
                child: AvatarCircle(
                  radius: 18,
                  imageUrl: profile?.avatarURL,
                  initials: _initials(profile?.friendlyName),
                  borderColor: AppColors.outlineVariant,
                  borderWidth: 1,
                ),
              ),
              const SizedBox(width: 8),
              const FriendsAppBarButton(),
            ],
          ),
        ),
        centerTitle: true,
        title: const BuyXpCta(),
        actions: [
          _BellButton(unreadCount: unreadCount),
          const SizedBox(width: 12),
        ],
      ),
      body: const _HomeBody(),
    );
  }

  static String _initials(String? name) {
    if (name == null || name.isEmpty) return '?';
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}

// _BuyXpCta + _SweepBorderPainter moved to lib/widgets/buy_xp_cta.dart
// so Profile can render the same animated CTA in its AppBar title.

class _BellButton extends StatelessWidget {
  final int unreadCount;
  const _BellButton({required this.unreadCount});

  @override
  Widget build(BuildContext context) {
    // Pull surface + on-surface colours from Theme so this widget is
    // subscribed to the InheritedWidget — without that dependency, the
    // bell's background was reading a stale value from the static
    // AppColors getter on theme toggle and only updated after the next
    // touch event jolted a rebuild.
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const NotificationsSheet(),
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.notifications_outlined,
                color: scheme.onSurface, size: 20),
            if (unreadCount > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints:
                      const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: BoxDecoration(
                    color: scheme.error,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.surface, width: 1.5),
                  ),
                  child: Text(
                    unreadCount > 9 ? '9+' : '$unreadCount',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
      children: const [
        // Auto-diagnostic banner — only renders when every step source
        // has been failing/empty for 10+ minutes. Self-suppressing if
        // dismissed or once steps start flowing.
        NoStepsBanner(),

        // Streak strip — flame chip + swipeable week PageView. Tapping
        // a past day opens the per-date Day Summary.
        StreakStrip(),
        SizedBox(height: 28),

        // Section 1: Overview card + stat pills
        OverviewCard(),
        SizedBox(height: 12),
        StatPillsRow(),

        SizedBox(height: 32),

        // Section 2: Active Battle
        ActiveBattleCard(),

        SizedBox(height: 32),

        // Today's track session (only renders when the user has a
        // qualifying run/walk from today — see TodaysSessionCard for
        // the show criteria). Self-hides via SizedBox.shrink when
        // there's nothing to show, so it doesn't add a phantom gap
        // on days without a session.
        TodaysSessionCard(),

        // Section 3: Today's mission — the personalized step target
        // (replaces the old multi-row daily missions list).
        DailyTargetCard(),

        SizedBox(height: 32),

        // Section 4: Map preview
        MapPreviewCard(),
      ],
    );
  }
}
