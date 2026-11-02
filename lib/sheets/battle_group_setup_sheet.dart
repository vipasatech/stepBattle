import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../config/constants.dart';
import '../features/onboarding_tour/tour_controller.dart';
import '../features/onboarding_tour/tour_step.dart';
import '../features/onboarding_tour/tour_target.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/battle_duration_picker.dart';
import '../widgets/battle_name_field.dart';
import '../widgets/battle_stake_picker.dart';
import '../widgets/battle_visibility_toggle.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../providers/subscription_provider.dart';
import 'add_friends_sheet.dart';
import 'upgrade_cta_sheet.dart';

/// Multi-player battle setup — invite up to N participants for a free-for-all.
///
/// Mirror of [Battle1v1SetupSheet]:
///   • "+ Add players" opens [AddFriendsSheet] in multi-select picker mode
///   • Inline search field removed
///   • Start time + end time pickers + duration chips replace the
///     end-only picker
class BattleGroupSetupSheet extends ConsumerStatefulWidget {
  /// Extra bottom padding on the Send Battle Invites CTA. Non-zero
  /// when the sheet is opened during the tour by BattlesScreen — the
  /// shell's own floating nav bar doesn't reflect in
  /// MediaQuery.viewPadding, so without this the CTA lands behind
  /// the shell nav and the "Send the invites" tour step's spotlight
  /// falls off-screen (user feedback 2026-09-21).
  final double extraBottomInset;

  const BattleGroupSetupSheet({
    super.key,
    this.extraBottomInset = 0,
  });

  /// Opens the sheet. Same param pattern as the other tour-driven
  /// sheets so BattlesScreen can pass a transparent barrier and use
  /// the shell's local navigator (keeping the tour overlay on top).
  static Future<void> show(
    BuildContext context, {
    bool useRootNavigator = true,
    Color? barrierColor,
    RouteSettings? routeSettings,
    bool useSafeArea = false,
    double extraBottomInset = 0,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: useRootNavigator,
      backgroundColor: Colors.transparent,
      barrierColor: barrierColor,
      useSafeArea: useSafeArea,
      // Named route lets the tour listener popUntil-target this
      // specific sheet without accidentally popping any user route
      // that might sit underneath (e.g. /battles).
      routeSettings: routeSettings,
      builder: (_) => BattleGroupSetupSheet(
        extraBottomInset: extraBottomInset,
      ),
    );
  }

  @override
  ConsumerState<BattleGroupSetupSheet> createState() =>
      _BattleGroupSetupSheetState();
}

class _BattleGroupSetupSheetState
    extends ConsumerState<BattleGroupSetupSheet> {
  final List<UserModel> _invited = [];

  /// Optional user-provided battle name (migration 0061). Parity with
  /// the 1v1 sheet — empty submits as null, no schema hit.
  final _nameCtl = TextEditingController();

  /// Cached notifier for [tourNextInterceptorProvider]. Populated in
  /// [didChangeDependencies] so [dispose] can deregister the
  /// interceptors without touching `ref` (Riverpod disposes its ref
  /// before `State.dispose` runs).
  StateController<Map<TourTargetId, Future<void> Function()>>?
      _interceptorController;

  @override
  void initState() {
    super.initState();
    // Register Next-tap interceptors so tapping Next on the tour card
    // during Multi steps 13 + 17 is equivalent to tapping the
    // underlying "Add players" and "Send Battle Invites" buttons.
    // Deferred via microtask to keep provider mutations out of the
    // initState frame.
    Future.microtask(_registerTourInterceptors);
    // Bridge for any tour transition that lands on the "Pick friends"
    // step while the Multi setup sheet is open. Original 2026-09-21
    // AM: covered Next-tap forward from Invite players. Extended
    // same day PM: also covers Back-tap from Set the window (or any
    // later Multi step) — the tour target-id (addFriendsSheetRoot)
    // is the same, so we can key off the SUCCESSOR target regardless
    // of direction / origin. Guarded by _pickInviteesInFlight so a
    // direct Add-players-tap (which already advances the tour
    // internally) doesn't double-fire. Firing here also carries the
    // current _invited list into AddFriendsSheet's initial selection
    // via _pickInvitees, so Back-into-Pick-friends reopens with the
    // previously-added players pre-selected (user feedback: sheet
    // was reappearing empty even after having added players).
    ref.listenManual(tourControllerProvider, (prev, next) {
      if (!mounted) return;
      if (!next.active) return;
      final nextTarget = next.currentStep?.targetId;
      if (nextTarget != TourTargetId.addFriendsSheetRoot) return;
      if (_pickInviteesInFlight) return;
      _pickInvitees();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _interceptorController ??=
        ref.read(tourNextInterceptorProvider.notifier);
  }

  void _registerTourInterceptors() {
    if (!mounted) return;
    final notifier = ref.read(tourNextInterceptorProvider.notifier);
    notifier.state = {
      ...notifier.state,
      TourTargetId.battleGroupAddPlayers:
          _handleTourNextAtInvitePlayers,
      TourTargetId.battleGroupCreateButton: _handleTourNextAtSendInvites,
    };
  }

  void _unregisterTourInterceptors() {
    final controller = _interceptorController;
    if (controller == null) return;
    Future.microtask(() {
      final current = controller.state;
      final touchesUs =
          current.containsKey(TourTargetId.battleGroupAddPlayers) ||
              current.containsKey(TourTargetId.battleGroupCreateButton);
      if (!touchesUs) return;
      controller.state = {...current}
        ..remove(TourTargetId.battleGroupAddPlayers)
        ..remove(TourTargetId.battleGroupCreateButton);
    });
  }

  Future<void> _handleTourNextAtInvitePlayers() async {
    if (!mounted) return;
    // Same code path as tapping "Add players" — the existing tour
    // listener on this state auto-opens AddFriendsSheet whenever the
    // tour lands on addFriendsSheetRoot (see the ref.listenManual in
    // initState). Calling `_pickInvitees` explicitly here matches the
    // button-tap flow so the guard flags (`_pickInviteesInFlight`)
    // stay honest.
    await _pickInvitees();
  }

  Future<void> _handleTourNextAtSendInvites() async {
    if (!mounted) return;
    // "Irrespective of whether Send Battle Invites is active or not"
    // (2026-09-22 evening user request) — just close the sheet. The
    // battles_screen Multi-flow post-await loop then advances the
    // tour past every downstream battle-setup sheet and lands on
    // Discover.
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _unregisterTourInterceptors();
    _nameCtl.dispose();
    super.dispose();
  }

  bool _creating = false;
  /// In-sheet error banner (see 1v1 sheet for rationale — snackbars
  /// render behind bottom sheets and can't be surfaced without
  /// dismissing the sheet).
  String? _submitError;
  BattleWindow? _window;

  /// Public lobby toggle — see [Battle1v1SetupSheet] for design.
  bool _isPublic = false;

  /// Per-participant XP stake. v2 economy requires ≥
  /// [AppConstants.minBattleStakeXp] (100). Pot = stake × participants
  /// (creator + accepted invitees). Winner takes the whole pot.
  int _stakeXp = AppConstants.minBattleStakeXp;

  final _battleCode = BattleService.generateBattleCode();

  /// Re-entrancy guard for [_pickInvitees] — prevents the tour
  /// listener (which fires on Invite players → Pick friends
  /// transition) from double-opening AddFriendsSheet when the user
  /// tapped the Add players button directly.
  bool _pickInviteesInFlight = false;

  // _isInvited was used by the pre-2026-09-21 additive onConfirm to
  // skip duplicates when appending new picks; the current REPLACE
  // semantics don't need it (the confirm list IS the intended
  // roster). Kept out of the tree — remove entirely if no other
  // caller reappears.

  void _removeInvited(UserModel user) {
    setState(() => _invited.removeWhere((u) => u.userId == user.userId));
  }

  Future<void> _showJoinCodeDialog(String code,
      {required bool recurring}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          recurring ? 'Daily Battle Created' : 'Invites Sent',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isPublic
                  ? 'Listed in Discover. Anyone can also paste this code:'
                  : 'Share this code to let anyone you invited join directly:',
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

  Future<void> _pickInvitees() async {
    if (_pickInviteesInFlight) return;
    final slotsLeft =
        AppConstants.maxGroupBattleParticipants - 1 - _invited.length;
    if (slotsLeft <= 0) return;

    _pickInviteesInFlight = true;
    try {
      // 2026-09-21 tour integration mirrors the 1v1 _pickOpponent flow:
      //   1. Push AddFriendsSheet FIRST (synchronous push) with the
      //      'tour_add_friends' name so the main tour listener can
      //      popUntil-target it later (see battles_screen.dart's
      //      addFriends outbound branch).
      //   2. Advance tour from Invite players → Pick friends (Multi
      //      twin of 1v1's Pick a friend). Order matters — sheet
      //      must be on the nav stack before the listener sees the
      //      state change.
      //   3. Await the sheet close (multi-select Confirm, manual
      //      dismiss, or listener-driven pop from a Next-tap on the
      //      Pick friends step's tour card).
      //   4. If tour is still on Pick friends after close, advance
      //      it to the next Multi step (Set the window).
      final notifier = ref.read(tourControllerProvider.notifier);
      final tourBefore = ref.read(tourControllerProvider);
      final onInvitePlayersStep = tourBefore.active &&
          tourBefore.currentStep?.targetId ==
              TourTargetId.battleGroupAddPlayers;

      final sheetFuture = showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: tourBefore.active ? Colors.transparent : null,
        routeSettings: const RouteSettings(name: 'tour_add_friends'),
        builder: (_) => AddFriendsSheet(
          mode: FriendsSheetMode.picker,
          confirmLabel: 'Add to Battle',
          // During tour, lift the "Add to Battle" CTA above the shell's
          // floating nav bar so the tour spotlight measures on-screen.
          extraBottomInset: tourBefore.active ? 90 : 0,
          // Seed selection with the currently invited players so a
          // Back-into-Pick-friends reopen shows them as already
          // added (green Added chip). Toggling any of them off
          // removes them via the REPLACE semantics below.
          initialSelectedIds: _invited.map((u) => u.userId).toSet(),
          onConfirm: (selected) {
            // REPLACE semantics (2026-09-21): the confirm list is
            // the user's final intended roster for this round. Doing
            // this instead of append lets a user open the picker,
            // untick someone they added earlier, confirm, and see
            // that player removed from the invited list. Cap at the
            // maxGroupBattleParticipants limit; excess entries silently
            // drop (rare — the picker itself enforces the same cap
            // when adding).
            setState(() {
              _invited.clear();
              for (final u in selected) {
                if (_invited.length >=
                    AppConstants.maxGroupBattleParticipants - 1) {
                  break;
                }
                _invited.add(u);
              }
            });
          },
        ),
      );

      if (onInvitePlayersStep) {
        notifier.next();
      }

      await sheetFuture;

      if (!mounted) return;
      final tourAfter = ref.read(tourControllerProvider);
      if (tourAfter.active &&
          tourAfter.currentStep?.targetId ==
              TourTargetId.addFriendsSheetRoot) {
        notifier.next();
      }
    } finally {
      _pickInviteesInFlight = false;
    }
  }

  /// Public-battle toggle handler. Turning ON prompts a confirmation
  /// dialog explaining the 1-hour advance rule; Cancel reverts, Continue
  /// accepts and the duration picker's minStart snaps to now+1h on the
  /// next rebuild. Turning OFF is instant.
  Future<void> _onPublicToggleChanged(bool value) async {
    if (!value) {
      setState(() => _isPublic = false);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Public battle'),
        content: const Text(
          'Public battles are scheduled at least 1 hour in advance, '
          'giving other players enough time to discover and join before '
          'the battle begins.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      setState(() => _isPublic = true);
    }
  }

  Future<void> _createBattle() async {
    // Public battles skip the invitee requirement — anyone with the
    // join code / via Discover can drop in.
    if (!_isPublic && _invited.isEmpty) return;
    final window = _window;
    if (window == null || !window.isValid) return;
    // Submit-time defense in depth for public battles. 5-min tolerance
    // matches the picker's snap buffer (+5 min above the strict floor),
    // so a normal submit never trips this check.
    if (_isPublic) {
      final floorWithTolerance =
          DateTime.now().add(const Duration(minutes: 55));
      if (window.start.isBefore(floorWithTolerance)) {
        setState(() => _submitError =
            'Public battles need to start at least 1 hour from now. '
            'Re-open the start time and pick a later slot.');
        return;
      }
    }
    setState(() {
      _creating = true;
      _submitError = null;
    });

    try {
      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) throw StateError('Not signed in');
      final participants = [
        BattleParticipant(
          userId: me.userId,
          displayName: me.displayName.isEmpty ? 'You' : me.displayName,
          preferredName: me.preferredName,
          avatarURL: me.avatarURL,
        ),
        ..._invited.map((u) => BattleParticipant(
              userId: u.userId,
              displayName: u.displayName,
              preferredName: u.preferredName,
              avatarURL: u.avatarURL,
            )),
      ];

      final service = ref.read(battleServiceProvider);
      final visibility =
          _isPublic ? BattleVisibility.public : BattleVisibility.private;
      // Optional battle name — parity with 1v1 sheet.
      final battleName =
          _nameCtl.text.trim().isEmpty ? null : _nameCtl.text.trim();
      // Daily preset → recurring series; otherwise one-off battle.
      final result = window.recurring
          ? await service.createDailySeries(
              type: BattleType.group,
              participants: participants,
              startTime: window.start,
              endTime: window.end,
              createdBy: me.userId,
              visibility: visibility,
              stakeXp: _stakeXp,
              name: battleName,
            )
          : await service.createBattle(
              type: BattleType.group,
              participants: participants,
              startTime: window.start,
              endTime: window.end,
              createdBy: me.userId,
              visibility: visibility,
              stakeXp: _stakeXp,
              name: battleName,
            );
      if (mounted) {
        Navigator.pop(context);
        await _showJoinCodeDialog(result.joinCode, recurring: window.recurring);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slotsLeft =
        AppConstants.maxGroupBattleParticipants - 1 - _invited.length;

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('MULTI BATTLE',
                          style: theme.textTheme.headlineSmall?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700)),
                      GestureDetector(
                        onTap: () => Clipboard.setData(
                            ClipboardData(text: _battleCode)),
                        child: Row(
                          children: [
                            Text('Battle ID: #$_battleCode',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: AppColors.secondary,
                                    letterSpacing: 1)),
                            const SizedBox(width: 4),
                            Icon(Icons.content_copy,
                                size: 12, color: AppColors.secondary),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${_invited.length + 1} / ${AppConstants.maxGroupBattleParticipants}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  // Public toggle sits above the duration picker: the
                  // "public → +1h floor" dialog fires BEFORE the user
                  // picks a start time so the picker can enforce the
                  // floor from the start.
                  BattleVisibilityToggle(
                    isPublic: _isPublic,
                    onChanged: _onPublicToggleChanged,
                  ),
                  const SizedBox(height: 16),

                  // Optional battle name — same slot placement as 1v1
                  // sheet so users find the field in a consistent spot.
                  BattleNameField(controller: _nameCtl),
                  const SizedBox(height: 16),

                  // PLAYERS section — 2026-09-21 moved from below the
                  // stake picker to right under Battle name. Per-user
                  // feedback: "Add players" belongs where the identity
                  // of the battle is being set (creator's card + name),
                  // not at the very bottom where users scrolled past
                  // it. Wrapped in a TourTarget so the Multi tour step
                  // spotlights this whole row (the label + Add players
                  // button + hint) — see TourTargetId.battleGroupAddPlayers.
                  TourTarget(
                    id: TourTargetId.battleGroupAddPlayers,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text('PLAYERS',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                      color: AppColors.onSurfaceVariant,
                                      letterSpacing: 2)),
                            ),
                            TextButton.icon(
                              onPressed:
                                  slotsLeft > 0 ? _pickInvitees : null,
                              icon: const Icon(Icons.person_add, size: 18),
                              label: Text(slotsLeft > 0
                                  ? 'Add players'
                                  : 'Max reached'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (_invited.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline,
                                    size: 18,
                                    color: AppColors.onSurfaceVariant),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Tap "Add players" to invite friends to the battle.',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                            color:
                                                AppColors.onSurfaceVariant),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _invited
                                .map((u) => _InvitedChip(
                                      user: u,
                                      onRemove: () => _removeInvited(u),
                                    ))
                                .toList(),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Start + end + chips. When public is on, minStart
                  // forces start >= now+1h. TourTarget lets the
                  // Multi-only "Set the window" step spotlight this
                  // block (2026-09-21).
                  TourTarget(
                    id: TourTargetId.battleGroupDuration,
                    child: BattleDurationPicker(
                      minStart: _isPublic
                          ? DateTime.now().add(const Duration(hours: 1))
                          : null,
                      onChanged: (window) {
                        _window = window;
                      },
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Stake picker — every participant commits this many
                  // XP; winner takes the whole pot. Min 100 (v2 economy).
                  // Pot size scales with number of accepted seats (creator
                  // + invitees). TourTarget for the Multi-only "Stake
                  // your XP" step (2026-09-21).
                  TourTarget(
                    id: TourTargetId.battleGroupStake,
                    child: BattleStakePicker(
                      value: _stakeXp,
                      participantsCount: _invited.length + 1,
                      onChanged: (v) => setState(() => _stakeXp = v),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),

            // Bottom CTA. extraBottomInset (non-zero during tour)
            // lifts the CTA above the shell's floating nav bar so
            // the "Send the invites" tour target measures on-screen.
            Container(
              padding: EdgeInsets.fromLTRB(
                  24, 16, 24, 32 + widget.extraBottomInset),
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
                  // In-sheet error banner — replaces the old
                  // ScaffoldMessenger snackbar (rendered behind the
                  // sheet and was invisible to the user).
                  if (_submitError != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: AppColors.error, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _submitError!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(Icons.close,
                                color: AppColors.error, size: 18),
                            onPressed: () =>
                                setState(() => _submitError = null),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Consumer(builder: (context, ref, _) {
                    final decision = ref.watch(canCreateBattleProvider);
                    // Public battles don't need an invitee list — anyone
                    // with the code / from Discover can join. So the
                    // button becomes actionable as soon as we're not
                    // mid-submit. Private battles still need ≥1 invitee.
                    final rosterReady =
                        (_isPublic || _invited.isNotEmpty) && !_creating;
                    final buttonEnabled = rosterReady && decision.allowed;
                    final blockedBySubOnly =
                        rosterReady && !decision.allowed;
                    return TourTarget(
                      // Multi-only "Send the invites" tour step
                      // spotlights this CTA (2026-09-21).
                      id: TourTargetId.battleGroupCreateButton,
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FilledButton(
                          onPressed: buttonEnabled
                              ? _createBattle
                              : blockedBySubOnly
                                  ? () => showUpgradeCtaSheet(
                                        context,
                                        focusTier: decision.upgradeTo,
                                      )
                                  : null,
                          style: blockedBySubOnly
                              ? FilledButton.styleFrom(
                                  backgroundColor: AppColors.amber
                                      .withValues(alpha: 0.85),
                                  foregroundColor: Colors.black,
                                )
                              : null,
                          child: _creating
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(blockedBySubOnly
                                  ? 'Upgrade to create'
                                  : 'Send Battle Invites'),
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 6),
                  Text(
                    'Battle starts at the chosen Start Time once all accept',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Invited chip
// =============================================================================
class _InvitedChip extends StatelessWidget {
  final UserModel user;
  final VoidCallback onRemove;

  const _InvitedChip({required this.user, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primaryBrand.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
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
            borderColor: AppColors.primary,
          ),
          const SizedBox(width: 6),
          Text(user.friendlyName,
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child:
                const Icon(Icons.close, size: 14, color: AppColors.error),
          ),
        ],
      ),
    );
  }
}
