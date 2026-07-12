import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../utils/app_logger.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/battle_duration_picker.dart';
import '../widgets/battle_visibility_toggle.dart';
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

  /// Set to true ONLY when the user taps Create. dispose() reads this to
  /// decide whether to hard-delete the draft row.
  bool _didCreate = false;

  int _teamCount = 2;
  bool _isPublic = false;

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
    // Sheet was dismissed without the creator tapping Create — the draft
    // lobby never became a "real" battle, so wipe it. Fire-and-forget; the
    // service swallows errors and the 24h sweep is a safety net.
    final id = _battleId;
    if (id != null && !_didCreate) {
      _battleService.deleteDraftBattle(id);
    }
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
            if (!mounted) return;
            setState(() {
              for (final u in newOnes) {
                _roster[u.userId] = (user: u, teamLabel: targetLabel);
              }
            });
          } catch (e) {
            _snack('Add failed: $e');
          }
        },
      ),
    );
  }

  Future<void> _moveToTeam(String userId, String label) async {
    if (_battleId == null) return;
    final me = await ref.read(currentUserProvider.future);
    if (me == null) return;
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

  Future<void> _setVisibility(bool isPublic) async {
    if (_battleId == null) return;
    final prev = _isPublic;
    setState(() => _isPublic = isPublic);
    try {
      await _battleService.setBattleVisibility(
        battleId: _battleId!,
        visibility:
            isPublic ? BattleVisibility.public : BattleVisibility.private,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPublic = prev);
      _snack('Visibility change failed: $e');
    }
  }

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
  // Create — finalize the draft. dispose() sees _didCreate=true and won't
  // delete the row.
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
      _didCreate = true;
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
    final totalPlayers = _roster.length + 1; // creator counts

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
              const SizedBox(height: 16),
              BattleVisibilityToggle(
                isPublic: _isPublic,
                onChanged: _setVisibility,
              ),
              const SizedBox(height: 20),

              Text(
                'TEAMS',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onSurfaceVariant, letterSpacing: 2),
              ),
              const SizedBox(height: 12),

              for (final label in _labels)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _TeamBlock(
                    label: label,
                    name: _displayName(label),
                    members: _roster.entries
                        .where((e) => e.value.teamLabel == label)
                        .map((e) => e.value.user)
                        .toList(),
                    otherTeams: _labels.where((l) => l != label).toList(),
                    canAdd: _roster.length + 1 < _maxParticipants,
                    // Per-team remove button. Hidden on Team A (creator's
                    // team) and when we'd drop below the 2-team minimum.
                    canRemoveTeam: label != 'A' && _teamCount > _minTeams,
                    onRename: () => _renameTeam(label),
                    onAdd: () => _addPlayers(label),
                    onMove: (userId, target) => _moveToTeam(userId, target),
                    onRemove: _removePlayer,
                    onRemoveTeam: () => _removeSpecificTeam(label),
                  ),
                ),

              // Add Team button only. Each team card now owns its own
              // remove button (next to the per-team add-players icon) so
              // the user can drop any team, not just the last.
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
              Text(
                'Add players & populate 2+ teams to enable Create. Close without Create to discard.',
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
    required this.onRename,
    required this.onAdd,
    required this.onMove,
    required this.onRemove,
    required this.onRemoveTeam,
  });

  Color get _accent {
    switch (label) {
      case 'A':
        return AppColors.primary;
      case 'B':
        return AppColors.secondary;
      case 'C':
        return AppColors.amber;
      default:
        return AppColors.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    )),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: onRename,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.edit,
                          size: 14, color: AppColors.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: canAdd ? onAdd : null,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.person_add, size: 20),
                tooltip: 'Add players',
              ),
              if (canRemoveTeam)
                IconButton(
                  onPressed: onRemoveTeam,
                  visualDensity: VisualDensity.compact,
                  color: AppColors.error,
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  tooltip: 'Remove this team',
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No players yet — tap Add or use the long-press menu to move someone here.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final u in members)
                  _MemberChip(
                    user: u,
                    accent: _accent,
                    onLongPress: () async {
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
                              ListTile(
                                leading: const Icon(Icons.person_remove,
                                    color: AppColors.error),
                                title: const Text('Remove from battle'),
                                onTap: () => Navigator.pop(ctx, 'rm'),
                              ),
                            ],
                          ),
                        ),
                      );
                      if (action == null) return;
                      if (action == 'rm') {
                        onRemove(u.userId);
                      } else if (action.startsWith('m:')) {
                        onMove(u.userId, action.substring(2));
                      }
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MemberChip extends StatelessWidget {
  final UserModel user;
  final Color accent;
  final VoidCallback onLongPress;

  const _MemberChip({
    required this.user,
    required this.accent,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AvatarCircle(
                radius: 12,
                imageUrl: user.avatarURL,
                initials: user.friendlyName.isNotEmpty
                    ? user.friendlyName[0].toUpperCase()
                    : '?',
                borderColor: accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  user.friendlyName,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
