import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../config/team_colors.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../utils/app_logger.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/battle_duration_picker.dart';
import '../widgets/bottom_sheet_handle.dart';
import 'add_friends_sheet.dart';

/// Team battle setup — **draft-first** lobby flow with dispose cleanup.
///
/// Sheet opens → `createTeamLobby` lands a pending row in Supabase so the
/// join code is shareable immediately + edits sync server-side as the
/// creator works. There's one CTA — **Create** — which calls
/// [BattleService.fanoutTeamLobbyInvites] to notify invitees and pops the
/// sheet. If the user dismisses the sheet (swipe down, back gesture, etc.)
/// without tapping Create, the State's `dispose` fires a hard delete of
/// the draft row.
///
/// Capacity rules:
///   • 2–4 teams (Q1, default 2).
///   • Up to 10 participants total across all teams (Q2).
class BattleTeamSetupSheet extends ConsumerStatefulWidget {
  const BattleTeamSetupSheet({super.key});

  @override
  ConsumerState<BattleTeamSetupSheet> createState() =>
      _BattleTeamSetupSheetState();
}

class _BattleTeamSetupSheetState extends ConsumerState<BattleTeamSetupSheet> {
  static const int _maxParticipants = 10;
  static const int _minTeams = 2;
  static const int _maxTeams = 4;

  // Lobby state — set by [_initLobby].
  String? _battleId;
  String? _joinCode;
  bool _lobbyReady = false;
  String? _lobbyError;
  bool _sending = false;

  int _teamCount = 2;

  final Map<String, ({UserModel user, String teamLabel})> _roster = {};
  final Map<String, String> _teamNames = {};

  /// Held outside Riverpod so we can still reach the service from dispose()
  /// after the widget tree is gone.
  late final BattleService _battleService;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  List<String> get _labels =>
      List.generate(_teamCount, (i) => String.fromCharCode(65 + i));

  String _displayName(String label) => _teamNames[label] ?? 'Team $label';

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _battleService = ref.read(battleServiceProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initLobby());
  }

  @override
  void dispose() {
    // Per Batch 4b-2 spec: closing the sheet no longer terminates the
    // lobby. The battle row lives on with its 10-min `pending_expires_at`
    // (Migration 0042); if no one joins in time the cron auto-cancels +
    // refunds every paid participant. The creator can also explicitly
    // cancel from the sheet's Cancel button (see _cancelLobby below).
    super.dispose();
  }

  Future<void> _initLobby() async {
    try {
      final me = await ref.read(currentUserProvider.future);
      if (me == null) throw StateError('Not signed in');
      final result = await _battleService.createTeamLobby(
        createdBy: me.userId,
        creatorDisplayName: me.displayName.isEmpty ? 'You' : me.displayName,
        creatorPreferredName: me.preferredName,
        creatorAvatarUrl: me.avatarURL,
      );
      if (!mounted) return;
      setState(() {
        _battleId = result.battleId;
        _joinCode = result.joinCode;
        _lobbyReady = true;
        // Seed the creator into the local roster so they render on
        // Team A immediately (the server-side insert in
        // createTeamLobby stamps team_label='A' + invite_status =
        // 'accepted'; without this local seed the sheet showed an
        // empty Team A until a friend was invited).
        _roster[me.userId] = (user: me, teamLabel: 'A');
      });
    } catch (e) {
      AppLogger.battle.e('teamLobby:init_failed', error: e);
      if (!mounted) return;
      setState(() => _lobbyError = e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Mutations — optimistic local update + server sync, rollback on error.
  // ---------------------------------------------------------------------------

  Future<void> _addPlayers(String targetLabel) async {
    if (_battleId == null) return;
    if (_roster.length + 1 >= _maxParticipants) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddFriendsSheet(
        mode: FriendsSheetMode.picker,
        confirmLabel: 'Add to $targetLabel',
        onConfirm: (selected) async {
          final newOnes = <UserModel>[];
          for (final u in selected) {
            if (_roster.containsKey(u.userId)) continue;
            if (_roster.length + newOnes.length + 1 >= _maxParticipants) break;
            newOnes.add(u);
          }
          if (newOnes.isEmpty) return;
          try {
            await _battleService.addTeamLobbyParticipants(
              battleId: _battleId!,
              entries: newOnes
                  .map((u) => (
                        userId: u.userId,
                        displayName: u.displayName,
                        preferredName: u.preferredName,
                        avatarUrl: u.avatarURL,
                        teamLabel: targetLabel,
                      ))
                  .toList(),
            );
            // Per Batch A #2c: no local roster add on invite. The
            // invitee sits as `pending` server-side; they show up in
            // team columns via realtime sync (see build()) only after
            // they accept. Snackbar confirms the invite went out.
            if (mounted) {
              _snack('Invite sent — they join the team once they accept.');
            }
          } catch (e) {
            _snack('Add failed: $e');
          }
        },
      ),
    );
  }

  /// Global invite entry-point (Batch 4b-2). Opens the friend picker
  /// once and distributes selected users across teams sequentially —
  /// fills Team A first, then B, then C/D. Balanced teams by default;
  /// the invitee can double-tap their chip afterward to swap.
  ///
  /// Team target cap = ceil(_maxParticipants / _teamCount) so no team
  /// can exceed its fair share on the first pass. Any overflow (which
  /// shouldn't happen given _maxParticipants=10 & _teamCount ≤ 4)
  /// falls to the last non-full team.
  Future<void> _invitePlayersGlobal() async {
    if (_battleId == null) return;
    if (_roster.length + 1 >= _maxParticipants) {
      _snack('Lobby is full.');
      return;
    }
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddFriendsSheet(
        mode: FriendsSheetMode.picker,
        confirmLabel: 'Invite',
        onConfirm: (selected) async {
          final newOnes = <UserModel>[];
          for (final u in selected) {
            if (_roster.containsKey(u.userId)) continue;
            if (_roster.length + newOnes.length + 1 >=
                _maxParticipants) {
              break;
            }
            newOnes.add(u);
          }
          if (newOnes.isEmpty) return;

          // Sequential-fill assignment. Snapshot per-team headcounts
          // (starting from current lobby state) and drop each new
          // invitee into the smallest team, breaking ties by label
          // order so Team A fills first.
          final counts = <String, int>{
            for (final l in _labels) l: 0,
          };
          for (final e in _roster.values) {
            counts[e.teamLabel] = (counts[e.teamLabel] ?? 0) + 1;
          }
          final assignments = <({
            UserModel user,
            String teamLabel,
          })>[];
          for (final u in newOnes) {
            // Pick the label with the smallest count; earlier label
            // wins on tie (A < B < C < D).
            String pick = _labels.first;
            var picked = counts[pick]!;
            for (final l in _labels) {
              final c = counts[l]!;
              if (c < picked) {
                pick = l;
                picked = c;
              }
            }
            assignments.add((user: u, teamLabel: pick));
            counts[pick] = picked + 1;
          }

          try {
            await _battleService.addTeamLobbyParticipants(
              battleId: _battleId!,
              entries: assignments
                  .map((a) => (
                        userId: a.user.userId,
                        displayName: a.user.displayName,
                        preferredName: a.user.preferredName,
                        avatarUrl: a.user.avatarURL,
                        teamLabel: a.teamLabel,
                      ))
                  .toList(),
            );
            // Batch A #2c: no local roster add. Invitees join the
            // visible lobby only after they accept — server-side
            // realtime sync flips them into `_roster` via build().
            if (mounted) {
              final n = assignments.length;
              _snack(
                  '$n invite${n == 1 ? "" : "s"} sent — they join once they accept.');
            }
          } catch (e) {
            _snack('Add failed: $e');
          }
        },
      ),
    );
  }

  /// Creator-only "abandon this lobby now" action. Explicitly refunds
  /// every paid stake via [BattleService.refundAllStakes], marks the
  /// battle cancelled, and closes the sheet. Confirms first — this is
  /// irreversible and takes real XP off the ledger.
  Future<void> _cancelLobby() async {
    if (_battleId == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Cancel this lobby?'),
        content: const Text(
          'Everyone who joined will get their stake back. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Keep it open',
                style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel lobby'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      // cancelBattle already runs refundAllStakes internally, so we
      // don't chain them here — that would double-invoke the refund
      // RPC (harmless due to the stake_paid idempotency flag, but
      // wasteful).
      await _battleService.cancelBattle(_battleId!);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      _snack('Cancel failed: $e');
    }
  }

  Future<void> _moveToTeam(String userId, String label) async {
    if (_battleId == null) return;
    final me = await ref.read(currentUserProvider.future);
    if (me == null) return;
    // Per Batch 4 spec: each user moves only themselves. Creator has
    // no swap-others superpower (Start/Cancel are their only admin
    // actions). Blocking client-side is defense-in-depth; the RLS on
    // battle_participants scopes updates to auth.uid() = user_id
    // anyway, so a bypass attempt would fail server-side too.
    if (userId != me.userId) {
      _snack("You can only move yourself between teams.");
      return;
    }
    final entry = _roster[userId];
    if (entry == null) return;
    final prev = entry.teamLabel;
    setState(() {
      _roster[userId] = (user: entry.user, teamLabel: label);
    });
    try {
      await _battleService.switchTeam(
        battleId: _battleId!,
        actorId: me.userId,
        teamLabel: label,
        targetUserId: userId,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _roster[userId] = (user: entry.user, teamLabel: prev);
      });
      _snack('Move failed: $e');
    }
  }

  Future<void> _removePlayer(String userId) async {
    if (_battleId == null) return;
    final entry = _roster[userId];
    if (entry == null) return;
    setState(() => _roster.remove(userId));
    try {
      await _battleService.removeTeamLobbyParticipant(
        battleId: _battleId!,
        userId: userId,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _roster[userId] = entry);
      _snack('Remove failed: $e');
    }
  }

  /// Remove a SPECIFIC team (not just the last one). Workflow:
  ///   1. Confirm with the user.
  ///   2. Move all members of [label] to Team A.
  ///   3. Shift every subsequent team's members down one slot
  ///      (e.g. removing B → C becomes B, D becomes C). Keeps the
  ///      label set A..N contiguous so the labels in _labels stay
  ///      aligned with the rendered cards.
  ///   4. Drop the now-empty last label by decrementing the team count.
  Future<void> _removeSpecificTeam(String label) async {
    if (_teamCount <= _minTeams) return;
    // Never remove Team A — the creator is always on A and labels
    // wouldn't have a stable "shift target" without it.
    if (label == 'A') return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text('Remove Team ${_displayName(label)}?'),
        content: Text(
          'Any players on Team ${_displayName(label)} will be reassigned to Team ${_displayName('A')}.',
          style: TextStyle(color: AppColors.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // 1. Move members of `label` → A.
    final labelMembers = _roster.entries
        .where((e) => e.value.teamLabel == label)
        .map((e) => e.key)
        .toList();
    for (final uid in labelMembers) {
      await _moveToTeam(uid, 'A');
    }

    // 2. Shift every later team down one slot.
    final allLabels =
        List<String>.generate(_teamCount, (i) => String.fromCharCode(65 + i));
    final removedIdx = allLabels.indexOf(label);
    for (var i = removedIdx + 1; i < allLabels.length; i++) {
      final from = allLabels[i];
      final to = allLabels[i - 1];
      final fromMembers = _roster.entries
          .where((e) => e.value.teamLabel == from)
          .map((e) => e.key)
          .toList();
      for (final uid in fromMembers) {
        await _moveToTeam(uid, to);
      }
      // Shift the friendly name down too.
      if (_teamNames.containsKey(from)) {
        setState(() {
          _teamNames[to] = _teamNames[from]!;
          _teamNames.remove(from);
        });
      }
    }

    // 3. Drop the now-empty last slot.
    await _setTeamCount(_teamCount - 1);
  }

  Future<void> _setTeamCount(int n) async {
    if (_battleId == null) return;
    if (n < _minTeams || n > _maxTeams) return;

    final prevCount = _teamCount;
    final prevRoster =
        Map<String, ({UserModel user, String teamLabel})>.from(_roster);
    final prevNames = Map<String, String>.from(_teamNames);

    setState(() {
      _teamCount = n;
      final live = _labels.toSet();
      for (final id in _roster.keys.toList()) {
        final e = _roster[id]!;
        if (!live.contains(e.teamLabel)) {
          _roster[id] = (user: e.user, teamLabel: 'A');
        }
      }
      _teamNames.removeWhere((k, _) => !live.contains(k));
    });

    try {
      await _battleService.setBattleTeamCount(
        battleId: _battleId!,
        count: n,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _teamCount = prevCount;
        _roster
          ..clear()
          ..addAll(prevRoster);
        _teamNames
          ..clear()
          ..addAll(prevNames);
      });
      _snack('Team count change failed: $e');
    }
  }

  Future<void> _renameTeam(String label) async {
    if (_battleId == null) return;
    final controller = TextEditingController(text: _displayName(label));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: const Text('Rename team'),
        content: TextField(
          controller: controller,
          maxLength: 24,
          decoration: const InputDecoration(hintText: 'Team name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    final prev = _teamNames[label];
    setState(() => _teamNames[label] = result);
    try {
      await _battleService.renameTeam(
        battleId: _battleId!,
        teamLabel: label,
        newName: result,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (prev == null) {
          _teamNames.remove(label);
        } else {
          _teamNames[label] = prev;
        }
      });
      _snack('Rename failed: $e');
    }
  }

  // (Public/Private toggle removed from team battles per Batch A #1 —
  // team lobbies are invite-only by design. `_setVisibility` was
  // deleted with the toggle; team battles now stay `private` for
  // their entire lifecycle.)

  void _onWindowChanged(BattleWindow window) {
    final battleId = _battleId;
    if (battleId == null) return;
    if (!window.isValid) return;
    _battleService
        .setBattleWindow(
      battleId: battleId,
      startTime: window.start,
      endTime: window.end,
    )
        .catchError((e) {
      AppLogger.battle.e('setBattleWindow:failed',
          fields: {'battleId': battleId}, error: e);
    });
  }

  // ---------------------------------------------------------------------------
  // Create — fans out invite notifications to every non-creator
  // participant so they see the invite in their notification centre.
  // The battle row itself already exists (created on sheet open); this
  // step just kicks the invite fanout.
  // ---------------------------------------------------------------------------

  bool get _canCreate {
    if (_sending) return false;
    if (_battleId == null) return false;
    if (_roster.isEmpty) return false;
    // Need members on at least 2 teams (the creator is on A by default).
    final liveTeams = <String>{'A'};
    for (final e in _roster.values) {
      liveTeams.add(e.teamLabel);
    }
    return liveTeams.length >= 2;
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() => _sending = true);
    try {
      await _battleService.fanoutTeamLobbyInvites(battleId: _battleId!);
      if (!mounted) return;
      Navigator.pop(context);
      await _showJoinCodeDialog(_joinCode!);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Failed to send invites: $e');
    }
  }

  Future<void> _showJoinCodeDialog(String code) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: const Text(
          'Team Battle Created',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Invites sent. Share this code so anyone can join:',
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => Clipboard.setData(ClipboardData(text: code)),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      code,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 6,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(Icons.content_copy,
                        size: 18, color: AppColors.primary),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // creator counts
    final totalPlayers = _roster.length + 1;

    // Realtime sync (#2c): pull the pending battle's accepted
    // participants from allBattlesProvider and reconcile with the
    // local `_roster`. Invitees don't appear in the roster until they
    // flip to invite_status='accepted' server-side — pending rows are
    // filtered out here.
    //
    // Local mutations (double-tap swap on your own chip) still work
    // optimistically; realtime overwrites them on next emission if the
    // server confirms a different value. Rare in practice — the swap
    // RPC round-trips in <1s.
    ref.listen<AsyncValue<List<BattleModel>>>(
      allBattlesProvider,
      (prev, next) {
        final battleId = _battleId;
        if (battleId == null) return;
        final rows = next.valueOrNull;
        if (rows == null) return;
        final battle = rows
            .where((b) => b.battleId == battleId)
            .cast<BattleModel?>()
            .firstWhere((_) => true, orElse: () => null);
        if (battle == null) return;
        final acceptedIds = <String>{};
        final updates = <String, ({UserModel user, String teamLabel})>{};
        for (final p in battle.participants) {
          if (p.inviteStatus != ParticipantInviteStatus.accepted) continue;
          acceptedIds.add(p.userId);
          // Only add participants we don't already have — preserves
          // any optimistic swap state in _roster that a laggy stream
          // would otherwise clobber.
          if (!_roster.containsKey(p.userId)) {
            // Synthesize a minimal UserModel from the participant
            // record — the chip only reads friendlyName + avatarURL,
            // the other required fields are stubbed with sane defaults.
            final now = DateTime.now();
            updates[p.userId] = (
              user: UserModel(
                userId: p.userId,
                userCode: '',
                displayName: p.friendlyName,
                email: '',
                avatarURL: p.avatarURL,
                createdAt: now,
                lastActiveAt: now,
              ),
              teamLabel: p.teamLabel ?? 'A',
            );
          }
        }
        // Also drop any local entries whose participant row is no
        // longer accepted (kicked, left, rejected).
        final removals = <String>[
          for (final k in _roster.keys)
            if (!acceptedIds.contains(k)) k,
        ];
        if (updates.isEmpty && removals.isEmpty) return;
        setState(() {
          _roster.addAll(updates);
          for (final k in removals) {
            _roster.remove(k);
          }
        });
      },
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: _lobbyError != null
            ? _LobbyErrorView(message: _lobbyError!)
            : !_lobbyReady
                ? const _LobbyLoadingView()
                : _buildReadyView(
                    theme: theme,
                    scrollController: scrollController,
                    totalPlayers: totalPlayers,
                  ),
      ),
    );
  }

  Widget _buildReadyView({
    required ThemeData theme,
    required ScrollController scrollController,
    required int totalPlayers,
  }) {
    return Column(
      children: [
        const BottomSheetHandle(),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('TEAM BATTLE',
                            style: theme.textTheme.headlineSmall?.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700)),
                        Text(
                          '$_teamCount teams · up to $_maxParticipants players',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: AppColors.onSurfaceVariant,
                              letterSpacing: 1),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$totalPlayers / $_maxParticipants',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_joinCode != null) _ShareCodeBar(code: _joinCode!),
              // 10-min lobby countdown — read straight off the pending
              // battle row's `pending_expires_at` (Migration 0042
              // stamps this at insert). Live-ticks via `Stream.periodic`
              // so the label decrements without the whole sheet
              // rebuilding. Hidden until the draft lobby row exists —
              // before that there's no deadline to count down against.
              if (_battleId != null) ...[
                const SizedBox(height: 10),
                _LobbyCountdownPill(battleId: _battleId!),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            children: [
              BattleDurationPicker(onChanged: _onWindowChanged),
              const SizedBox(height: 20),
              // Public toggle is intentionally not offered for team
              // battles — team lobbies are private by design (invite-
              // only). Exposing "public team lobby" would let random
              // Discover users drop into an arbitrary team, which
              // breaks the "creator picks the roster" premise.

              Row(
                children: [
                  Expanded(
                    child: Text(
                      'TEAMS',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  // Global invite button — one CTA for the whole
                  // lobby (batch 4b-2). Distributes selected friends
                  // across teams sequentially so the creator doesn't
                  // have to think about placement; anyone unhappy
                  // with their auto-assignment can double-tap their
                  // chip to swap teams.
                  TextButton.icon(
                    onPressed: _roster.length + 1 < _maxParticipants
                        ? _invitePlayersGlobal
                        : null,
                    icon: const Icon(Icons.group_add_outlined, size: 18),
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
              const SizedBox(height: 6),
              // Small caption teaching the primary gesture — testers
              // missed that double-tap-on-team moves you here (Batch A
              // round-2 #1). Kept short + muted so it doesn't compete
              // with the section header.
              Text(
                'Double-tap a team to move yourself there.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 10),

              // Team cards stacked full-width — one below another.
              // Reverted the side-by-side wrap after tester feedback:
              // vertical stacking gives each card enough room for its
              // tile row without horizontal scroll on 2-team battles,
              // and keeps the reading order top-to-bottom.
              for (final label in _labels)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _TeamBlock(
                          label: label,
                          name: _displayName(label),
                          members: _roster.entries
                              .where((e) => e.value.teamLabel == label)
                              .map((e) => e.value.user)
                              .toList(),
                          otherTeams:
                              _labels.where((l) => l != label).toList(),
                          canAdd: _roster.length + 1 < _maxParticipants,
                          canRemoveTeam:
                              label != 'A' && _teamCount > _minTeams,
                          currentUserId: ref
                                  .watch(authStateProvider)
                                  .valueOrNull
                                  ?.id ??
                              '',
                          isCreator: true,
                    isMyCurrentTeam: _roster[ref
                                .watch(authStateProvider)
                                .valueOrNull
                                ?.id ??
                            '']
                            ?.teamLabel ==
                        label,
                    onRename: () => _renameTeam(label),
                    onAdd: () => _addPlayers(label),
                    onMove: (userId, target) => _moveToTeam(userId, target),
                    onRemove: _removePlayer,
                    onRemoveTeam: () => _removeSpecificTeam(label),
                  ),
                ),

              // Add Team button — full-width, sits below the stack of
              // team cards.
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _teamCount < _maxTeams
                      ? () => _setTeamCount(_teamCount + 1)
                      : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(
                    _teamCount < _maxTeams
                        ? 'Add Team ${String.fromCharCode(65 + _teamCount)}'
                        : 'Max $_maxTeams teams',
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.4),
                    ),
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),

        Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.surfaceContainer.withValues(alpha: 0),
                AppColors.surfaceContainer,
              ],
            ),
          ),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: _canCreate ? _create : null,
                  child: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Create'),
                ),
              ),
              const SizedBox(height: 6),
              // Cancel affordance — creator-only, kills the lobby +
              // refunds every paid stake. Kept as a lightweight text
              // button (not a second FilledButton) so it doesn't compete
              // with the primary Create CTA above it.
              if (_battleId != null)
                TextButton.icon(
                  onPressed: _cancelLobby,
                  icon: Icon(Icons.cancel_outlined,
                      size: 16, color: AppColors.error),
                  label: Text(
                    'Cancel lobby & refund everyone',
                    style: TextStyle(color: AppColors.error),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                // Closing the sheet now leaves the lobby running; the
                // 10-min cron will auto-resolve if no one joins.
                'Add players & populate 2+ teams to enable Create. Close to keep the lobby open.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Always-visible "share this code" header bar.
// =============================================================================
class _ShareCodeBar extends StatelessWidget {
  final String code;
  const _ShareCodeBar({required this.code});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: code));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Code $code copied'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.glassBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.key, size: 16, color: AppColors.primary),
            const SizedBox(width: 10),
            Text(
              'Join code',
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                code,
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.content_copy,
                size: 16, color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

class _LobbyLoadingView extends StatelessWidget {
  const _LobbyLoadingView();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BottomSheetHandle(),
          const SizedBox(height: 40),
          CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 16),
          Text(
            'Preparing lobby…',
            style: TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LobbyErrorView extends StatelessWidget {
  final String message;
  const _LobbyErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BottomSheetHandle(),
          const SizedBox(height: 24),
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 12),
          Text(
            'Could not prepare lobby',
            style: TextStyle(
                color: AppColors.onSurface, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Per-team block: header (rename) + member chips + Add button.
// =============================================================================
class _TeamBlock extends StatelessWidget {
  final String label;
  final String name;
  final List<UserModel> members;
  final List<String> otherTeams;
  final bool canAdd;
  final bool canRemoveTeam;
  final String currentUserId;
  /// True if the sheet is being viewed by the battle's creator. Grants
  /// the "Remove from battle" option on OTHER players' chip long-press
  /// menu (Batch A round-2 #2). Non-creators only get self-serve
  /// actions on their own chip.
  final bool isCreator;
  /// True when the current user is already on THIS team — used to
  /// suppress the double-tap-team-to-move gesture on the team you're
  /// already on (would be a no-op, but silently doing nothing feels
  /// broken).
  final bool isMyCurrentTeam;
  final VoidCallback onRename;
  final VoidCallback onAdd;
  final void Function(String userId, String target) onMove;
  final void Function(String userId) onRemove;
  final VoidCallback onRemoveTeam;

  const _TeamBlock({
    required this.label,
    required this.name,
    required this.members,
    required this.otherTeams,
    required this.canAdd,
    required this.canRemoveTeam,
    required this.currentUserId,
    required this.isCreator,
    required this.isMyCurrentTeam,
    required this.onRename,
    required this.onAdd,
    required this.onMove,
    required this.onRemove,
    required this.onRemoveTeam,
  });

  // Team accent — sourced from the shared [TeamColors] palette so
  // every place teams surface (setup sheet, arena, cards, result
  // banner) reads the same hue per team. See lib/config/team_colors.dart
  // for the palette rationale.
  Color get _accent => TeamColors.forLabel(label);

  /// Returns the label of the next team in the A→B→C→D→A rotation,
  /// restricted to the teams that actually exist ([otherTeams] is the
  /// current-team-excluded set from the parent). Used by the
  /// double-tap-to-swap gesture on member chips.
  static String _nextLabelInRotation(
      String currentLabel, List<String> otherTeams) {
    // Combine current + others, sort so 'A' < 'B' < 'C' < 'D', then
    // pick the one AFTER current (wrap to first).
    final all = [currentLabel, ...otherTeams]..sort();
    final idx = all.indexOf(currentLabel);
    return all[(idx + 1) % all.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Wrap the whole card in a GestureDetector so double-tapping
    // ANYWHERE on the team block (Batch A round-2 #1) moves the
    // current user to this team. Suppressed on the team they're
    // already on. The chip-level double-tap still works too (kept for
    // muscle memory), but this is the primary discoverable gesture.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: isMyCurrentTeam
          ? null
          : () => onMove(currentUserId, label),
      child: Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: onRename,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppColors.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(Icons.edit,
                          size: 12, color: AppColors.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
              // Gradient home icon on the CREATOR's current team card
              // (the team they're sitting in right now — moves with
              // them if they double-tap into another team). Signals
              // "creator is here" at a glance so people can pick which
              // team to join based on who's where.
              if (isMyCurrentTeam)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _accent,
                        _accent.withValues(alpha: 0.55),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child:
                      const Icon(Icons.home, size: 14, color: Colors.white),
                ),
              if (canRemoveTeam)
                GestureDetector(
                  onTap: onRemoveTeam,
                  child: Icon(Icons.close,
                      size: 16, color: AppColors.error),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Horizontal tile row — filled tiles for accepted members,
          // padded with empty person-silhouette placeholders up to 4
          // visible slots (matches the reference layout so the card
          // never feels empty), then a trailing "+" invite tile that
          // signals the team isn't slot-capped and horizontal scroll
          // is available for larger rosters.
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              children: [
                for (final u in members) ...[
                  _MemberTile(
                    user: u,
                    accent: _accent,
                    isCreator: u.userId == currentUserId,
                    onLongPress: (u.userId == currentUserId)
                        ? () => _showMoveMenu(context)
                        : (isCreator
                            ? () => _showRemoveDialog(context, u)
                            : null),
                    onDoubleTap: (u.userId != currentUserId ||
                            otherTeams.isEmpty)
                        ? null
                        : () => onMove(
                              u.userId,
                              _nextLabelInRotation(label, otherTeams),
                            ),
                  ),
                  const SizedBox(width: 6),
                ],
                // Empty silhouette slots — pad up to 4 visible slots
                // so a card with one player still shows the "room to
                // grow" visual of the reference. Silhouettes are also
                // tap-to-invite; they open the global picker.
                for (var i = 0;
                    i < (4 - members.length).clamp(0, 4);
                    i++) ...[
                  _EmptySlotTile(accent: _accent, onTap: onAdd),
                  const SizedBox(width: 6),
                ],
                // Trailing "+" tile — always present as the definitive
                // "add more" affordance beyond the padded silhouettes.
                _AddPlayerTile(accent: _accent, onTap: onAdd),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// Own-tile long-press menu — the explicit team-picker. Complements
  /// the primary "double-tap the target team card" gesture.
  Future<void> _showMoveMenu(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in otherTeams)
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: Text('Move to Team $t'),
                onTap: () => Navigator.pop(ctx, 'm:$t'),
              ),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action.startsWith('m:')) {
      onMove(currentUserId, action.substring(2));
    }
  }

  /// Creator-only remove-other confirmation dialog.
  Future<void> _showRemoveDialog(BuildContext context, UserModel u) async {
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm == true) onRemove(u.userId);
  }
}

/// Compact square avatar tile used inside a [_TeamBlock] row. Height
/// matches [_EmptySlotTile] + [_AddPlayerTile] so the row aligns. Home
/// badge overlays the top-right when the tile represents the battle
/// creator.
class _MemberTile extends StatelessWidget {
  final UserModel user;
  final Color accent;
  final bool isCreator;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;

  const _MemberTile({
    required this.user,
    required this.accent,
    required this.isCreator,
    this.onLongPress,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = user.friendlyName;
    final initials =
        name.isNotEmpty ? name[0].toUpperCase() : '?';
    return GestureDetector(
      onLongPress: onLongPress,
      onDoubleTap: onDoubleTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
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
            alignment: Alignment.center,
            child: AvatarCircle(
              radius: 18,
              imageUrl: user.avatarURL,
              initials: initials,
            ),
          ),
          if (isCreator)
            Positioned(
              top: -3,
              right: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [accent, accent.withValues(alpha: 0.6)],
                  ),
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
    );
  }
}

/// Empty player-silhouette placeholder tile. Renders in the padded
/// section of a team row (after filled members, before the trailing
/// "+" tile) so cards with fewer players still communicate available
/// capacity — matches the reference layout where empty seats show as
/// grey silhouettes. Tap opens the global invite picker.
class _EmptySlotTile extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;
  const _EmptySlotTile({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: accent.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.person_outline,
            size: 22, color: accent.withValues(alpha: 0.5)),
      ),
    );
  }
}

/// Trailing "+" tile at the end of every team row. Distinct from the
/// empty silhouettes above — this one carries the explicit "add
/// player" affordance so users know they can invite beyond the visible
/// 4-slot pad. Opens the global invite picker on tap.
class _AddPlayerTile extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;
  const _AddPlayerTile({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: accent.withValues(alpha: 0.45),
            width: 1.2,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.add, size: 22, color: accent),
      ),
    );
  }
}

/// Live 10-minute lobby countdown pill. Reads `pending_expires_at` off
/// the battle row (set by Migration 0042's trigger for team battles)
/// and re-renders every 20s so the label decrements visibly without
/// churning the parent sheet's state. If the deadline has already
/// passed the cron will resolve the lobby shortly — we show
/// "Resolving…" to bridge the ~1 min gap.
class _LobbyCountdownPill extends ConsumerWidget {
  final String battleId;
  const _LobbyCountdownPill({required this.battleId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // allBattlesProvider is a realtime StreamProvider; pluck out the
    // one row we care about. Passing the raw stream through a
    // StreamBuilder tick is what gives us the visible ticking without
    // depending on parent rebuilds.
    final battle = ref
        .watch(allBattlesProvider)
        .valueOrNull
        ?.where((b) => b.battleId == battleId)
        .firstOrNull;
    final expiry = battle?.pendingExpiresAt;
    if (expiry == null) {
      // Pre-Migration-0042 rows OR the draft insert hasn't landed yet
      // via realtime. Render nothing — the sheet still works, just
      // without the countdown.
      return const SizedBox.shrink();
    }
    return StreamBuilder<int>(
      // Tick every second so users see the seconds counter move,
      // not just the minute label update every 20s. A 1s ticker on
      // a single text node is cheap — no scroll thrash concerns.
      stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
      builder: (context, _) {
        final r = expiry.difference(DateTime.now());
        final label = r.isNegative
            ? 'Resolving…'
            : r.inMinutes >= 1
                ? 'Lobby closes in ${r.inMinutes}m ${r.inSeconds % 60}s'
                : 'Lobby closes in ${r.inSeconds}s';
        // Amber tint below 2 min so the urgency reads at a glance
        // without shouting the whole time.
        final urgent = !r.isNegative && r.inMinutes < 2;
        final tint = urgent ? AppColors.amber : scheme.primary;
        return Container(
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
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: tint,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
