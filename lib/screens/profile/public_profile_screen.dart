import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../config/colors.dart';
import '../../models/friend_relationship_model.dart';
import '../../models/subscription_model.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/subscription_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/leaderboard_service.dart';
import '../../sheets/battle_1v1_setup_sheet.dart';
import '../../sheets/upgrade_cta_sheet.dart';
import '../../utils/app_logger.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/pro_badge.dart';
import '../../widgets/shimmer_loader.dart';

/// Read-only view of another user's profile — reached from the arena
/// (tap an opponent's avatar) or from leaderboards / friends list.
///
/// Matches the Profile tab visual language stripped of every private /
/// self-only affordance:
///   • No top-right icons (search / share / settings)
///   • No edit avatar sheet, no share-my-QR sheet
///   • No this-week trend chart, no battles-history card
///   • No account / settings / sign-out rows
///
/// What's kept:
///   • Big avatar + name + verified badge + location
///   • 5-stat row: Level · B/W · XP · Streak · Rank
///   • All-time stats card, expanded by default:
///     Total XP · Battles W/L · Best Streak · Total Steps
class PublicProfileScreen extends ConsumerWidget {
  final String userId;
  const PublicProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncUser = ref.watch(otherUserProvider(userId));

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: asyncUser.when(
        loading: () => ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: const [
            ShimmerLoader(height: 92, borderRadius: 20),
            SizedBox(height: 16),
            ShimmerLoader(height: 72),
            SizedBox(height: 12),
            ShimmerCard(),
            SizedBox(height: 12),
            ShimmerCard(),
          ],
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load profile: $e',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
        ),
        data: (user) {
          if (user == null) {
            return const Center(child: Text('User not found.'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 40),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _PublicIdentity(user: user),
              ),
              const SizedBox(height: 28),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _PublicActionBar(user: user),
              ),
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _PublicStatsRow(user: user),
              ),
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _AllTimeCard(user: user),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Full-screen zoomable viewer for a user's avatar. Opens as a
/// transparent dialog with a Hero transition from the tapped circle;
/// the user can pinch-zoom (up to 4×), pan, and dismiss via the close
/// button or a tap on the dimmed backdrop.
void _showAvatarViewer(
  BuildContext context, {
  required String imageUrl,
  required String heroTag,
}) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      pageBuilder: (_, __, ___) => _AvatarViewer(
        imageUrl: imageUrl,
        heroTag: heroTag,
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _AvatarViewer extends StatelessWidget {
  final String imageUrl;
  final String heroTag;
  const _AvatarViewer({required this.imageUrl, required this.heroTag});

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Backdrop tap = dismiss.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.expand(),
          ),
          Center(
            child: Hero(
              tag: heroTag,
              child: InteractiveViewer(
                panEnabled: true,
                minScale: 0.75,
                maxScale: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                      width: 220,
                      height: 220,
                      color: Colors.grey.shade900,
                      alignment: Alignment.center,
                      child: const Icon(Icons.broken_image_outlined,
                          color: Colors.white54, size: 48),
                    ),
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return const SizedBox(
                        width: 220,
                        height: 220,
                        child: Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: topInset + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Identity — avatar + name + verified badge + location
// =============================================================================

class _PublicIdentity extends StatelessWidget {
  final UserModel user;
  const _PublicIdentity({required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = _locationLine(user);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Tap to open a full-screen viewer of the avatar. Only wire the
        // tap when there's an actual photo to look at — the initials
        // circle for photo-less users has nothing meaningful to zoom.
        GestureDetector(
          onTap: (user.avatarURL ?? '').isEmpty
              ? null
              : () => _showAvatarViewer(
                    context,
                    imageUrl: user.avatarURL!,
                    heroTag: 'public-avatar-${user.userId}',
                  ),
          child: Hero(
            tag: 'public-avatar-${user.userId}',
            child: AvatarCircle(
              radius: 48,
              imageUrl: user.avatarURL,
              initials: user.friendlyName.isNotEmpty
                  ? user.friendlyName[0].toUpperCase()
                  : '?',
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      user.friendlyName.isEmpty ? '—' : user.friendlyName,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        height: 1.1,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const ProBadge(size: 18),
                ],
              ),
              if (location != null) ...[
                const SizedBox(height: 3),
                Text(
                  location,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String? _locationLine(UserModel u) {
    if (!u.hasHome) return null;
    final parts = <String>[
      if ((u.districtName ?? '').isNotEmpty) u.districtName!,
      if ((u.stateName ?? '').isNotEmpty) u.stateName!,
      if ((u.countryName ?? '').isNotEmpty) u.countryName!,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }
}

// =============================================================================
// Action bar — Add-friend chip + Battle chip
//
// Sits between the identity block and the stats row on someone else's
// profile. Two full-width chips share the row equally:
//
//   [ + Add friend  ]   [ ⚔ Battle ]
//
// Add friend cycles through the friendship state (send / cancel /
// respond / friends). Battle is Pro-gated — free users tap it and get
// the [showUpgradeCtaSheet] Pro upsell with a contextual "Take on
// {name} head-to-head" headline; Pro / Family users go straight into
// [Battle1v1SetupSheet] with the opponent already selected.
//
// Hidden entirely on the viewer's OWN profile (nothing sensible to do
// with either chip).
// =============================================================================

class _PublicActionBar extends ConsumerWidget {
  final UserModel user;
  const _PublicActionBar({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authStateProvider).valueOrNull;
    if (me == null || me.id == user.userId) {
      // Own profile — no actions apply. Collapse to zero-height so the
      // parent spacing doesn't leave a gap.
      return const SizedBox.shrink();
    }

    return Row(
      children: [
        Expanded(child: _FriendChip(otherUser: user, myUid: me.id)),
        const SizedBox(width: 10),
        Expanded(child: _BattleChip(otherUser: user)),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Friend chip — state machine over friend_relationships
// -----------------------------------------------------------------------------

/// Which affordance the friend chip should render right now. Derived
/// from [allFriendRelationshipsProvider] filtered to the pair
/// (me, otherUser).
enum _FriendChipState {
  /// No row exists (or only a rejected one) → offer to send a request.
  add,
  /// I've sent them a pending request → let me cancel it.
  requested,
  /// They sent ME a pending request → open the accept/decline dialog.
  incoming,
  /// Accepted both sides → offer to unfriend via confirm.
  friends,
}

class _FriendChip extends ConsumerStatefulWidget {
  final UserModel otherUser;
  final String myUid;

  const _FriendChip({required this.otherUser, required this.myUid});

  @override
  ConsumerState<_FriendChip> createState() => _FriendChipCell();
}

class _FriendChipCell extends ConsumerState<_FriendChip> {
  bool _busy = false;

  /// Look at every relationship row the current user is party to and
  /// pick the one that involves [widget.otherUser]. `pending` and
  /// `accepted` matter; a `rejected` row is treated as "no
  /// relationship" so the user can re-request.
  ({_FriendChipState state, FriendRelationship? rel}) _derive(
      List<FriendRelationship> rels) {
    FriendRelationship? match;
    for (final r in rels) {
      final involves =
          (r.fromUserId == widget.myUid && r.toUserId == widget.otherUser.userId) ||
              (r.toUserId == widget.myUid && r.fromUserId == widget.otherUser.userId);
      if (!involves) continue;
      if (r.status == FriendStatus.rejected) continue;
      // Prefer accepted > pending in case both somehow exist.
      if (match == null || r.status == FriendStatus.accepted) {
        match = r;
      }
    }
    if (match == null) return (state: _FriendChipState.add, rel: null);
    if (match.status == FriendStatus.accepted) {
      return (state: _FriendChipState.friends, rel: match);
    }
    // pending
    if (match.fromUserId == widget.myUid) {
      return (state: _FriendChipState.requested, rel: match);
    }
    return (state: _FriendChipState.incoming, rel: match);
  }

  Future<void> _sendRequest() async {
    final me = ref.read(userProfileProvider).valueOrNull;
    final myName = (me?.displayName.trim().isNotEmpty ?? false)
        ? me!.displayName
        : 'A StepBattle user';
    setState(() => _busy = true);
    try {
      await ref.read(friendServiceProvider).sendRequest(
            fromUserId: widget.myUid,
            toUserId: widget.otherUser.userId,
            fromDisplayName: myName,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send request: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelRequest(String relId) async {
    setState(() => _busy = true);
    try {
      await ref.read(friendServiceProvider).cancelRequest(relId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showIncomingDialog(String relId) async {
    final choice = await showDialog<_IncomingChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Friend request'),
        content: Text(
          '${widget.otherUser.friendlyName} sent you a friend request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_IncomingChoice.decline),
            child: Text('Decline',
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_IncomingChoice.accept),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final svc = ref.read(friendServiceProvider);
      if (choice == _IncomingChoice.accept) {
        await svc.acceptRequest(relId);
      } else {
        await svc.rejectRequest(relId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not respond: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRemove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Remove friend?'),
        content: Text(
          '${widget.otherUser.friendlyName} will no longer see your profile as a friend.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(friendServiceProvider).removeFriend(
            userId: widget.myUid,
            friendId: widget.otherUser.userId,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final relsAsync = ref.watch(allFriendRelationshipsProvider);
    final rels = relsAsync.valueOrNull ?? const <FriendRelationship>[];
    final derived = _derive(rels);

    final spec = switch (derived.state) {
      _FriendChipState.add => (
          icon: Icons.person_add_alt_1,
          label: 'Add friend',
          filled: true,
          onTap: _busy ? null : _sendRequest,
        ),
      _FriendChipState.requested => (
          icon: Icons.hourglass_top,
          label: 'Requested',
          filled: false,
          onTap: _busy ? null : () => _cancelRequest(derived.rel!.relationshipId),
        ),
      _FriendChipState.incoming => (
          icon: Icons.mark_email_unread_outlined,
          label: 'Respond',
          filled: true,
          onTap: _busy ? null : () => _showIncomingDialog(derived.rel!.relationshipId),
        ),
      _FriendChipState.friends => (
          icon: Icons.check_circle,
          label: 'Friends',
          filled: false,
          onTap: _busy ? null : _confirmRemove,
        ),
    };

    return _ActionChip(
      icon: spec.icon,
      label: spec.label,
      filled: spec.filled,
      busy: _busy,
      onTap: spec.onTap,
    );
  }
}

enum _IncomingChoice { accept, decline }

// -----------------------------------------------------------------------------
// Battle chip — Pro-gated 1v1 invite
// -----------------------------------------------------------------------------

class _BattleChip extends ConsumerWidget {
  final UserModel otherUser;
  const _BattleChip({required this.otherUser});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ActionChip(
      // Matches the Battles bottom-nav icon so the two "battle"
      // affordances read as the same concept in the UI.
      icon: MdiIcons.swordCross,
      label: 'Battle',
      filled: true,
      busy: false,
      onTap: () => _handleTap(context, ref),
    );
  }

  Future<void> _handleTap(BuildContext context, WidgetRef ref) async {
    try {
      final sub = ref.read(subscriptionProvider);
      final isPro = sub.tier != SubscriptionTier.basic;
      // Batch A #4: friends bypass the Pro gate. Non-friends still see
      // the Pro upsell — direct challenges to arbitrary users are the
      // Pro feature. Friend-to-friend battles are free (the "social"
      // reason to add friends is exactly this).
      final friendIds = ref.read(acceptedFriendIdsProvider);
      final isFriend = friendIds.contains(otherUser.userId);
      if (!isPro && !isFriend) {
        // Free / no-tier + non-friend → show the Pro upsell with the
        // named-opponent context copy (Variant B).
        await showUpgradeCtaSheet(
          context,
          focusTier: SubscriptionTier.pro,
          contextTitle: 'Take on ${otherUser.friendlyName} head-to-head',
          contextDescription:
              'Send a private 1-on-1 challenge to anyone. Available with StepBattle Pro — or free if you\'re already friends.',
        );
        return;
      }
      // Pro / Family → open 1v1 setup with the opponent already picked.
      // Note: NOT using `useRootNavigator: true` here — we already sit
      // on the root navigator (public profile is a root route in
      // [routes.dart]), and mixing root-nav sheets from inside a root
      // route can duplicate the HeroController key and red-screen the
      // app. The existing [Battle1v1SetupSheet] callers that DO use
      // root-nav live inside the shell where they need it to clear the
      // bottom nav — that scenario doesn't apply on this screen.
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => Battle1v1SetupSheet(initialOpponent: otherUser),
      );
    } catch (e, s) {
      // Any failure inside the two sheet flows above should surface as
      // a snackbar instead of a red-screen. The framework's onError
      // hook (main.dart) still logs to Sentry for us.
      AppLogger.session.e('publicProfile:battleTap:failed',
          fields: {'opponent': otherUser.userId}, error: e, stack: s);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn\'t open battle setup. Try again.')),
        );
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Shared chip primitive — filled OR outlined, with spinner while busy
// -----------------------------------------------------------------------------

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  /// Filled = primary affordance (add / respond / battle). Outlined =
  /// secondary / already-done state (requested / friends).
  final bool filled;
  final bool busy;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.filled,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final child = busy
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: filled ? scheme.onPrimary : scheme.primary,
            ),
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    const padding = EdgeInsets.symmetric(vertical: 12);
    if (filled) {
      return FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: padding,
          shape: shape,
        ),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: padding,
        shape: shape,
        side: BorderSide(color: scheme.outlineVariant),
        foregroundColor: scheme.onSurface,
      ),
      child: child,
    );
  }
}

// =============================================================================
// 5-stat row: Level · B/W · XP · Streak · Rank
// =============================================================================

class _PublicStatsRow extends ConsumerWidget {
  final UserModel user;
  const _PublicStatsRow({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rankAsync = ref.watch(otherUserRankProvider(user.userId));
    final rank = rankAsync.valueOrNull?.rank ?? 0;
    final stats = ref.watch(battleWinStatsProvider(user.userId)).valueOrNull;
    final ratio = stats == null ? null : battleWinRatioOf(stats);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatItem(label: 'Level', value: '${user.level}'),
          const _StatGap(),
          _StatItem(
            label: 'B/W',
            value: ratio == null ? '—' : '${(ratio * 100).round()}%',
          ),
          const _StatGap(),
          _StatItem(
            label: 'XP',
            value: _abbreviateXp(user.totalXP),
            valueColor: AppColors.primary,
          ),
          const _StatGap(),
          _StatItem(
            label: 'Streak',
            value: '${user.currentStreak}',
            trailingIcon: const Icon(
              Icons.local_fire_department,
              color: Color(0xFFD97706),
              size: 18,
            ),
          ),
          const _StatGap(),
          _StatItem(
            label: 'Rank',
            value: rank > 0 ? '#$rank' : '—',
          ),
        ],
      ),
    );
  }

  static String _abbreviateXp(int xp) {
    if (xp < 1000) return '$xp';
    if (xp < 10000) return '${(xp / 1000).toStringAsFixed(1)}K';
    if (xp < 1000000) return '${(xp / 1000).round()}K';
    return '${(xp / 1000000).toStringAsFixed(1)}M';
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailingIcon;

  const _StatItem({
    required this.label,
    required this.value,
    this.valueColor,
    this.trailingIcon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            fontWeight: FontWeight.w500,
            fontSize: 11.5,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                color: valueColor ?? AppColors.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 18,
                height: 1.1,
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 4),
              Transform.translate(offset: const Offset(0, 1), child: trailingIcon!),
            ],
          ],
        ),
      ],
    );
  }
}

class _StatGap extends StatelessWidget {
  const _StatGap();
  @override
  Widget build(BuildContext context) => const SizedBox(width: 34);
}

// =============================================================================
// All-time card (always expanded — no collapse for other users)
// =============================================================================

class _AllTimeCard extends ConsumerWidget {
  final UserModel user;
  const _AllTimeCard({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stats = ref.watch(battleWinStatsProvider(user.userId)).valueOrNull;
    final wins = stats?.wins ?? 0;
    final losses = (stats == null) ? 0 : (stats.total - stats.wins);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — icon + title + subtitle. No collapse chevron
          // (this card is always expanded for other users) and no
          // separate "All Time" section title below — the header
          // already says "All-time stats" so the second heading was
          // redundant.
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.query_stats, color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'All-time stats',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Steps, XP, wins — since day one',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // Row 1: Total XP · Battles
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'Total XP',
                  value: _fmt(user.totalXP),
                  valueColor: AppColors.tertiary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatTile(
                  label: 'Battles',
                  child: RichText(
                    text: TextSpan(
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                      children: [
                        TextSpan(
                          text: '${wins}W',
                          style: TextStyle(color: AppColors.primary),
                        ),
                        const TextSpan(text: ' / '),
                        TextSpan(
                          text: '${losses}L',
                          style: TextStyle(color: AppColors.errorDim),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Row 2: Best Streak · Total Steps
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'Best Streak',
                  value: '${user.bestStreak} DAYS',
                  valueColor: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatTile(
                  label: 'Total Steps',
                  value: _fmt(user.totalStepsAllTime),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String? value;
  final Color? valueColor;
  final Widget? child;

  const _StatTile({
    required this.label,
    this.value,
    this.valueColor,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.outline,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          child ??
              Text(
                value ?? '',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: valueColor ?? AppColors.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
        ],
      ),
    );
  }
}

// =============================================================================
// Providers — fetch another user's profile + rank
// =============================================================================

/// Fetches another user's full profile row. Public-readable fields only —
/// RLS strips the rest server-side.
final otherUserProvider = FutureProvider.family<UserModel?, String>(
  (ref, userId) async {
    final svc = ref.read(authServiceProvider);
    return svc.getProfile(userId);
  },
);

/// Fetches another user's global leaderboard position. Returns null when
/// the user has no rank (e.g., just signed up, no XP yet).
final otherUserRankProvider =
    FutureProvider.family<({int rank, int totalXp})?, String>(
  (ref, userId) async {
    try {
      final entry = await LeaderboardService().getMyRank(userId);
      if (entry == null) return null;
      return (rank: entry.rank, totalXp: entry.totalXP);
    } catch (_) {
      return null;
    }
  },
);

// =============================================================================
// Arena peek sheet — quick-stats sheet shown when tapping an avatar in
// the battleground. Tap the sheet to expand to the full public profile.
// =============================================================================

class ArenaProfilePeekSheet extends ConsumerWidget {
  final String userId;
  final VoidCallback onViewFullProfile;
  const ArenaProfilePeekSheet({
    super.key,
    required this.userId,
    required this.onViewFullProfile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asyncUser = ref.watch(otherUserProvider(userId));
    final asyncRank = ref.watch(otherUserRankProvider(userId));
    final asyncStats = ref.watch(battleWinStatsProvider(userId));

    return GestureDetector(
      onTap: onViewFullProfile,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              asyncUser.when(
                loading: () => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
                error: (e, _) => Text(
                  'Could not load: $e',
                  style: TextStyle(color: AppColors.onSurfaceVariant),
                ),
                data: (user) {
                  if (user == null) {
                    return const Text('User not found.');
                  }
                  final rank = asyncRank.valueOrNull?.rank ?? 0;
                  final stats = asyncStats.valueOrNull;
                  final ratio = stats == null ? null : battleWinRatioOf(stats);

                  return Column(
                    children: [
                      AvatarCircle(
                        imageUrl: user.avatarURL,
                        initials: user.friendlyName.isNotEmpty
                            ? user.friendlyName[0].toUpperCase()
                            : '?',
                        radius: 32,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        user.friendlyName.isEmpty ? '—' : user.friendlyName,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      if (user.userCode.isNotEmpty)
                        Text(
                          '@${user.userCode}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.center,
                        children: [
                          _PeekChip(label: 'Lv ${user.level}', color: AppColors.primary),
                          _PeekChip(label: '${user.totalXP} XP', color: AppColors.tertiary),
                          _PeekChip(
                            label: '${user.currentStreak}d Streak',
                            color: AppColors.primary,
                          ),
                          _PeekChip(
                            label: rank > 0 ? '#$rank' : 'Rank --',
                            color: AppColors.secondary,
                          ),
                          _PeekChip(
                            label: ratio == null
                                ? 'B/W --'
                                : 'B/W ${(ratio * 100).toStringAsFixed(0)}%',
                            color: AppColors.amber,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Tap to view full profile',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeekChip extends StatelessWidget {
  final String label;
  final Color color;
  const _PeekChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Convenience opener — shows the peek sheet; tap routes to the full
/// public profile screen at /users/:userId.
Future<void> showArenaProfilePeek(BuildContext context, String userId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    builder: (ctx) => ArenaProfilePeekSheet(
      userId: userId,
      onViewFullProfile: () {
        Navigator.of(ctx).pop();
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => PublicProfileScreen(userId: userId),
          ),
        );
      },
    ),
  );
}
