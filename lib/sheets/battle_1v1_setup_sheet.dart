import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../features/onboarding_tour/tour_controller.dart';
import '../features/onboarding_tour/tour_step.dart';
import '../features/onboarding_tour/tour_target.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../providers/user_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/battle_duration_picker.dart';
import '../widgets/battle_name_field.dart';
import '../widgets/battle_stake_picker.dart';
import '../widgets/battle_visibility_toggle.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../widgets/insufficient_xp_dialog.dart';
import '../providers/subscription_provider.dart';
import 'add_friends_sheet.dart';
import 'upgrade_cta_sheet.dart';

/// 1v1 battle setup.
///
/// UX layout (top → bottom):
///   • Title + battle code
///   • YOU vs OPPONENT card — tap "+ Select Opponent" to open the
///     [AddFriendsSheet] in picker mode (single-select)
///   • Start time + End time pickers with duration chips (see
///     [BattleDurationPicker])
///   • CTA: "Send Battle Invite"
class Battle1v1SetupSheet extends ConsumerStatefulWidget {
  /// Pre-selects this user as the opponent, skipping the empty state
  /// where "+ Select Opponent" opens the [AddFriendsSheet]. Used when
  /// the sheet is opened from another user's profile — the "who am I
  /// challenging" decision is already made, don't ask again.
  final UserModel? initialOpponent;

  /// Extra bottom inset applied to the ListView / CTA container so the
  /// Send Battle Invite button clears the shell's own bottom nav bar
  /// during the tour flow. Zero for normal user-initiated opens.
  final double extraBottomInset;

  const Battle1v1SetupSheet({
    super.key,
    this.initialOpponent,
    this.extraBottomInset = 0,
  });

  /// Opens the sheet. Tour opens with `useRootNavigator: false` so
  /// the sheet renders inside the shell (under our overlay), and
  /// `barrierColor: Colors.transparent` so the sheet's default scrim
  /// doesn't stack with the tour's dim. Tour also passes
  /// `useSafeArea: true` so the sheet respects the system nav inset
  /// — and a nonzero `extraBottomInset` so the Create/Send Invite
  /// button sits above the shell's OWN bottom nav bar (which
  /// MediaQuery.viewPadding does NOT count).
  static Future<void> show(
    BuildContext context, {
    bool useRootNavigator = true,
    Color? barrierColor,
    bool useSafeArea = false,
    double extraBottomInset = 0,
    UserModel? initialOpponent,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: useRootNavigator,
      useSafeArea: useSafeArea,
      backgroundColor: Colors.transparent,
      barrierColor: barrierColor,
      builder: (_) => Battle1v1SetupSheet(
        initialOpponent: initialOpponent,
        extraBottomInset: extraBottomInset,
      ),
    );
  }

  @override
  ConsumerState<Battle1v1SetupSheet> createState() =>
      _Battle1v1SetupSheetState();
}

class _Battle1v1SetupSheetState extends ConsumerState<Battle1v1SetupSheet> {
  UserModel? _selectedOpponent;

  /// Optional user-provided battle name (2026-09-04, migration 0061).
  /// Controller so we can `.text.trim()` at submit + `.dispose()` on
  /// unmount. Empty text → no name written (default majority state).
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
    _selectedOpponent = widget.initialOpponent;
    // Register Next-tap interceptors so tapping Next on the tour card
    // during 1v1 steps 8 + 12 is equivalent to tapping the underlying
    // "+ Select Opponent" and "Send Battle Invite" buttons. Deferred
    // via microtask to keep provider mutations out of the initState
    // frame.
    Future.microtask(_registerTourInterceptors);
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
      TourTargetId.battle1v1Opponent: _handleTourNextAtChooseOpponent,
      TourTargetId.battle1v1CreateButton: _handleTourNextAtSendInvite,
    };
  }

  void _unregisterTourInterceptors() {
    final controller = _interceptorController;
    if (controller == null) return;
    Future.microtask(() {
      final current = controller.state;
      final touchesUs =
          current.containsKey(TourTargetId.battle1v1Opponent) ||
              current.containsKey(TourTargetId.battle1v1CreateButton);
      if (!touchesUs) return;
      controller.state = {...current}
        ..remove(TourTargetId.battle1v1Opponent)
        ..remove(TourTargetId.battle1v1CreateButton);
    });
  }

  Future<void> _handleTourNextAtChooseOpponent() async {
    if (!mounted) return;
    // Same code path as tapping "+ Select Opponent" — opens the
    // AddFriendsSheet with the tour_add_friends route + transparent
    // barrier + advances the tour to step 9. When the picker closes
    // (via user pick, drag-down, OR another Next tap on the tour
    // card that flips the target OFF addFriendsSheetRoot), the
    // battles_screen addFriendsOutbound branch pops the sheet.
    await _pickOpponent();
  }

  Future<void> _handleTourNextAtSendInvite() async {
    if (!mounted) return;
    // "Irrespective of whether Send Battle Invite is active or not"
    // (2026-09-22 user request) — just close the sheet. The
    // battles_screen post-await loop advances the tour past all
    // 1v1 / Multi / Team sheets and lands on Discover.
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _unregisterTourInterceptors();
    _nameCtl.dispose();
    super.dispose();
  }

  bool _creating = false;
  /// In-sheet error banner text. Shown ABOVE the primary button so it
  /// isn't swallowed by the bottom sheet's z-order (a ScaffoldMessenger
  /// snackbar renders behind the sheet and can't be dismissed without
  /// closing the sheet first). Cleared on any successful submit or on
  /// picker value change.
  String? _submitError;
  BattleWindow? _window;

  /// When true, the battle goes into the public Discover feed and anyone with
  /// the join code (or the Discover tap) can join. Off by default — invite-only.
  bool _isPublic = false;

  /// Per-participant XP stake. Min 100 (set by migration 0016 economy
  /// rules); 0 means "free play, no stake". Pot = stake Ã— 2 in 1v1; the
  /// winner gets the whole pot.
  int _stakeXp = 100;

  final _battleCode = BattleService.generateBattleCode();

  Future<void> _showJoinCodeDialog(String code,
      {required bool recurring}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          recurring ? 'Daily Battle Created' : 'Battle Invite Sent',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Explicit "waiting" copy so the creator doesn't expect to
            // enter the arena immediately. Tester feedback: previously
            // read as though the battle had started already, but 1v1
            // battles only activate once the OPPONENT accepts.
            Text(
              _isPublic
                  ? 'Listed in Discover. Anyone can also paste this code:'
                  : 'Waiting for the opponent to accept. Once they do, the '
                      'battle appears in your Active list and step tracking '
                      'begins. Share the code below to speed things up:',
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

  Future<void> _pickOpponent() async {
    // 2026-09-14 tour integration for the "Pick a friend" step
    // (index 9, targetId addFriendsSheetRoot, sheet addFriends):
    //
    //   1. Push AddFriendsSheet FIRST (synchronous push into the nav
    //      stack). The named route settings let the BattlesScreen
    //      tour listener identify + pop this specific route later
    //      via popUntil, without accidentally popping the underlying
    //      Battle1v1SetupSheet.
    //   2. Then advance the tour from step 8 → step 9. Order matters:
    //      the listener's postFrame runs after the frame in which
    //      the state changed, and by then AddFriendsSheet is already
    //      the top of the nav — no race where the listener would
    //      pop the wrong route.
    //   3. After the sheet closes (via single-select instant confirm,
    //      manual drag-down, or listener-driven pop from tour skip /
    //      tour-advance), if we're still on step 9, advance to step
    //      10 "Set the window".
    final notifier = ref.read(tourControllerProvider.notifier);
    final tourBefore = ref.read(tourControllerProvider);
    final onChooseOpponentStep = tourBefore.active &&
        tourBefore.currentStep?.targetId == TourTargetId.battle1v1Opponent;

    final sheetFuture = showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Transparent barrier during tour so the overlay's spotlight
      // dim remains the only backdrop — otherwise the two dims stack.
      barrierColor: tourBefore.active ? Colors.transparent : null,
      // Named route so the tour listener can popUntil this specific
      // route without also closing Battle1v1SetupSheet underneath.
      routeSettings: const RouteSettings(name: 'tour_add_friends'),
      builder: (_) => AddFriendsSheet(
        mode: FriendsSheetMode.picker,
        multiSelect: false,
        confirmLabel: 'Select Opponent',
        // AddFriendsSheet returns the picked list via onConfirm; in
        // single-select mode it contains exactly one user AND the
        // sheet auto-pops on tap (see AddFriendsSheet._toggleSelect).
        onConfirm: (selected) {
          if (selected.isEmpty) return;
          setState(() => _selectedOpponent = selected.first);
        },
      ),
    );

    // Advance tour AFTER the sheet has been pushed onto the nav stack
    // (see step 2 in the docstring above).
    if (onChooseOpponentStep) {
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
  }

  /// Shown when the user taps a disabled control (opponent picker while
  /// public toggle is ON, or vice versa). Explains the mutual-exclusion
  /// so the disabled state doesn't read as a dead pixel.
  ///
  /// Uses [showDialog] rather than a snackbar because the setup sheet
  /// covers ~90% of the screen — a scaffold-anchored snackbar renders
  /// at the bottom of the outer screen, INSIDE the sheet's bounds,
  /// where the user can't see it. Dialogs stack on the root navigator
  /// above the sheet, so they always surface.
  /// Public-battle toggle handler. Turning ON prompts a confirmation
  /// dialog explaining the 1-hour advance rule — Cancel reverts the
  /// toggle to off; Continue keeps it on and the duration picker's
  /// minStart snaps to now+1h on the next rebuild. Turning OFF is
  /// instant (no dialog).
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

  Future<void> _showMutexHint(String message) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Can\'t do both'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _createBattle() async {
    // For PUBLIC battles, no specific opponent is required — anyone with
    // the join code or via Discover can drop in. For PRIVATE battles
    // we still need a chosen opponent at create time.
    if (!_isPublic && _selectedOpponent == null) return;
    final window = _window;
    if (window == null || !window.isValid) return;
    // Submit-time defense in depth: even though the picker enforces a
    // now+1h floor when public is on, the sheet can sit open for a
    // while before submit — re-check here so an about-to-elapse window
    // doesn't sneak through. Tolerance of 5 min matches the picker's
    // snap buffer (+5 min above the strict floor), so a normal submit
    // never trips this check.
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
    // Insufficient-XP pre-check. Previously the battle was created
    // and the stake charge failed downstream with a generic error;
    // testers wanted the "buy XP" path surfaced before we mutate any
    // server state. If the user can't afford the stake, show the
    // dialog + offer to open BuyXpSheet, and return WITHOUT calling
    // createBattle.
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    if (_stakeXp > 0 && me.totalXP < _stakeXp) {
      await showInsufficientXpDialog(
        context,
        required: _stakeXp,
        balance: me.totalXP,
        action: 'create this battle',
      );
      return;
    }

    setState(() {
      _creating = true;
      _submitError = null;
    });

    try {
      final participants = <BattleParticipant>[
        BattleParticipant(
          userId: me.userId,
          displayName: me.displayName.isEmpty ? 'You' : me.displayName,
          preferredName: me.preferredName,
          avatarURL: me.avatarURL,
        ),
        if (_selectedOpponent != null)
          BattleParticipant(
            userId: _selectedOpponent!.userId,
            displayName: _selectedOpponent!.displayName,
            preferredName: _selectedOpponent!.preferredName,
            avatarURL: _selectedOpponent!.avatarURL,
          ),
      ];
      // Daily preset → recurring series (one accept covers every future day).
      // Anything else → one-off battle, original flow.
      final service = ref.read(battleServiceProvider);
      final visibility =
          _isPublic ? BattleVisibility.public : BattleVisibility.private;
      // Optional battle name — passed through as null when the field is
      // empty so pre-migration DBs still accept the insert. The service
      // clamps to 30 chars server-side.
      final battleName =
          _nameCtl.text.trim().isEmpty ? null : _nameCtl.text.trim();
      final result = window.recurring
          ? await service.createDailySeries(
              type: BattleType.oneVsOne,
              participants: participants,
              startTime: window.start,
              endTime: window.end,
              createdBy: me.userId,
              visibility: visibility,
              stakeXp: _stakeXp,
              name: battleName,
            )
          : await service.createBattle(
              type: BattleType.oneVsOne,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
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

            // Title + battle code
            Center(
              child: Text('1 vs 1',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 4),
            Center(
              child: GestureDetector(
                onTap: () =>
                    Clipboard.setData(ClipboardData(text: _battleCode)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Battle ID: #$_battleCode',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.secondary,
                          letterSpacing: 2,
                        )),
                    const SizedBox(width: 4),
                    Icon(Icons.content_copy,
                        size: 12, color: AppColors.secondary),
                  ],
                ),
              ),
            ),

            // Scrollable body
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  const SizedBox(height: 20),

                  // YOU vs OPPONENT card. Right side is tappable to open
                  // the friend picker sheet. Left side shows the current
                  // user's own avatar + friendly name so the sheet
                  // mirrors how the opponent side reads once picked —
                  // no more anonymous "YOU / You" placeholder.
                  //
                  // IntrinsicHeight makes both Expanded children the
                  // same height (crossAxisAlignment.stretch), so the
                  // creator (Laxmi) and opponent (+ Select Opponent)
                  // cards render at identical size. Without it the
                  // creator card shrank to its content while the
                  // placeholder side stretched taller.
                  IntrinsicHeight(
                    child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Builder(builder: (_) {
                          final me = ref.watch(userProfileProvider).valueOrNull;
                          final myName = (me?.friendlyName.trim().isNotEmpty ?? false)
                              ? me!.friendlyName
                              : 'You';
                          final myInitials = myName.isNotEmpty
                              ? myName[0].toUpperCase()
                              : 'Y';
                          return _PlayerCard(
                            initials: myInitials,
                            imageUrl: me?.avatarURL,
                            name: myName,
                            isReady: true,
                          );
                        }),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('VS',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w900,
                              fontStyle: FontStyle.italic,
                            )),
                      ),
                      // Opponent picker — disabled when the battle is
                      // Public (an open lobby anyone can join; the
                      // "opponent" is whoever picks up the code first).
                      // Tap on the disabled state surfaces a snackbar
                      // explaining why so users aren't just clicking
                      // dead pixels.
                      Expanded(
                        // TourTarget wraps the opponent picker card
                        // for tour step 7.
                        child: TourTarget(
                          id: TourTargetId.battle1v1Opponent,
                          child: GestureDetector(
                          // opaque so taps land on the transparent
                          // areas of the placeholder card too — without
                          // this, taps on empty space between the
                          // avatar and label can miss and no popup
                          // fires.
                          behavior: HitTestBehavior.opaque,
                          onTap: _isPublic
                              ? () => _showMutexHint(
                                  'Turn off Public Battle to select a specific opponent.')
                              : _pickOpponent,
                          child: Opacity(
                            opacity: _isPublic ? 0.4 : 1.0,
                            child: _PlayerCard(
                              initials: _selectedOpponent == null
                                  ? null
                                  : (_selectedOpponent!.friendlyName.isNotEmpty
                                      ? _selectedOpponent!.friendlyName[0]
                                          .toUpperCase()
                                      : '?'),
                              imageUrl: _selectedOpponent?.avatarURL,
                              name: _selectedOpponent?.friendlyName ??
                                  '+ Select Opponent',
                              isPlaceholder: _selectedOpponent == null,
                            ),
                          ),
                        ),
                        ),
                      ),
                    ],
                  ),
                  ),
                  const SizedBox(height: 24),

                  // Public-battle toggle — mutually exclusive with the
                  // opponent picker. When an opponent is selected the
                  // toggle is greyed out and tapping it surfaces a
                  // snackbar (users aren't just clicking dead pixels).
                  //
                  // Placement: above the duration picker so the
                  // "public → +1h floor" dialog fires BEFORE users pick
                  // a start time — otherwise a picked earlier time
                  // would silently snap forward on toggle-on.
                  Opacity(
                    opacity: _selectedOpponent == null ? 1.0 : 0.4,
                    child: IgnorePointer(
                      ignoring: _selectedOpponent != null,
                      child: BattleVisibilityToggle(
                        isPublic: _isPublic,
                        onChanged: _onPublicToggleChanged,
                      ),
                    ),
                  ),
                  if (_selectedOpponent != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: GestureDetector(
                        onTap: () => _showMutexHint(
                            'Remove the selected opponent to make this battle Public.'),
                        child: Text(
                          'Tap to learn why this is disabled',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.primary,
                            decoration: TextDecoration.underline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),

                  // Optional battle name — one line, 30-char cap. Empty
                  // → no name saved and every surface falls back to the
                  // derived "You vs X" title exactly as before this
                  // feature landed (migration 0061, 2026-09-04).
                  BattleNameField(controller: _nameCtl),

                  const SizedBox(height: 16),

                  // Start + end time + duration chips. When public is
                  // on, minStart forces start >= now+1h so joiners have
                  // time to discover the battle. TourTarget for step 8.
                  TourTarget(
                    id: TourTargetId.battle1v1Duration,
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

                  // Stake picker — both sides commit this many XP; winner
                  // takes the whole pot. Min 100, no max (v2 economy).
                  // TourTarget for step 9.
                  TourTarget(
                    id: TourTargetId.battle1v1Stake,
                    child: BattleStakePicker(
                      value: _stakeXp,
                      participantsCount: 2,
                      onChanged: (v) => setState(() => _stakeXp = v),
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),

            // Bottom CTA — extra bottom padding when the tour is
            // driving the sheet so the Send Invite button clears the
            // shell's own bottom nav bar (which MediaQuery.viewPadding
            // doesn't count).
            Container(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 32 + widget.extraBottomInset),
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
                  // ScaffoldMessenger snackbar, which rendered behind
                  // the sheet and users could only see by dismissing
                  // the whole sheet.
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
                  Consumer(
                    builder: (context, ref, _) {
                      final decision =
                          ref.watch(canCreateBattleProvider);
                      final oppReady =
                          _selectedOpponent != null || _isPublic;
                      final buttonEnabled =
                          !_creating && oppReady && decision.allowed;

                      // When the ONLY blocker is the subscription cap,
                      // keep the button visually tappable so its onTap
                      // opens the upgrade sheet (rather than being
                      // a dead-null onPressed).
                      final blockedBySubOnly =
                          !_creating && oppReady && !decision.allowed;

                      return SizedBox(
                        width: double.infinity,
                        height: 56,
                        // TourTarget for step 10 — spotlight the Create
                        // CTA so users know how to send the invite.
                        child: TourTarget(
                          id: TourTargetId.battle1v1CreateButton,
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
                                      strokeWidth: 2,
                                      color: Colors.white))
                              : Text(blockedBySubOnly
                                  ? 'Upgrade to create'
                                  : 'Send Battle Invite'),
                        ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Consumer(
                    builder: (context, ref, _) {
                      final decision =
                          ref.watch(canCreateBattleProvider);
                      return Text(
                        decision.allowed
                            ? 'Battle starts at the chosen Start Time once opponent accepts'
                            : (decision.reason ??
                                'Monthly cap reached'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: decision.allowed
                              ? AppColors.onSurfaceVariant
                              : AppColors.amber,
                        ),
                        textAlign: TextAlign.center,
                      );
                    },
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
// Player card (YOU / opponent)
// =============================================================================
class _PlayerCard extends StatelessWidget {
  final String? initials;
  final String? imageUrl;
  final String name;
  final bool isReady;
  final bool isPlaceholder;

  const _PlayerCard({
    this.initials,
    this.imageUrl,
    required this.name,
    this.isReady = false,
    this.isPlaceholder = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The card body — pixel-identical shape / size / border / padding
    // for BOTH the creator and the opponent, so a Row of them lines up
    // flush with zero visual weight imbalance.
    //
    // Revision history:
    //   • Before 1.1.6+31 — creator had an extra "Ready" pill in its
    //     Column, which added ~24 px only to the creator side; user
    //     called out the height mismatch.
    //   • 1.1.6+31–36     — height was equalised, BUT the creator card
    //     still shipped with a heavier border (1.5 px @ 55 % alpha vs
    //     1 px @ 20 % alpha) plus an inline "CREATOR" text ribbon at
    //     top: 6 / right: 6 that ate visual "breathing room" above the
    //     avatar. User feedback (2026-08-30): "cards are not of same
    //     size and style … instead of text you can keep the home icon
    //     as a badge."
    //   • 2026-08-30 (this) — border weight + colour are the SAME on
    //     both sides. Creator distinction moves to a circular home-
    //     icon badge that extends slightly OUTSIDE the card corner
    //     via a Stack + Positioned(top:-8, right:-8). Because Positioned
    //     children don't contribute to the Stack's layout rect, the
    //     card size stays exactly matched with the opponent's.
    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // Fill still branches — glassBackground for a filled slot vs
        // surfaceContainerLow for an empty one — but only the FILL
        // differs now, not the frame.
        color: isPlaceholder
            ? AppColors.surfaceContainerLow
            : AppColors.glassBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          // 2026-09-13: unified border across ALL three states
          // (creator, opponent-selected, opponent-placeholder) so the
          // pair reads as visually matched siblings. User feedback:
          // "creator card should match the size and shape of the
          // select opponent card style and size" — previously the
          // creator shipped a heavier purple 1.25 px border while the
          // placeholder used a subtler grey 2 px, giving Laxmi's card
          // more visual weight than the opponent slot. Semantic
          // differentiation stays in the floating home-icon creator
          // badge (top-right on Laxmi) and the "+ Select Opponent"
          // copy on the empty slot — the frame itself no longer
          // encodes state.
          color: AppColors.outlineVariant.withValues(alpha: 0.3),
          width: 2,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: Column(
        children: [
          if (isPlaceholder)
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.3),
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
              ),
              child: Icon(Icons.person_add,
                  color: AppColors.onSurfaceVariant, size: 26),
            )
          else
            AvatarCircle(
              radius: 28,
              imageUrl: imageUrl,
              initials: initials,
              // 2026-09-13: ring matches the placeholder's inner-circle
              // treatment (outlineVariant @ 30 % alpha, 2 px) so the
              // paired cards share the same 56×56 outer disc frame
              // regardless of whether the slot is filled or empty.
              // Previously this shipped as AppColors.primary (bright
              // purple), giving Laxmi's inner circle a purple halo
              // while the opponent's was a subtle grey outline.
              borderColor: AppColors.outlineVariant.withValues(alpha: 0.3),
              borderWidth: 2,
            ),
          const SizedBox(height: 8),
          Text(
            name,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: isPlaceholder
                  ? AppColors.onSurfaceVariant
                  : AppColors.onSurface,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ),
    );

    // Opponent + placeholder → plain card (no badge). Creator → the
    // same plain card with a small home-icon badge floating over its
    // top-right corner. `isReady` continues to signal "this is the
    // creator's card" (per the pre-2026-08-30 contract with callers).
    if (!isReady) return card;
    return Stack(
      clipBehavior: Clip.none,
      // fit: passthrough forwards this Stack's INCOMING constraints
      // to `card` (the non-positioned child) instead of loosening
      // them, which is Stack's default (StackFit.loose). Without this,
      // when the creator card is placed inside an `Expanded(flex:1)`
      // in a Row the Stack loosens the tight width down to
      // min_w = 0, so `card` shrinks to fit its content (avatar +
      // short "Laxmi" text) — visibly narrower than the opponent card
      // (which returns `card` directly, no Stack wrap, so it receives
      // the Expanded's tight width and fills it). User called this
      // out 2026-09-13 with a side-by-side screenshot. Passthrough
      // keeps the card at the full flex-1 width so the pair matches.
      fit: StackFit.passthrough,
      children: [
        card,
        Positioned(
          top: -8,
          right: -8,
          child: Semantics(
            label: 'Battle creator',
            container: true,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  // Thin ring in the sheet's surface colour so the
                  // badge reads as a floating notification-style pip,
                  // not just a coloured dot smeared on the card edge.
                  color: AppColors.surfaceContainer,
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                Icons.home_rounded,
                size: 14,
                color: AppColors.onPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Stake picker moved to lib/widgets/battle_stake_picker.dart —
// shared with the group-battle setup sheet.
