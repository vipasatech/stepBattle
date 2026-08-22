import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../config/team_colors.dart';
import '../../models/battle_model.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../services/battle_service.dart';
import '../../sheets/add_friends_sheet.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/battle_duration_picker.dart';
import '../../widgets/battle_stake_picker.dart';
import '../../widgets/shimmer_loader.dart';

/// Full-screen team-lobby page — replaces the old `BattleTeamSetupSheet`
/// (which was a modal). Renders both the creator and joiner variants
/// off the same widget, branching on `battle.createdBy == myUid`.
///
/// State machine (creator only):
///   • Stake NOT confirmed (battle.stake_xp = 0): stake picker
///     editable + Confirm-stake CTA at bottom. Invite button hidden;
///     empty-slot taps surface a snackbar prompting to set stake first.
///   • Stake confirmed (battle.stake_xp > 0 + creator stake_paid): stake
///     picker collapses into a locked summary chip, Invite button
///     appears on the TEAMS header row, and the bottom CTA switches
///     to "Start battle now" (enabled once ≥1 non-creator accepted).
///
/// Joiners always see the locked stake summary + read-only duration.
/// Their only action is the Leave button at the bottom.
class TeamLobbyPage extends ConsumerStatefulWidget {
  final String battleId;
  const TeamLobbyPage({super.key, required this.battleId});

  @override
  ConsumerState<TeamLobbyPage> createState() => _TeamLobbyPageState();
}

class _TeamLobbyPageState extends ConsumerState<TeamLobbyPage> {
  int _stakeXp = 100; // draft value; only committed on Confirm stake tap
  bool _confirmingStake = false;
  bool _starting = false;
  bool _cancelling = false;
  bool _leaving = false;

  /// Persistent signal that "the user just tapped Leave themselves." Set
  /// in [_leaveLobby] BEFORE the RPC fires. Consumed by the kick-detect
  /// block in [build] to suppress the "You were removed" snackbar on a
  /// self-leave — the user knows what they did, they don't need a toast
  /// telling them they left. Only a creator-kick (which this flag is
  /// still false for) surfaces the snackbar.
  bool _selfLeavingIntent = false;

  /// One-shot guard for the kick-detect auto-pop in [build]. Without
  /// this the postFrameCallback would fire on every rebuild while the
  /// participant row is `rejected`, spamming the SnackBar queue during
  /// the ~50ms teardown window.
  bool _kickHandled = false;
  static const int _minTeams = 2;
  static const int _maxTeams = 4;
  static const int _maxParticipants = 10;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  Future<void> _confirmStake(BattleModel battle) async {
    if (_confirmingStake) return;
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    setState(() => _confirmingStake = true);
    try {
      await ref.read(battleServiceProvider).confirmStake(
            battleId: battle.battleId,
            actorId: me.userId,
            stakeXp: _stakeXp,
          );
    } on InsufficientXpException {
      _snack('You don\'t have enough XP for this stake.');
    } catch (e) {
      _snack('Could not confirm stake: $e');
    } finally {
      if (mounted) setState(() => _confirmingStake = false);
    }
  }

  Future<void> _onWindowChanged(BattleWindow window) async {
    if (!window.isValid) return;
    try {
      await ref.read(battleServiceProvider).setBattleWindow(
            battleId: widget.battleId,
            startTime: window.start,
            endTime: window.end,
          );
    } catch (e) {
      _snack('Duration update failed: $e');
    }
  }

  Future<void> _setTeamCount(BattleModel battle, int newCount) async {
    // Gate: each team needs at least one active participant to
    // justify existing, so requiring `activeCount >= newCount` blocks
    // creating an empty Team C / D. Without this the button silently
    // succeeds and the roster shows a ghost team with only the "+
    // Add player" placeholder — confusing UX.
    final activeCount = battle.participants
        .where((p) =>
            p.inviteStatus != ParticipantInviteStatus.rejected)
        .length;
    if (newCount > activeCount) {
      final teamLetter = String.fromCharCode('A'.codeUnitAt(0) + newCount - 1);
      await _showAddTeamGuardDialog(
        teamLetter: teamLetter,
        needed: newCount,
        have: activeCount,
      );
      return;
    }
    try {
      await ref.read(battleServiceProvider).setBattleTeamCount(
            battleId: battle.battleId,
            count: newCount,
          );
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  /// Info dialog when the user taps "Add Team X" without enough
  /// players to fill it. Uses the app-root navigator so the dialog
  /// overlays every ancestor (including any bottom sheet the lobby
  /// was launched from) — a plain showDialog on the page context
  /// would render underneath a sheet in the stack.
  Future<void> _showAddTeamGuardDialog({
    required String teamLetter,
    required int needed,
    required int have,
  }) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        icon: Icon(Icons.group_add_outlined,
            color: AppColors.primary, size: 32),
        title: const Text('Add more players'),
        content: Text(
          'Team $teamLetter needs at least $needed players in the lobby '
          '($have joined so far). Invite more friends first, then add Team $teamLetter.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeTeam(BattleModel battle, String label) async {
    if (battle.teamLabels.length <= _minTeams) return;
    if (label == 'A') return; // creator lives here; keep A stable
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: Text('Remove Team $label?'),
        content: Text(
          'Any players on Team $label will be reassigned to Team A.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      // Move members of removed team to A
      for (final p in battle.participants) {
        if (p.teamLabel == label) {
          await ref.read(battleServiceProvider).switchTeam(
                battleId: battle.battleId,
                actorId: battle.createdBy,
                teamLabel: 'A',
                targetUserId: p.userId,
              );
        }
      }
      // Then reduce team count
      await ref.read(battleServiceProvider).setBattleTeamCount(
            battleId: battle.battleId,
            count: battle.teamLabels.length - 1,
          );
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _swapToTeam(BattleModel battle, String label) async {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    final mine = battle.participantFor(me.userId);
    if (mine == null) return;
    if (mine.teamLabel == label) return;
    try {
      await ref.read(battleServiceProvider).switchTeam(
            battleId: battle.battleId,
            actorId: me.userId,
            teamLabel: label,
            targetUserId: me.userId,
          );
    } catch (e) {
      _snack('Move failed: $e');
    }
  }

  Future<void> _invitePlayers(BattleModel battle) async {
    if (battle.stakeXp <= 0) {
      _snack('Confirm the stake first to invite players.');
      return;
    }
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    // Instant-invite mode — each tap on a friend's `+` chip fires an
    // invite immediately. No batch select + confirm button. The sheet
    // shows a spinner per row while the RPC runs, then flips to a
    // green `✓ Sent` chip on success.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddFriendsSheet(
        mode: FriendsSheetMode.picker,
        onInviteImmediately: (u) async {
          // Look up the freshest battle snapshot from the per-battle
          // detail stream (which reacts to any user's row changes on
          // this battle, unlike allBattlesProvider). The `battle`
          // captured above is a build-time value that goes stale
          // between taps.
          final live = ref
              .read(battleDetailProvider(battle.battleId))
              .valueOrNull;
          final source = live ?? battle;

          // Capacity guard — leave room for the creator + this new
          // invitee. Bail with a snackbar if the lobby is full.
          final activeCount = source.participants
              .where((p) =>
                  p.inviteStatus != ParticipantInviteStatus.rejected)
              .length;
          if (activeCount >= _maxParticipants) {
            _snack('Lobby is full.');
            throw StateError('lobby_full');
          }

          // Sequential team-fill: drop into the smallest non-rejected
          // team; ties broken by label (A first).
          final labels = source.teamLabels;
          final counts = <String, int>{for (final l in labels) l: 0};
          for (final p in source.participants) {
            if (p.inviteStatus == ParticipantInviteStatus.rejected) {
              continue;
            }
            final t = p.teamLabel;
            if (t != null && counts.containsKey(t)) {
              counts[t] = counts[t]! + 1;
            }
          }
          var pick = labels.first;
          var picked = counts[pick]!;
          for (final l in labels) {
            final c = counts[l]!;
            if (c < picked) {
              pick = l;
              picked = c;
            }
          }

          await ref
              .read(battleServiceProvider)
              .addTeamLobbyParticipants(battleId: source.battleId, entries: [
            (
              userId: u.userId,
              displayName: u.displayName,
              preferredName: u.preferredName,
              avatarUrl: u.avatarURL,
              teamLabel: pick,
            ),
          ]);
          // No local roster mutation — the realtime hydrator on the
          // page picks up the participant flip once they accept.
        },
      ),
    );
  }

  Future<void> _removePlayer(BattleModel battle, UserModel u) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: Text('Remove ${u.friendlyName} from lobby?'),
        content: const Text(
          "They'll be dropped from the team battle. Any stake they paid is refunded.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      // Creator kick — must use removeParticipantAsCreator (Migration
      // 0058). leaveTeamBattle's underlying refund_participant_stake
      // RPC has an `auth.uid() = p_user_id` self-only check that
      // rejects creator-kick calls with `not_authorized: caller must
      // match participant` (repro'd 2026-08-13).
      await ref.read(battleServiceProvider).removeParticipantAsCreator(
            battleId: battle.battleId,
            targetUserId: u.userId,
          );
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _startNow(BattleModel battle) async {
    if (_starting) return;
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    setState(() => _starting = true);
    try {
      await ref.read(battleServiceProvider).startBattleNow(
            battleId: battle.battleId,
            actorId: me.userId,
          );
      // Route creator straight into the arena. Joiners still on this
      // page will be pushed by battleActivationDetectorProvider (their
      // stream sees the status flip → app.dart router.push).
      if (mounted) {
        // Replace this route with the arena so back-nav lands on
        // wherever the lobby was launched from, not the (now empty)
        // lobby itself. `go_router.pushReplacement` handles the
        // route-stack swap.
        context.pushReplacement('/battle-ground/${battle.battleId}');
      }
    } catch (e) {
      _snack('Failed to start: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _cancelLobby(BattleModel battle) async {
    if (_cancelling) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Cancel this lobby?'),
        content: const Text(
          "Everyone who joined will get their stake back. This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Keep it open',
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel lobby'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      await ref.read(battleServiceProvider).cancelBattle(battle.battleId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _snack('Cancel failed: $e');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  Future<void> _leaveLobby(BattleModel battle) async {
    if (_leaving) return;
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Leave this lobby?'),
        content: Text(
          battle.stakeXp > 0
              ? 'You\'ll get your ${battle.stakeXp} XP stake back. The remaining players stay in the lobby.'
              : 'You\'ll leave the lobby. The remaining players stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    // Signal to the kick-detect block in build() that the incoming
    // `invite_status='rejected'` realtime tick is our own doing — so
    // it silently pops instead of surfacing the "You were removed by
    // the creator" snackbar. See _selfLeavingIntent docstring.
    _selfLeavingIntent = true;
    setState(() => _leaving = true);
    try {
      await ref.read(battleServiceProvider).leaveTeamBattle(
            battleId: battle.battleId,
            userId: me.userId,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _snack('Failed to leave: $e');
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = ref.watch(currentUserProvider).valueOrNull;
    // Realtime read via battleDetailProvider — streams
    // battle_participants for this battle_id (any user), so when a
    // joiner accepts or leaves the creator's UI updates without
    // needing to trigger on the creator's own row. Previously we
    // filtered `allBattlesProvider` down by battleId, but that stream
    // only reacts to changes to the CURRENT user's participant row —
    // the creator's lobby stayed stale after a joiner accepted.
    final battle =
        ref.watch(battleDetailProvider(widget.battleId)).valueOrNull;

    if (battle == null) {
      // Battle not (yet) in the stream — could be a cold-open of a
      // pending card while the stream is still hydrating (typically
      // <500ms). Skeleton with shimmer rather than a spinner so the
      // page feels like it's already there and just filling in — this
      // was reported as "app freezes for a second before entering
      // team lobby" pre-1.1.6+24; the shimmer skeleton makes the
      // hydration wait feel intentional instead of janky.
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('Team lobby'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Start / End date rows
              const ShimmerLoader(height: 56),
              const SizedBox(height: 8),
              const ShimmerLoader(height: 56),
              const SizedBox(height: 16),
              // Stake card
              const ShimmerLoader(height: 72, borderRadius: 16),
              const SizedBox(height: 24),
              // "TEAMS" label + invite action row
              Row(
                children: const [
                  ShimmerLoader(width: 70, height: 14),
                  Spacer(),
                  ShimmerLoader(width: 110, height: 20, borderRadius: 10),
                ],
              ),
              const SizedBox(height: 12),
              // Team A card
              const ShimmerLoader(height: 130, borderRadius: 16),
              const SizedBox(height: 12),
              // Team B card
              const ShimmerLoader(height: 130, borderRadius: 16),
              const SizedBox(height: 20),
              // Add team button
              const ShimmerLoader(height: 44, borderRadius: 22),
              const SizedBox(height: 12),
              // Bottom CTA
              const ShimmerLoader(height: 52, borderRadius: 26),
            ],
          ),
        ),
      );
    }

    // If the battle transitioned out of pending (activated or cancelled)
    // pop the page — user should be back on the Battles tab / arena.
    if (battle.status != BattleStatus.pending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }

    final isCreator = me != null && battle.createdBy == me.userId;
    final stakeLocked = battle.stakeXp > 0;

    // Kick-detect auto-pop: if the current user is a NON-CREATOR whose
    // participant row just transitioned to `rejected` (or vanished),
    // they were either kicked by the creator (Migration 0058's
    // creator_remove_participant RPC) or self-left. Either way, they
    // shouldn't be sitting on the lobby page.
    //
    // Prior to 1.1.6+25 this scenario left the kicked user stranded —
    // the page only auto-popped on `battle.status` changes, but a
    // kick only flips `battle_participants.invite_status`. Reported
    // 2026-08-13: "the profile in the team is being removed but not
    // kicked away from the team lobby page."
    //
    // Creator is intentionally excluded — the RPC forbids creators
    // kicking themselves (`creator_cannot_remove_self`), and the
    // creator's own path out of the lobby is Cancel lobby → battle
    // status flips → handled by the existing status-check above.
    if (me != null && !isCreator && !_kickHandled) {
      final myParticipant = battle.participantFor(me.userId);
      final wasKicked = myParticipant == null ||
          myParticipant.inviteStatus == ParticipantInviteStatus.rejected;
      if (wasKicked) {
        _kickHandled = true;
        final showSnackbar = !_selfLeavingIntent;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (showSnackbar) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  battle.stakeXp > 0
                      ? 'You were removed from this battle. Your ${battle.stakeXp} XP stake was refunded.'
                      : 'You were removed from this battle.',
                ),
                duration: const Duration(seconds: 4),
              ),
            );
          }
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            // No route to pop back to (e.g. deep-linked into the lobby
            // via a notification tap) — send them to Battles tab.
            context.go('/battles');
          }
        });
      }
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Team lobby'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          children: [
            // Header — title + Battle ID (Batch A r3 spec)
            Text(
              'Team battle',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              'BATTLE ID · ${battle.shortId}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            _JoinCodeBar(code: battle.joinCode ?? ''),
            const SizedBox(height: 10),
            _CountdownPill(battle: battle),
            const SizedBox(height: 18),
            if (isCreator)
              _CreatorBody(
                battle: battle,
                stakeLocked: stakeLocked,
                draftStake: _stakeXp,
                onStakeDraftChanged: (v) =>
                    setState(() => _stakeXp = v),
                onWindowChanged: _onWindowChanged,
                onSetTeamCount: (n) => _setTeamCount(battle, n),
                onRemoveTeam: (l) => _removeTeam(battle, l),
                onSwapToTeam: (l) => _swapToTeam(battle, l),
                onInvitePlayers: () => _invitePlayers(battle),
                onRemovePlayer: (u) => _removePlayer(battle, u),
                // Inside `isCreator`, me is guaranteed non-null (see
                // `isCreator = me != null && battle.createdBy == me.userId`)
                // and Dart flow analysis has already narrowed it.
                currentUserId: me.userId,
                maxTeams: _maxTeams,
                minTeams: _minTeams,
              )
            else
              _JoinerBody(
                battle: battle,
                onSwapToTeam: (l) => _swapToTeam(battle, l),
                currentUserId: me?.userId ?? '',
              ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomBar(
        battle: battle,
        isCreator: isCreator,
        stakeLocked: stakeLocked,
        confirmingStake: _confirmingStake,
        starting: _starting,
        cancelling: _cancelling,
        leaving: _leaving,
        onConfirmStake: () => _confirmStake(battle),
        onStartNow: () => _startNow(battle),
        onCancel: () => _cancelLobby(battle),
        onLeave: () => _leaveLobby(battle),
      ),
    );
  }
}

// =============================================================================
// Sub-widgets
// =============================================================================

class _JoinCodeBar extends StatelessWidget {
  final String code;
  const _JoinCodeBar({required this.code});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.vpn_key, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Text('Join code',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.onSurfaceVariant)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              code,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 4,
                color: AppColors.primary,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Join code copied')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CountdownPill extends StatelessWidget {
  final BattleModel battle;
  const _CountdownPill({required this.battle});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expiry = battle.pendingExpiresAt;
    if (expiry == null) return const SizedBox.shrink();
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
      builder: (context, _) {
        final r = expiry.difference(DateTime.now());
        final label = r.isNegative
            ? 'Resolving…'
            : r.inMinutes >= 1
                ? 'Lobby closes in ${r.inMinutes}m ${r.inSeconds % 60}s'
                : 'Lobby closes in ${r.inSeconds}s';
        final urgent = !r.isNegative && r.inMinutes < 2;
        final tint = urgent ? AppColors.amber : AppColors.primary;
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: tint.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.timer_outlined, size: 14, color: tint),
                const SizedBox(width: 6),
                Text(label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: tint,
                      fontWeight: FontWeight.w800,
                    )),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CreatorBody extends StatelessWidget {
  final BattleModel battle;
  final bool stakeLocked;
  final int draftStake;
  final ValueChanged<int> onStakeDraftChanged;
  final ValueChanged<BattleWindow> onWindowChanged;
  final ValueChanged<int> onSetTeamCount;
  final ValueChanged<String> onRemoveTeam;
  final ValueChanged<String> onSwapToTeam;
  final VoidCallback onInvitePlayers;
  final void Function(UserModel) onRemovePlayer;
  final String currentUserId;
  final int minTeams;
  final int maxTeams;

  const _CreatorBody({
    required this.battle,
    required this.stakeLocked,
    required this.draftStake,
    required this.onStakeDraftChanged,
    required this.onWindowChanged,
    required this.onSetTeamCount,
    required this.onRemoveTeam,
    required this.onSwapToTeam,
    required this.onInvitePlayers,
    required this.onRemovePlayer,
    required this.currentUserId,
    required this.minTeams,
    required this.maxTeams,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = battle.teamLabels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BattleDurationPicker(onChanged: onWindowChanged),
        const SizedBox(height: 18),
        if (!stakeLocked) ...[
          BattleStakePicker(
            value: draftStake,
            onChanged: onStakeDraftChanged,
            participantsCount: labels.length.clamp(2, 4),
          ),
          const SizedBox(height: 6),
          Text(
            'Confirm the stake below — it locks once you do, so nobody\ngets an unexpected charge later.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ] else
          _LockedStakeSummary(stakeXp: battle.stakeXp),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: Text(
                'TEAMS',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (stakeLocked)
              TextButton.icon(
                onPressed: onInvitePlayers,
                icon:
                    const Icon(Icons.group_add_outlined, size: 18),
                label: const Text('Invite players'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Double-tap a team to move yourself there.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 10),
        for (final label in labels)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _TeamCard(
              battle: battle,
              label: label,
              currentUserId: currentUserId,
              isCreator: true,
              canRemoveTeam: label != 'A' && labels.length > minTeams,
              onDoubleTapCard: () => onSwapToTeam(label),
              onRemoveTeam: () => onRemoveTeam(label),
              onInvitePlayers: onInvitePlayers,
              onRemovePlayer: onRemovePlayer,
              stakeLocked: stakeLocked,
            ),
          ),
        if (labels.length < maxTeams)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => onSetTeamCount(labels.length + 1),
              icon: const Icon(Icons.add, size: 18),
              label: Text(
                'Add Team ${String.fromCharCode(65 + labels.length)}',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _JoinerBody extends StatelessWidget {
  final BattleModel battle;
  final ValueChanged<String> onSwapToTeam;
  final String currentUserId;

  const _JoinerBody({
    required this.battle,
    required this.onSwapToTeam,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = battle.teamLabels;
    // Duration read-only summary
    final duration = battle.endTime.difference(battle.startTime);
    final dLabel = duration.inDays >= 1
        ? '${duration.inDays} day${duration.inDays == 1 ? "" : "s"}'
        : '${duration.inHours} hour${duration.inHours == 1 ? "" : "s"}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'BATTLE DURATION',
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.calendar_today,
                  size: 14, color: AppColors.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                '$dLabel  ·  Ends ${_dayShort(battle.endTime)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _LockedStakeSummary(
          stakeXp: battle.stakeXp,
          youPaid: battle.stakeXp,
        ),
        const SizedBox(height: 22),
        Text(
          'TEAMS',
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Double-tap a team to move yourself there.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 10),
        for (final label in labels)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _TeamCard(
              battle: battle,
              label: label,
              currentUserId: currentUserId,
              isCreator: false,
              canRemoveTeam: false,
              onDoubleTapCard: () => onSwapToTeam(label),
              onRemoveTeam: () {},
              onInvitePlayers: () {},
              onRemovePlayer: (_) {},
              stakeLocked: true,
            ),
          ),
      ],
    );
  }

  static String _dayShort(DateTime t) {
    const wk = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${wk[t.weekday - 1]}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

class _LockedStakeSummary extends StatelessWidget {
  final int stakeXp;
  final int? youPaid;
  const _LockedStakeSummary({required this.stakeXp, this.youPaid});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock, size: 14, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(
                'STAKE · LOCKED',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.primary,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Each player pays $stakeXp XP',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (youPaid != null) ...[
            const SizedBox(height: 2),
            Text(
              'You paid: $youPaid XP',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TeamCard extends StatelessWidget {
  final BattleModel battle;
  final String label;
  final String currentUserId;
  final bool isCreator;
  final bool canRemoveTeam;
  final VoidCallback onDoubleTapCard;
  final VoidCallback onRemoveTeam;
  final VoidCallback onInvitePlayers;
  final void Function(UserModel) onRemovePlayer;
  final bool stakeLocked;

  const _TeamCard({
    required this.battle,
    required this.label,
    required this.currentUserId,
    required this.isCreator,
    required this.canRemoveTeam,
    required this.onDoubleTapCard,
    required this.onRemoveTeam,
    required this.onInvitePlayers,
    required this.onRemovePlayer,
    required this.stakeLocked,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = TeamColors.forLabel(label);
    // Accepted members render at full opacity; pending invitees render
    // dimmed with a small hourglass badge so the creator can see WHO
    // they've invited but who hasn't responded yet. Previously the
    // filter dropped pending rows entirely, so it looked like the
    // invite vanished from the creator's UI the moment they sent it.
    final accepted = battle.participants
        .where((p) =>
            p.inviteStatus == ParticipantInviteStatus.accepted &&
            p.teamLabel == label)
        .toList();
    final pending = battle.participants
        .where((p) =>
            p.inviteStatus == ParticipantInviteStatus.pending &&
            p.teamLabel == label)
        .toList();
    // Ordered roster: accepted first, then pending. Total tiles
    // = accepted + pending (up to 4 shown), padded with empty slots.
    final roster = [...accepted, ...pending];
    final myTeam = battle
        .participantFor(currentUserId)
        ?.teamLabel;
    final isMyTeam = myTeam == label;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: isMyTeam ? null : onDoubleTapCard,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Team $label',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
                if (isMyTeam)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        accent,
                        accent.withValues(alpha: 0.55),
                      ]),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.home,
                        size: 14, color: Colors.white),
                  ),
                if (canRemoveTeam) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: onRemoveTeam,
                    child: Icon(Icons.close,
                        size: 16, color: AppColors.error),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                children: [
                  for (final p in roster) ...[
                    _MemberTile(
                      user: _asUserModel(p),
                      accent: accent,
                      isCreator: p.userId == battle.createdBy,
                      // Pending invitees render at reduced opacity with
                      // an hourglass badge; creator can still long-press
                      // to remove (cancels the invite).
                      isPending:
                          p.inviteStatus == ParticipantInviteStatus.pending,
                      onLongPress: (isCreator &&
                              p.userId != currentUserId)
                          ? () => onRemovePlayer(_asUserModel(p))
                          : null,
                    ),
                    const SizedBox(width: 6),
                  ],
                  // Pad up to 4 slots with empty silhouettes
                  for (var i = 0;
                      i < (4 - roster.length).clamp(0, 4);
                      i++) ...[
                    _EmptySlotTile(
                      accent: accent,
                      onTap: stakeLocked && isCreator
                          ? onInvitePlayers
                          : null,
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (isCreator)
                    _AddPlayerTile(
                      accent: accent,
                      onTap: stakeLocked ? onInvitePlayers : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static UserModel _asUserModel(BattleParticipant p) {
    final now = DateTime.now();
    return UserModel(
      userId: p.userId,
      userCode: '',
      displayName: p.friendlyName,
      email: '',
      avatarURL: p.avatarURL,
      createdAt: now,
      lastActiveAt: now,
    );
  }
}

class _MemberTile extends StatelessWidget {
  final UserModel user;
  final Color accent;
  final bool isCreator;
  final bool isPending;
  final VoidCallback? onLongPress;
  const _MemberTile({
    required this.user,
    required this.accent,
    required this.isCreator,
    this.isPending = false,
    this.onLongPress,
  });
  @override
  Widget build(BuildContext context) {
    final initials = user.friendlyName.isNotEmpty
        ? user.friendlyName[0].toUpperCase()
        : '?';
    final avatarUrl = user.avatarURL;
    // Pending invitees render at reduced opacity so the roster reads
    // clearly as "accepted vs waiting". A small hourglass badge in the
    // bottom-right corner reinforces the state.
    final tileOpacity = isPending ? 0.45 : 1.0;
    return GestureDetector(
      onLongPress: onLongPress,
      child: Opacity(
        opacity: tileOpacity,
        child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 40×40 rounded-square tile. If we have a real avatar URL,
          // render the photo (rounded to match the tile shape) with an
          // accent-tinted border; otherwise fall back to the coloured
          // initial. Previously only the initial ever rendered — the
          // avatar URL was passed in and ignored.
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: accent.withValues(alpha: 0.55),
                width: 1.2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: (avatarUrl != null && avatarUrl.isNotEmpty)
                ? AvatarCircle(
                    radius: 20,
                    imageUrl: avatarUrl,
                    initials: initials,
                    borderColor: Colors.transparent,
                  )
                : Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                  ),
          ),
          if (isPending)
            Positioned(
              bottom: -3,
              right: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: AppColors.onSurfaceVariant,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.surfaceContainerLow,
                    width: 1.2,
                  ),
                ),
                child: const Icon(Icons.hourglass_top,
                    size: 8, color: Colors.white),
              ),
            ),
          if (isCreator)
            Positioned(
              top: -3,
              right: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    accent,
                    accent.withValues(alpha: 0.6),
                  ]),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.surfaceContainerLow,
                    width: 1.2,
                  ),
                ),
                child: const Icon(Icons.home,
                    size: 8, color: Colors.white),
              ),
            ),
        ],
        ),
      ),
    );
  }
}

class _EmptySlotTile extends StatelessWidget {
  final Color accent;
  final VoidCallback? onTap;
  const _EmptySlotTile({required this.accent, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: accent.withValues(alpha: 0.2),
          ),
        ),
        child: Icon(Icons.person_outline,
            size: 22, color: accent.withValues(alpha: 0.5)),
      ),
    );
  }
}

class _AddPlayerTile extends StatelessWidget {
  final Color accent;
  final VoidCallback? onTap;
  const _AddPlayerTile({required this.accent, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: accent.withValues(alpha: 0.45),
          ),
        ),
        child: Icon(Icons.add, size: 22, color: accent),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final BattleModel battle;
  final bool isCreator;
  final bool stakeLocked;
  final bool confirmingStake;
  final bool starting;
  final bool cancelling;
  final bool leaving;
  final VoidCallback onConfirmStake;
  final VoidCallback onStartNow;
  final VoidCallback onCancel;
  final VoidCallback onLeave;

  const _BottomBar({
    required this.battle,
    required this.isCreator,
    required this.stakeLocked,
    required this.confirmingStake,
    required this.starting,
    required this.cancelling,
    required this.leaving,
    required this.onConfirmStake,
    required this.onStartNow,
    required this.onCancel,
    required this.onLeave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!isCreator) {
      // Joiner bar: leave button only
      return SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: OutlinedButton.icon(
          onPressed: leaving ? null : onLeave,
          icon: Icon(Icons.logout, color: AppColors.error),
          label: Text(
            'Leave lobby & refund my stake',
            style: TextStyle(color: AppColors.error),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      );
    }
    // Creator bar
    if (!stakeLocked) {
      // State A — Confirm stake
      return SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: confirmingStake ? null : onConfirmStake,
                child: confirmingStake
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Confirm stake'),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: cancelling ? null : onCancel,
              child: Text(
                'Cancel lobby',
                style: TextStyle(color: AppColors.error),
              ),
            ),
          ],
        ),
      );
    }
    // State B — Start now
    final nonCreatorAccepted = battle.participants
        .where((p) =>
            p.inviteStatus == ParticipantInviteStatus.accepted &&
            p.userId != battle.createdBy)
        .length;
    final teamsWithMembers = <String>{
      for (final p in battle.participants)
        if (p.inviteStatus == ParticipantInviteStatus.accepted &&
            p.teamLabel != null)
          p.teamLabel!,
    };
    final canStart =
        nonCreatorAccepted >= 1 && teamsWithMembers.length >= 2;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: canStart && !starting ? onStartNow : null,
              child: starting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Start battle now'),
            ),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: cancelling ? null : onCancel,
            icon: Icon(Icons.cancel_outlined,
                size: 16, color: AppColors.error),
            label: Text(
              'Cancel lobby & refund everyone',
              style: TextStyle(color: AppColors.error),
            ),
          ),
          if (!canStart)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Need ≥1 acceptor and members on ≥2 teams to start.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
