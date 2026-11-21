// Data model + const catalog for the 7-step new-user tour
// (migration 0062, design memo: `memory/project_new_user_tour.md`).
//
// This file is intentionally the ONE place tour content lives. Copy
// changes, target additions, and re-ordering all happen here — the
// overlay, controller, and TourTarget wrappers stay untouched.

import '../../services/capability_service.dart';

/// Named handle for every element the tour can spotlight. Each id
/// matches exactly one [TourTarget] widget in the app tree; the
/// controller resolves the id → GlobalKey lookup through the
/// [TourTargetRegistry] at fire time. Reordering the enum is safe
/// (order comes from [kTourSteps]); removing an id requires updating
/// the corresponding screen wrapper AND the step list.
enum TourTargetId {
  homeStepCounter,
  homeStreakFlame,
  homeLevelCard,
  // Retired 2026-09-04 (bonus-quests step removed by user request).
  // Kept in the enum so any lingering TourTarget widgets in the tree
  // don't fail to compile; nothing in kTourSteps references it now.
  homeMissionsSection,
  // Legacy — was the "Change goal" button inside TodaysMissionSheet.
  // The change-goal flow was rewritten 2026-09-04 to go DIRECTLY to
  // SetGoalSheet with interactive +/- and Save spotlights (see the
  // setGoalSheet* ids below). This id no longer appears in kTourSteps
  // but stays in the enum for the existing TourTarget wrapper.
  missionSheetChangeGoal,
  // Inside SetGoalSheet — spotlight the +/- stepper row so users can
  // adjust their goal LIVE during the tour.
  setGoalSheetPicker,
  // Inside SetGoalSheet — Save Goal button. Interactive so the user
  // can actually save from within the tour.
  setGoalSheetSave,
  battlesCreateButton,
  battleSelect1v1Tile,
  battle1v1Opponent,
  /// Wraps the ENTIRE AddFriendsSheet content — used by the "Pick a
  /// friend" tour step so the spotlight covers the whole sheet
  /// (tabs, list, search) rather than one cell. Added 2026-09-14
  /// after user feedback: highlighting only "+ Select Opponent"
  /// left the sheet's own tabs unexplained.
  addFriendsSheetRoot,
  /// Wraps the PLAYERS row (label + Add players button + hint) in
  /// BattleGroupSetupSheet. Used by the "Invite players" tour step
  /// that fires only on the Multi flow — the 1v1 flow has a
  /// dedicated Select Opponent target instead. Added 2026-09-21.
  battleGroupAddPlayers,
  /// BattleDurationPicker in BattleGroupSetupSheet — Multi-side
  /// equivalent of [battle1v1Duration]. Same widget class wrapped
  /// with a distinct id so the tour catalog can have a Multi-only
  /// "Set the window" step that only measures when the Multi sheet
  /// is open. Added 2026-09-21.
  battleGroupDuration,
  /// BattleStakePicker in BattleGroupSetupSheet — Multi-side
  /// equivalent of [battle1v1Stake]. Added 2026-09-21.
  battleGroupStake,
  /// "Send Battle Invites" button at the bottom of BattleGroupSetupSheet
  /// — Multi-side equivalent of [battle1v1CreateButton]. Added
  /// 2026-09-21.
  battleGroupCreateButton,
  battle1v1Duration,
  battle1v1Stake,
  battle1v1CreateButton,
  /// "Use entry & open" FilledButton in `_TeamBattleConfirmDialog`.
  /// Team-flow entry point — added 2026-09-22 alongside the six team
  /// lobby steps below.
  teamConfirmUseEntryButton,
  /// Duration preset chips (Daily/12h/1d/3d/1w/Custom) inside
  /// `BattleDurationPicker` when it's rendered on the team lobby page.
  /// Wired via the picker's optional `chipsTargetId` param.
  teamLobbyDurationChips,
  /// Starts + Ends time pills inside `BattleDurationPicker` on the
  /// team lobby page. Wired via the picker's optional `datesTargetId`
  /// param.
  teamLobbyDurationDates,
  /// The `BattleStakePicker` block itself on the team lobby page —
  /// the four preset chips (100/250/500/1000) + ± stepper. Added
  /// 2026-09-22 so the tour has a step where the user can actually
  /// pick a stake value; the next step ([teamLobbyStake]) then
  /// spotlights the Confirm stake CTA in the bottom bar.
  teamLobbyStakePicker,
  /// The "Confirm stake" CTA in `_BottomBar`'s State A on the team
  /// lobby page. Tap locks the draft stake into `battle.stakeXp`.
  teamLobbyStake,
  /// "Invite players" TextButton that appears in the TEAMS header row
  /// on the team lobby page once the stake is locked.
  teamLobbyInvitePlayers,
  /// Bottom action row on the team lobby page — "Start battle now"
  /// primary CTA + "Cancel lobby & refund everyone" text link. Last
  /// step of the team sub-flow.
  teamLobbyBottomActions,
  discoverLobbyCard,
  profileSettingsGear,
}

/// Which modal bottom sheet must be OPEN for a given step. Screens
/// listen to the tour controller and open/close their sheet when a
/// step tagged with that sheet becomes active / falls off active.
///
/// `null` = no sheet, target lives on the current tab's page.
enum TourSheet {
  setGoal,              // SetGoalSheet — opened by HomeScreen for the
                        // change-your-goal flow (interactive +/- + Save).
  todaysMission,        // TodaysMissionSheet — legacy from earlier tour
                        // versions; kept as an enum value for backwards
                        // compatibility, no step uses it now.
  newBattleSelection,   // NewBattleSelectionSheet — opened by BattlesScreen
  battle1v1Setup,       // Battle1v1SetupSheet — chained from newBattleSelection
  addFriends,           // AddFriendsSheet — opened from inside Battle1v1SetupSheet
                        // by "+ Select Opponent". Sheet is nested (stacked on
                        // top of battle1v1Setup, not replacing it).
  battleGroupSetup,     // BattleGroupSetupSheet — the Multi flow's setup sheet,
                        // opened by BattlesScreen listener after the format
                        // picker closes with the Multi choice. Only the
                        // "Invite players" tour step uses this sheet marker;
                        // the 1v1 flow's steps stay on battle1v1Setup.
  teamConfirmDialog,    // `_TeamBattleConfirmDialog` — the "Start a team
                        // battle?" AlertDialog. NOT a bottom sheet; reusing
                        // the sheet enum as a general "context marker" so
                        // the listener can advance/pop consistently.
                        // Added 2026-09-22.
  teamLobby,            // TeamLobbyPage — full-screen page pushed onto the
                        // shell's Battles branch nav (NOT root nav) during
                        // tour so the overlay stays on top. Added 2026-09-22.
}

/// Which shell destination the tour needs to be showing for a given
/// step. The controller drives [MainShell] to switch/push there
/// BEFORE it measures the target rect, so the target is guaranteed
/// mounted by the time we try to spotlight it.
///
/// Values map to the shell's own tab indices where possible; `profile`
/// is a pushed child of the Home shell branch (not a tab).
enum TourTab {
  home,     // shell.goBranch(0)
  battles,  // shell.goBranch(1)
  profile,  // context.push('/profile') from within the Home branch
}

/// Where the arrow tip enters the spotlight from. The overlay paints
/// the arrow based on this + the tooltip's own bottom-anchored
/// position, so all we're doing here is picking which side of the
/// spotlight the arrow enters — the curve is auto-computed by the
/// painter.
enum TourArrowSide {
  /// Arrow tip enters the TOP of the spotlight (tooltip is BELOW the
  /// target). Used when the spotlighted element sits low on the screen.
  fromAbove,

  /// Arrow tip enters the BOTTOM of the spotlight (tooltip is ABOVE).
  /// Used when the spotlighted element sits high on the screen.
  fromBelow,
}

/// One entry in the tour catalog. v5 (2026-09-04) splits copy into
/// [title] + [description] to match the plant-app reference the user
/// shared: a dark card with a bold title, one-line description, and
/// a corner X close.
///
/// [arrowSide] retained even though the overlay no longer paints an
/// arrow — it still tells the tooltip which side of the target to
/// anchor to (fromBelow = tooltip below target, fromAbove = tooltip
/// above).
class TourStep {
  final TourTargetId targetId;
  final TourTab tab;
  final String title;
  final String description;
  final TourArrowSide arrowSide;

  /// If non-null, the named modal bottom sheet must be open for this
  /// step. Cross-step comparison in the shell/screen listeners decides
  /// whether to open a new sheet, keep the current one open, or close
  /// the previous one when advancing between steps.
  final TourSheet? sheet;

  /// When true, the tour overlay DOES NOT block pointer events on
  /// the underlying page — the user can actually interact with the
  /// spotlighted target (tap +/- steppers, tap Save, etc.). Used by
  /// the change-goal flow where the user has to be able to adjust
  /// the goal and hit Save from within the tour.
  final bool allowTargetInteraction;

  /// When true, a tap on the target widget itself should behave the
  /// SAME as tapping the tour card's Next button — i.e. advance the
  /// tour rather than fire the target's natural onTap. Widgets that
  /// carry a [TourTarget] wrapper opt in by checking this flag from
  /// their own onTap handler. Used on the change-goal INTRO step
  /// (index 3) so both paths — Next button OR card tap — funnel
  /// into the SetGoalSheet tour flow instead of the card's own
  /// useRootNavigator:true sheet that covers the overlay.
  final bool advanceOnTargetTap;

  /// Extra dp of space between the card and the target on top of
  /// the base gap. Used when the target is a specific icon inside
  /// a larger widget block (e.g. the flame inside StreakStrip) and
  /// the card should sit below the WHOLE block, not just below the
  /// icon.
  final double cardOffsetPastTarget;

  /// Override the horizontal notch position on the card (0..1
  /// fraction of card width). Null → compute from target's centre X.
  /// Used when the target is wide (e.g. the whole streak strip) but
  /// the notch should still anchor at a specific horizontal spot
  /// (e.g. where the flame is on the left of the strip).
  final double? notchFractionOverride;

  /// When true, the Back button is hidden on this step regardless of
  /// stepIndex. Used by the FIRST step of the team lobby sub-flow so
  /// pressing Back cannot rewind past the "Use entry & open" confirm
  /// dialog after the lobby has already been created on the server
  /// (a destructive action to unwind). Added 2026-09-22.
  final bool hidesBackButton;

  /// A capability this step should offer to unlock.
  ///
  /// When set AND the capability is currently locked, the card's primary
  /// button becomes "Allow" and the secondary becomes "Not now".
  /// Granting advances; declining also advances — asking twice inside
  /// one flow is nagging, and the padlock left on the spotlighted widget
  /// is the second chance.
  ///
  /// Attached to EXISTING steps rather than added as new ones on
  /// purpose. Steps 0 and 1 already spotlight the step counter and the
  /// streak flame, which are precisely the widgets these permissions
  /// unlock — so the ask lands on the thing it affects, and no index
  /// moves. [TourStepRanges] and the info-icon replays are index-keyed,
  /// so prepending steps would have silently repointed both.
  final AppCapability? permission;

  const TourStep({
    required this.targetId,
    required this.tab,
    required this.title,
    required this.description,
    required this.arrowSide,
    this.sheet,
    this.allowTargetInteraction = false,
    this.advanceOnTargetTap = false,
    this.cardOffsetPastTarget = 0,
    this.notchFractionOverride,
    this.hidesBackButton = false,
    this.permission,
  });
}

/// Convenience index ranges for the info-icon replays on Home + Battle.
/// Kept next to [kTourSteps] so any reordering of the catalog updates
/// the ranges in one place.
class TourStepRanges {
  const TourStepRanges._();
  /// Home steps: everything on / opened FROM the Home tab (indices 0-5).
  /// After the 2026-09-13 rework: step counter, streak, level card,
  /// change-goal INTRO (points at the daily-goal card on Home so the
  /// user sees WHERE to change it from), change-goal picker inside
  /// SetGoalSheet, save-goal button inside SetGoalSheet.
  static const int homeFrom = 0;
  static const int homeUntilExclusive = 6;

  /// Battle steps: everything from "New Battle" tap through Discover.
  /// Latest shift 2026-09-22 (afternoon): the Team-flow sub-tour was
  /// expanded from 7 → 8 steps by inserting a new "Stake the XP" step
  /// at index 21, so Confirm-stake / Invite-players / Add-friends /
  /// bottom-actions shifted +1 (was 21-24, now 22-25). Discover moves
  /// to 26 and Profile to 27. Battles-scoped info-icon replay covers
  /// indices 6-26 (walks 1v1, Multi, AND Team flows).
  static const int battleFrom = 6;
  static const int battleUntilExclusive = 27;
}

/// The ordered 28-step catalog. 7 → 13 on 2026-09-04; 13 → 14 on
/// 2026-09-13 (change-goal INTRO); 14 → 15 on 2026-09-14 (Pick a friend);
/// 15 → 16 on 2026-09-21 (Multi Invite players); 16 → 19 same day (three
/// more Multi steps); 19 → 20 evening (Multi twin of Pick a friend);
/// 20 → 27 on 2026-09-22 (Team sub-flow: Use entry & open dialog + 6
/// team lobby steps); 27 → 28 on 2026-09-22 afternoon (split old stake
/// step into "Stake the XP" picker + "Lock the stake" CTA). This is
/// the ONLY place the sequence is defined — everything else derives
/// from `kTourSteps.length` and `kTourSteps[i]`. Reordering: swap
/// entries here, then update [TourStepRanges] if the Home/Battle
/// split point moves.
///
/// Sequence intent:
///   0-2   Home tab    — grounds the daily loop (goal → streak → level)
///   3     Home tab    — change-goal INTRO (points at the daily-goal card)
///   4-5   Sheet        — SetGoalSheet picker + save-goal button
///   6-17  Battle flow  — New Battle → selection → 1v1 setup with nested
///                        AddFriendsSheet step + Multi-only sub-tour
///   18-25 Team flow    — Use entry & open dialog + team lobby (duration
///                        chips + Starts/Ends dates + Stake picker +
///                        Lock stake + Invite players + AddFriendsSheet
///                        + Start/Cancel row)
///   26    Discover     — public battle discovery
///   27    Profile      — settings entry point (change goal / home / theme)
///
/// Copy is ALL-CAPS declarative, matches the reference visual grammar.
const List<TourStep> kTourSteps = [
  // ── Home tab (indices 0-5) ─────────────────────────────────────
  TourStep(
    targetId: TourTargetId.homeStepCounter,
    tab: TourTab.home,
    title: "Today's goal",
    description: 'Walk to earn XP. Hit the number to complete today. '
        'StepBattle reads your step count from your phone and Apple '
        'Health — without it there is nothing to score.',
    arrowSide: TourArrowSide.fromBelow,
    permission: AppCapability.steps,
  ),
  TourStep(
    targetId: TourTargetId.homeStreakFlame,
    tab: TourTab.home,
    title: 'Keep the flame alive',
    description: 'Hit your goal every day to build a streak. Turn on '
        'notifications and we will warn you before you lose one.',
    arrowSide: TourArrowSide.fromBelow,
    permission: AppCapability.notifications,
    // Target rect wraps the WHOLE streak strip (flame + "N Days"
    // caption + weekly dots) so the spotlight highlights the entire
    // strip and the card lands right below the "N Days" row. The
    // notch overrides its horizontal position to sit near the LEFT
    // of the card (0.13) so it still points at the flame icon.
    notchFractionOverride: 0.13,
  ),
  TourStep(
    targetId: TourTargetId.homeLevelCard,
    tab: TourTab.home,
    title: 'Level up as you move',
    description: 'Every step earns XP toward your next level.',
    arrowSide: TourArrowSide.fromBelow,
  ),
  // Bonus quests step removed 2026-09-04 (user feedback).
  //
  // Change-goal flow rewritten 2026-09-04 to two INTERACTIVE steps:
  // step opens SetGoalSheet directly, lets the user actually adjust
  // with +/- and save. `allowTargetInteraction: true` disables the
  // overlay's tap-blocking so +/- and Save are live.
  // Intro step: point at the daily-mission card on Home so users
  // see WHERE to open the change-goal sheet from. Interactive so
  // taps on the card still open TodaysMissionSheet naturally; the
  // tour then auto-advances to the setGoalSheetPicker step which
  // opens SetGoalSheet from HomeScreen's listener.
  TourStep(
    targetId: TourTargetId.homeStepCounter,
    tab: TourTab.home,
    title: 'Change your daily goal',
    description: 'Tap the card or Next to adjust it.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
    // Tapping the daily-goal card on Home also advances the tour
    // (DailyTargetCard.onTap reads this flag). Without it, a card
    // tap would open the natural useRootNavigator:true SetGoalSheet
    // that covers the overlay and drops the user out of the tour.
    advanceOnTargetTap: true,
  ),
  TourStep(
    targetId: TourTargetId.setGoalSheetPicker,
    tab: TourTab.home,
    sheet: TourSheet.setGoal,
    title: 'Change your daily goal',
    description: 'Use + and – to adjust. Try it now.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.setGoalSheetSave,
    tab: TourTab.home,
    sheet: TourSheet.setGoal,
    title: 'Save your new goal',
    description: 'Tap Save Goal to lock it in.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  // ── Battles flow (indices 6-17) — 1v1 setup + Multi sub-tour ──
  // All battle steps are INTERACTIVE (2026-09-09 user request):
  // user can tap the New Battle button, 1v1 tile, opponent / duration
  // / stake pickers, and Create button live during the tour. The
  // BattlesScreen listener awaits the sheet-close future and
  // auto-advances the tour when the user finishes an action.
  TourStep(
    targetId: TourTargetId.battlesCreateButton,
    tab: TourTab.battles,
    title: 'Start a battle',
    description: 'Tap New Battle to open the picker.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.battleSelect1v1Tile,
    tab: TourTab.battles,
    sheet: TourSheet.newBattleSelection,
    title: 'Pick a format',
    description: 'Try 1v1, Multi, or Team — or skip to default 1v1.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
    // 2026-09-14: card sits ABOVE the 3-tile row with the notch
    // pointing down; the base gap put the notch tip flush with the
    // tile tops, which read as an overlap (especially once a tile
    // shows its picked-state purple border + checkmark). +32 dp of
    // extra clearance lifts the whole card so the tiles have room
    // to breathe below the arrow tip without the card drifting so
    // far up that it loses its visual link to the target.
    cardOffsetPastTarget: 32,
  ),
  TourStep(
    targetId: TourTargetId.battle1v1Opponent,
    tab: TourTab.battles,
    sheet: TourSheet.battle1v1Setup,
    title: 'Choose an opponent',
    description: 'Tap + Select Opponent to open the friend picker.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  // Nested-sheet step (2026-09-14): AddFriendsSheet stacks on top of
  // Battle1v1SetupSheet when the user taps "+ Select Opponent". This
  // step spotlights the ENTIRE friend picker so the user understands
  // the three tabs it offers (Friends, Search, Requests). Single-tap
  // on any friend both selects them AND closes the sheet — see the
  // singleSelectInstantConfirm branch in AddFriendsSheet — so the
  // tour advances naturally without a separate "confirm" tap.
  TourStep(
    targetId: TourTargetId.addFriendsSheetRoot,
    tab: TourTab.battles,
    sheet: TourSheet.addFriends,
    title: 'Pick a friend',
    description: 'Browse Friends, Search, or Requests. Tap to add.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.battle1v1Duration,
    tab: TourTab.battles,
    sheet: TourSheet.battle1v1Setup,
    title: 'Set the window',
    description: 'How long the battle will run.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.battle1v1Stake,
    tab: TourTab.battles,
    sheet: TourSheet.battle1v1Setup,
    title: 'Stake your XP',
    description: 'Winner takes the pot. Minimum 100.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.battle1v1CreateButton,
    tab: TourTab.battles,
    sheet: TourSheet.battle1v1Setup,
    title: 'Send the invite',
    description: 'Tap Create to challenge your opponent.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  // Multi-only steps (2026-09-21). BattlesScreen's tour listener
  // advances the tour past ALL battleGroupSetup steps when the
  // user's format choice isn't Multi; for Multi it opens
  // BattleGroupSetupSheet and walks these four steps — mirroring
  // the 1v1 sub-flow (opponent → duration → stake → send) so both
  // formats teach the same shape of setup. Targets and sheet
  // marker are Multi-specific so the widget wraps in
  // BattleGroupSetupSheet resolve unambiguously.
  TourStep(
    targetId: TourTargetId.battleGroupAddPlayers,
    tab: TourTab.battles,
    sheet: TourSheet.battleGroupSetup,
    title: 'Invite players',
    description: 'Tap Add players to bring friends into the battle.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  // Multi-flow twin of the 1v1 "Pick a friend" step (index 9). The
  // AddFriendsSheet opens on top of BattleGroupSetupSheet when the
  // user taps Add players OR taps Next on the Invite players step —
  // BattleGroupSetupSheet's tour listener bridges the "Next tap on
  // Invite players" case by opening the picker itself. Same target
  // (addFriendsSheetRoot) as the 1v1 step because both flows use
  // the same AddFriendsSheet widget wrapping. Distinction lives in
  // the FLOW (prev-step target = battleGroupAddPlayers here vs
  // battle1v1Opponent for 1v1).
  TourStep(
    targetId: TourTargetId.addFriendsSheetRoot,
    tab: TourTab.battles,
    sheet: TourSheet.addFriends,
    title: 'Pick friends',
    description: 'Browse Friends, Search, or Requests. Tap Add to invite.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.battleGroupDuration,
    tab: TourTab.battles,
    sheet: TourSheet.battleGroupSetup,
    title: 'Set the window',
    description: 'How long the battle will run.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.battleGroupStake,
    tab: TourTab.battles,
    sheet: TourSheet.battleGroupSetup,
    title: 'Stake your XP',
    description: 'Every player pays this. Winner takes the pot.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.battleGroupCreateButton,
    tab: TourTab.battles,
    sheet: TourSheet.battleGroupSetup,
    title: 'Send the invites',
    description: 'Tap Send to challenge everyone at once.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  // ── Team sub-flow (indices 18-24, added 2026-09-22) ────────────
  // Only reached when the user picks Team at step 7 (Pick a format).
  // Sequence: "Use entry & open" confirm dialog → team lobby's
  // duration chips → Starts/Ends dates → stake + confirm → Invite
  // players → AddFriendsSheet → bottom actions (Start now / Cancel).
  //
  // The team lobby route is normally pushed onto the ROOT navigator
  // (see routes.dart '/team-lobby/:battleId'). The tour listener
  // instead pushes a MaterialPageRoute onto the SHELL branch nav so
  // the OnboardingTourOverlay (mounted inside the shell) stays on
  // top of the page.
  TourStep(
    targetId: TourTargetId.teamConfirmUseEntryButton,
    tab: TourTab.battles,
    sheet: TourSheet.teamConfirmDialog,
    title: 'Confirm the team battle',
    description: "Tap Use entry & open — or Next — to spend 1 entry and open the lobby.",
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
    // A tour Next tap on this step is routed to the confirm dialog's
    // "Use entry & open" action via [tourNextInterceptorProvider]
    // (added 2026-09-22 afternoon), so we can't allow going Back —
    // the lobby is already being created on the server the moment
    // Next fires. Hide Back here as well as on the first team lobby
    // step (Battle window chips) so the whole one-way transition is
    // uninterruptible.
    hidesBackButton: true,
  ),
  TourStep(
    targetId: TourTargetId.teamLobbyDurationChips,
    tab: TourTab.battles,
    sheet: TourSheet.teamLobby,
    title: 'Pick a battle window',
    description: 'Choose a preset — Daily, 1d, 3d, 1w, or Custom.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
    // Server-side lobby already exists at this point; a Back tap
    // shouldn't destroy it. The overlay hides Back on this step so
    // the user advances forward or skips out via the X on the card.
    hidesBackButton: true,
  ),
  TourStep(
    targetId: TourTargetId.teamLobbyDurationDates,
    tab: TourTab.battles,
    sheet: TourSheet.teamLobby,
    title: 'Fine-tune Starts & Ends',
    description: 'Tap either row to set an exact start or end.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  // 2026-09-22 afternoon — split the old single stake step into TWO:
  // this "Stake the XP" step targets `BattleStakePicker` at the top
  // of the team lobby so the user can actually pick a value with the
  // preset chips + ± stepper, and the next step ([teamLobbyStake])
  // spotlights the Confirm-stake CTA at the bottom.
  TourStep(
    targetId: TourTargetId.teamLobbyStakePicker,
    tab: TourTab.battles,
    sheet: TourSheet.teamLobby,
    title: 'Stake the XP',
    description: 'Pick each player\'s stake with the presets or ± stepper.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.teamLobbyStake,
    tab: TourTab.battles,
    sheet: TourSheet.teamLobby,
    title: 'Lock the stake',
    description: 'Tap Confirm stake — or Next — to lock the amount in.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.teamLobbyInvitePlayers,
    tab: TourTab.battles,
    sheet: TourSheet.teamLobby,
    title: 'Invite players',
    description: 'Tap Invite players — or Next — to open the friend picker.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  // Reuses [addFriendsSheetRoot] target — same AddFriendsSheet the
  // 1v1 + Multi flows highlight. Distinction is flow-based (prev
  // step target = teamLobbyInvitePlayers here).
  TourStep(
    targetId: TourTargetId.addFriendsSheetRoot,
    tab: TourTab.battles,
    sheet: TourSheet.addFriends,
    title: 'Add teammates',
    description: 'Tap a friend to invite them into the lobby.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.teamLobbyBottomActions,
    tab: TourTab.battles,
    sheet: TourSheet.teamLobby,
    title: 'Start or cancel',
    description: 'Start battle now when ready — or Cancel & refund everyone.',
    arrowSide: TourArrowSide.fromAbove,
    allowTargetInteraction: true,
  ),
  TourStep(
    targetId: TourTargetId.discoverLobbyCard,
    tab: TourTab.battles,
    title: 'Discover public battles',
    description: 'Join open lobbies without waiting for an invite.',
    arrowSide: TourArrowSide.fromBelow,
    allowTargetInteraction: true,
  ),
  // ── Profile (index 19) ─────────────────────────────────────────
  TourStep(
    targetId: TourTargetId.profileSettingsGear,
    tab: TourTab.profile,
    title: 'Make it yours',
    description: 'Change your goal, home, theme and more.',
    arrowSide: TourArrowSide.fromBelow,
  ),
];
