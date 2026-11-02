// [3D-DISABLED-2026-08-21] dart:async import was for `unawaited()` around
// MediaWarmup.primeWebViewEngine() — both commented out below. Re-add on
// re-enable.
// import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../features/onboarding_tour/tour_controller.dart';
import '../../features/onboarding_tour/tour_replay_icon.dart';
import '../../features/onboarding_tour/tour_step.dart';
import '../../features/onboarding_tour/tour_target.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../utils/app_logger.dart';
// [3D-DISABLED-2026-08-21] media_warmup import was only used for
// primeWebViewEngine, commented below.
// import '../../services/media_warmup.dart';
import '../../screens/team_lobby/team_lobby_page.dart';
import '../../sheets/battle_1v1_setup_sheet.dart';
import '../../sheets/battle_group_setup_sheet.dart';
import '../../sheets/new_battle_selection_sheet.dart';
import '../../sheets/pending_battle_actions_sheet.dart';
import '../../sheets/team_battle_confirm_dialog.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/insufficient_xp_dialog.dart';
import '../../widgets/mount_stagger.dart';
import '../../widgets/shimmer_loader.dart';
import '../../providers/subscription_provider.dart';
import '../../sheets/upgrade_cta_sheet.dart';
import '../family/widgets/incoming_family_invite_card.dart';
import 'widgets/battle_card.dart';

/// Session-local set of series IDs the user has stopped via the
/// inline "Stop recurring" action. Populated on successful
/// [BattleService.stopSeries] and read by [_stopRecurringCallback]
/// to hide the button on the next rebuild — otherwise the button
/// keeps showing until app restart because BattleModel doesn't
/// hydrate `battle_series.status`, and `battle_participants` realtime
/// doesn't fire when only the series row flips.
///
/// Session-only is fine: on cold-start the series is refetched and
/// its post-stop lifecycle (settle_daily_battle marking the series
/// stopped, no more spawn, etc.) means the whole battle typically
/// won't reappear in the "active" list at all.
final _clientStoppedSeriesIdsProvider =
    StateProvider<Set<String>>((_) => const {});

class BattlesScreen extends ConsumerStatefulWidget {
  const BattlesScreen({super.key});

  @override
  ConsumerState<BattlesScreen> createState() => _BattlesScreenState();
}

class _BattlesScreenState extends ConsumerState<BattlesScreen> {
  @override
  void initState() {
    super.initState();
    // Auto-cancel any pending battles older than 24h that the user
    // created, and pull scheduled battles into the active state.
    // Battle COMPLETION is server-owned since 1.1.6+29 (see the block
    // comment on battle_service.completeExpiredBattles); we no longer
    // call that here — the server cron settles the pot and flips
    // status, and the "Ending…" pill on active-past-end-time cards
    // covers the ~60 s transition window for the user.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = ref.read(authStateProvider).valueOrNull?.id;
      if (uid != null) {
        final svc = ref.read(battleServiceProvider);
        svc.cancelExpiredPendingBattles(uid);
        svc.activateScheduledBattles(uid);
      }
      // [3D-DISABLED-2026-08-21] — WebView priming skipped. The 3D
      // character system is disabled, so the WebView never mounts and
      // priming it wastes ~500-1000 ms of CPU on every Battles tab
      // open. Re-enable alongside the rest of the 3D stack.
      //
      // Prime the WebView engine so the first `Flutter3DViewer` mount
      // (avatar customizer / arena) doesn't pay the ~500-1000 ms
      // cold-start. The user is on the Battles tab → arena open is
      // seconds away; this is the right place for this warmup, not
      // during the splash where it competed with first-paint I/O.
      // unawaited(MediaWarmup.primeWebViewEngine());
    });
  }

  @override
  Widget build(BuildContext context) {
    // ── Tour sheet driver ─────────────────────────────────────────
    // Dynamic format flow (2026-09-09 user request): step 6 opens
    // NewBattleSelectionSheet. The user can pick 1v1, Multi or Team.
    //   • Pick 1v1 (or just tap tour's Next) → continue with steps
    //     7-10 in Battle1v1SetupSheet.
    //   • Pick Multi → open BattleGroupSetupSheet and let user
    //     explore; skip the 1v1-specific steps 7-10 → jump to 11.
    //   • Pick Team → team lobby route opens; skip to 11.
    //
    // All battle-flow steps are INTERACTIVE — the user can tap the
    // actual buttons, tiles, and pickers.
    ref.listen(tourControllerProvider, (prev, next) {
      final prevSheet = prev?.currentStep?.sheet;
      final nextSheet = next.currentStep?.sheet;
      AppLogger.tour.i('battlesListener:fire', fields: {
        'prevActive': (prev?.active ?? false).toString(),
        'nextActive': next.active.toString(),
        'prevStep': prev?.stepIndex.toString() ?? 'null',
        'nextStep': next.stepIndex.toString(),
        'prevSheet': prevSheet?.name ?? 'null',
        'nextSheet': nextSheet?.name ?? 'null',
        'prevTargetId': prev?.currentStep?.targetId.name ?? 'null',
        'nextTargetId': next.currentStep?.targetId.name ?? 'null',
      });

      // ── Tour-just-ended teardown (2026-09-13) ─────────────────────
      // When the user taps the X on the tour card, notifier.skip()
      // flips the state to idle. Anything the tour is currently
      // showing on this branch's navigator — NewBattleSelectionSheet
      // (step 7), Battle1v1SetupSheet (steps 8-11), or BattleGroup
      // SetupSheet (side-effect opened on the Multi flow after the
      // tour has advanced past step 12, where currentStep.sheet is
      // null and the regular open/close diff wouldn't catch it) —
      // needs to come down.
      //
      // Only ONE sheet is ever tour-owned at a time (the listener
      // below pops the previous relevant sheet before opening the
      // next one), so a single nav.pop() clears the tour-owned top
      // WITHOUT wiping any pre-existing pushed route that lived
      // BELOW it (e.g. a replay triggered from Settings leaves
      // /settings under the tour sheets — we don't want to pop that
      // too). Fires ONLY on the active→idle transition; per-step
      // advancing continues below.
      final tourJustEnded = prev != null && prev.active && !next.active;
      if (tourJustEnded) {
        AppLogger.tour.i('battlesListener:branch:tourJustEnded');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final nav = Navigator.of(context, rootNavigator: false);
          // Names of every route the tour listeners push onto the
          // shell branch nav (2026-09-22 team-flow additions
          // included). Popping only the top-most tour-owned route
          // leaves stacked cases half-cleaned (e.g. team-flow ends
          // with AddFriendsSheet on top of TeamLobbyPage on top of
          // BattlesScreen). popUntil the first NON-tour route so
          // every layer the tour pushed comes down at once.
          const tourRoutes = {
            'tour_add_friends',
            'tour_multi_setup',
            'tour_team_confirm',
            'tour_team_lobby',
          };
          if (nav.canPop()) {
            AppLogger.tour.i('battlesListener:tourJustEnded:popUntilNonTour');
            nav.popUntil((route) {
              final name = route.settings.name;
              return name == null || !tourRoutes.contains(name);
            });
          }
        });
        return;
      }

      // ── Nested AddFriendsSheet handling (2026-09-14) ─────────────
      // Step 9 "Pick a friend" (targetId addFriendsSheetRoot, sheet
      // addFriends) is a NESTED sheet — it stacks on top of Battle
      // 1v1 Setup rather than replacing it. Battle1v1SetupSheet's
      // _pickOpponent pushes the sheet and advances the tour on the
      // way IN, so this branch only handles the way OUT:
      //   • Whether the sheet closed via user tap-to-pick, manual
      //     dismiss, or a Next tap on the tour card, popUntil the
      //     named 'tour_add_friends' route makes sure AddFriendsSheet
      //     is off the nav so the next tour step's target (duration
      //     picker inside Battle 1v1 Setup) is reachable.
      //   • popUntil is idempotent — if the sheet has already been
      //     popped by _toggleSelect's Navigator.pop, the condition
      //     already holds at the top and no unwanted pop of Battle
      //     1v1 Setup happens.
      //   • The INBOUND transition (battle1v1Setup → addFriends) is
      //     handled entirely by _pickOpponent — the listener has
      //     nothing to do on that side; short-circuit early.
      if (prevSheet == TourSheet.addFriends &&
          nextSheet != TourSheet.addFriends) {
        AppLogger.tour.i('battlesListener:branch:addFriendsOutbound');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final nav = Navigator.of(context, rootNavigator: false);
          nav.popUntil((route) => route.settings.name != 'tour_add_friends');
        });
        return;
      }
      if (nextSheet == TourSheet.addFriends) {
        AppLogger.tour.i('battlesListener:branch:addFriendsInbound');
        return;
      }
      // ── Nested BattleGroupSetupSheet handling (2026-09-21) ────────
      // Step 13 "Invite players" (targetId battleGroupAddPlayers,
      // sheet battleGroupSetup) is only reached on the Multi flow —
      // the format-picker's post-await code opens the Multi setup
      // sheet and awaits it there. This branch handles the OUTBOUND
      // transition:
      //   • Whether the sheet closed via user tap-to-close, drag-
      //     dismiss, or a Next tap on the tour card while the sheet
      //     is still open, popUntil the 'tour_multi_setup' named
      //     route makes sure the Multi sheet is off the nav so the
      //     next tour step's target (Discover open-battles card on
      //     the underlying Battles page) is reachable.
      //   • popUntil is idempotent — if the sheet closed itself
      //     first, the top no longer carries the name and no
      //     unwanted pop of a real user route happens.
      //   • INBOUND (battle1v1Setup / newBattleSelection → battle
      //     GroupSetup) is entirely handled by the format-picker's
      //     post-await code — short-circuit early.
      if (prevSheet == TourSheet.battleGroupSetup &&
          nextSheet != TourSheet.battleGroupSetup) {
        AppLogger.tour.i('battlesListener:branch:battleGroupOutbound');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final nav = Navigator.of(context, rootNavigator: false);
          nav.popUntil((route) => route.settings.name != 'tour_multi_setup');
        });
        return;
      }
      if (nextSheet == TourSheet.battleGroupSetup) {
        AppLogger.tour.i('battlesListener:branch:battleGroupInbound');
        return;
      }

      // ── Team confirm dialog handling (2026-09-22) ─────────────────
      // Step 18 "Confirm the team battle" (targetId
      // teamConfirmUseEntryButton, sheet teamConfirmDialog) is only
      // reached when the user picks Team at step 7. The format-picker
      // post-await block opens the confirm dialog with a named route.
      // OUTBOUND: whether the dialog closed via tap-through (Use
      // entry & open), Cancel, or Next on the tour card, popUntil the
      // 'tour_team_confirm' name so the dialog is off the nav before
      // we push the team lobby page.
      if (prevSheet == TourSheet.teamConfirmDialog &&
          nextSheet != TourSheet.teamConfirmDialog) {
        AppLogger.tour.i('battlesListener:branch:teamConfirmOutbound');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final nav = Navigator.of(context, rootNavigator: false);
          nav.popUntil(
              (route) => route.settings.name != 'tour_team_confirm');
        });
        return;
      }
      if (nextSheet == TourSheet.teamConfirmDialog) {
        AppLogger.tour.i('battlesListener:branch:teamConfirmInbound');
        return;
      }

      // ── Team lobby page handling (2026-09-22) ─────────────────────
      // Steps 19-22 + 24 (teamLobby sheet marker) render on top of
      // the shell branch navigator (not the root nav) so the overlay
      // stays above. OUTBOUND: pop any 'tour_team_lobby' route left
      // on the stack when the tour advances OFF teamLobby (usually
      // when landing on Discover, step 25).
      if (prevSheet == TourSheet.teamLobby &&
          nextSheet != TourSheet.teamLobby &&
          nextSheet != TourSheet.addFriends) {
        AppLogger.tour.i('battlesListener:branch:teamLobbyOutbound');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final nav = Navigator.of(context, rootNavigator: false);
          nav.popUntil(
              (route) => route.settings.name != 'tour_team_lobby');
        });
        return;
      }
      if (nextSheet == TourSheet.teamLobby &&
          prevSheet != TourSheet.teamConfirmDialog) {
        // Intra-team-lobby step change (chips → dates → stake, etc.)
        // or return from AddFriendsSheet — nothing to open/close, just
        // let the overlay re-measure the new target.
        AppLogger.tour.i('battlesListener:branch:teamLobbyIntraStep');
        return;
      }

      if (prevSheet == nextSheet) {
        AppLogger.tour.i('battlesListener:noop', fields: {
          'reason': 'sameSheet',
          'sheet': (prevSheet?.name ?? 'null'),
        });
        return;
      }
      final relevant = {
        TourSheet.newBattleSelection,
        TourSheet.battle1v1Setup,
      };
      if (!relevant.contains(prevSheet) && !relevant.contains(nextSheet)) {
        AppLogger.tour.i('battlesListener:noop', fields: {
          'reason': 'irrelevantSheets',
          'prevSheet': prevSheet?.name ?? 'null',
          'nextSheet': nextSheet?.name ?? 'null',
        });
        return;
      }
      AppLogger.tour.i('battlesListener:schedulePostFrame', fields: {
        'prevSheet': prevSheet?.name ?? 'null',
        'nextSheet': nextSheet?.name ?? 'null',
      });
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        AppLogger.tour.i('battlesListener:postFrame:start', fields: {
          'prevSheet': prevSheet?.name ?? 'null',
          'nextSheet': nextSheet?.name ?? 'null',
        });
        final nav = Navigator.of(context, rootNavigator: false);
        // Pop the previous tour sheet if it's still on top.
        if (relevant.contains(prevSheet) && nav.canPop()) {
          AppLogger.tour.i('battlesListener:postFrame:popPrevSheet');
          nav.pop();
        }
        if (nextSheet == TourSheet.newBattleSelection) {
          AppLogger.tour.i('battlesListener:openNewBattleSelectionSheet');
          // Reset the format choice each time we enter step 7 (the
          // "Pick a format" step, formerly 6 before the change-goal
          // INTRO shifted battle-flow indices +1) so a replay of the
          // tour starts from a clean slate.
          ref.read(tourBattleFormatChoiceProvider.notifier).state = null;
          await NewBattleSelectionSheet.show(
            context,
            useRootNavigator: false,
            barrierColor: Colors.transparent,
          );
          if (!mounted) return;
          AppLogger.tour.i('battlesListener:newBattleSelectionClosed');
          // Selection sheet closed. Advance the tour past step 6.
          final notifier = ref.read(tourControllerProvider.notifier);
          var state = ref.read(tourControllerProvider);
          while (state.active &&
              state.currentStep?.sheet == TourSheet.newBattleSelection) {
            AppLogger.tour.i('battlesListener:advance:pastNewBattleSelection',
                fields: {'at': state.stepIndex.toString()});
            await notifier.next();
            state = ref.read(tourControllerProvider);
          }
          if (!mounted) return;
          // Check the user's choice and route accordingly.
          final choice = ref.read(tourBattleFormatChoiceProvider);
          AppLogger.tour.i('battlesListener:formatChoice', fields: {
            'choice': choice?.toString() ?? 'null',
            'label': choice == 0
                ? '1v1'
                : choice == 1
                    ? 'multi'
                    : choice == 2
                        ? 'team'
                        : 'default',
          });
          if (choice == 1 || choice == 2) {
            // Multi/Team — skip past ALL 1v1-specific battle-setup
            // steps: battle1v1Setup sheet (Choose opponent, Set the
            // window, Stake, Send invite) AND the nested addFriends
            // step (Pick a friend). The 2026-09-21 loop condition
            // covers both — before that fix, the loop only skipped
            // battle1v1Setup and stopped on step 9 (addFriends),
            // leaving the tour hovering over a non-existent target
            // while the Multi sheet opened underneath.
            state = ref.read(tourControllerProvider);
            while (state.active &&
                (state.currentStep?.sheet == TourSheet.battle1v1Setup ||
                    state.currentStep?.sheet == TourSheet.addFriends)) {
              await notifier.next();
              state = ref.read(tourControllerProvider);
            }
            if (choice == 1) {
              // Multi flow — now on the Multi-only "Invite players"
              // step (sheet: battleGroupSetup). Open the Multi setup
              // sheet so the tour target (the PLAYERS row) becomes
              // measurable; when the sheet closes, advance the tour
              // past this Multi step to Discover. Named route so the
              // main tour listener can popUntil this specific sheet
              // when the user taps Next on the tour card while the
              // sheet is still open (2026-09-21).
              await BattleGroupSetupSheet.show(
                // ignore: use_build_context_synchronously
                context,
                useRootNavigator: false,
                barrierColor: Colors.transparent,
                routeSettings: const RouteSettings(name: 'tour_multi_setup'),
                // Lift the Send Battle Invites CTA above the shell's
                // floating nav bar so the "Send the invites" step's
                // spotlight measures on-screen (2026-09-21 user
                // feedback: CTA was falling behind the nav bar).
                useSafeArea: true,
                extraBottomInset: 90,
              );
              if (!mounted) return;
              state = ref.read(tourControllerProvider);
              // Sweep past every downstream battle-setup surface so
              // Multi lands cleanly on Discover after the Multi setup
              // sheet closes (2026-09-22 evening — user report: Next
              // on "Send the invites" was leaving the tour card stuck
              // over an unmeasurable target because the previous loop
              // only skipped battleGroupSetup and the next step is
              // teamConfirmDialog). Covers:
              //   • TourSheet.battleGroupSetup   — Multi steps 13, 15-17
              //   • TourSheet.addFriends         — Multi step 14
              //   • TourSheet.teamConfirmDialog  — Team step 18
              //   • TourSheet.teamLobby          — Team steps 19-23, 25
              while (state.active &&
                  (state.currentStep?.sheet ==
                          TourSheet.battleGroupSetup ||
                      state.currentStep?.sheet == TourSheet.addFriends ||
                      state.currentStep?.sheet ==
                          TourSheet.teamConfirmDialog ||
                      state.currentStep?.sheet == TourSheet.teamLobby)) {
                await notifier.next();
                state = ref.read(tourControllerProvider);
              }
            }
            // choice == 2 (Team) — full tour orchestration (2026-09-22).
            // The New Battle picker's tour path popped the sheet
            // without opening the confirm dialog OR creating the
            // lobby (`_continue` short-circuits when tour is active),
            // so ALL of that is driven from here so it renders under
            // the shell overlay.
            if (choice == 2) {
              // Skip every Multi-only step — battleGroupSetup steps
              // (13, 15, 16, 17) AND the Multi twin of "Pick a friend"
              // at step 14 (addFriends) — to land on step 18
              // "Confirm the team battle".
              state = ref.read(tourControllerProvider);
              while (state.active &&
                  (state.currentStep?.sheet ==
                          TourSheet.battleGroupSetup ||
                      state.currentStep?.sheet == TourSheet.addFriends)) {
                await notifier.next();
                state = ref.read(tourControllerProvider);
              }
              final me = ref.read(currentUserProvider).valueOrNull;
              if (me == null) {
                AppLogger.tour.w('battlesListener:teamFlow:noCurrentUser');
                return;
              }
              // Open confirm dialog under the overlay. Non-root nav +
              // transparent barrier keeps the overlay's dim as the
              // only backdrop; the named route lets the outbound
              // teardown branch popUntil it precisely on tour skip.
              AppLogger.tour.i('battlesListener:teamFlow:openConfirmDialog');
              final confirmed = await showTeamBattleConfirmDialog(
                // ignore: use_build_context_synchronously
                context,
                useRootNavigator: false,
                barrierColor: Colors.transparent,
                routeSettings:
                    const RouteSettings(name: 'tour_team_confirm'),
              );
              if (!mounted) return;
              AppLogger.tour.i('battlesListener:teamFlow:confirmClosed',
                  fields: {'confirmed': confirmed.toString()});
              if (confirmed) {
                // Hide the overlay immediately (before the RPC + push
                // work runs) so the user sees a clean team-lobby load
                // instead of the "Confirm the team battle" card ghost-
                // hovering over the shimmer skeleton. The overlay
                // auto-clears the flag inside `_measureTarget` on the
                // first `measure:committed` for step 19's target, so
                // it reappears the instant the team lobby is ready.
                ref.read(tourOverlaySuspendedProvider.notifier).state = true;
                AppLogger.tour.i(
                    'battlesListener:teamFlow:overlaySuspended');
              }
              if (!confirmed) {
                // Cancel path — advance past teamConfirmDialog step
                // and skip past all downstream team-lobby steps + the
                // trailing addFriends step so the tour lands on
                // Discover.
                AppLogger.tour.i(
                    'battlesListener:teamFlow:skipRestOfTeamSteps');
                state = ref.read(tourControllerProvider);
                while (state.active &&
                    (state.currentStep?.sheet ==
                            TourSheet.teamConfirmDialog ||
                        state.currentStep?.sheet == TourSheet.teamLobby ||
                        state.currentStep?.sheet == TourSheet.addFriends)) {
                  await notifier.next();
                  state = ref.read(tourControllerProvider);
                }
                return;
              }
              // Confirmed path — create lobby BEFORE advancing the
              // tour past teamConfirmDialog. If we advanced first,
              // the tour would land on step 19 (teamLobbyDurationChips)
              // with no team lobby page mounted for ~500 ms while
              // createTeamLobby's RPC ran, leaving the overlay with
              // an unmeasurable target during that gap.
              //
              // 15 s timeout (2026-09-22 afternoon) — the log from
              // an earlier session showed the tour appearing "hung"
              // on Confirm the team battle while createTeamLobby
              // waited on a flaky Supabase realtime channel (channel
              // errors preceded the call). Surfacing the failure
              // instead of hanging indefinitely lets the user retry.
              String battleId;
              try {
                AppLogger.tour.i('battlesListener:teamFlow:createLobby');
                final result = await ref
                    .read(battleServiceProvider)
                    .createTeamLobby(
                      createdBy: me.userId,
                      creatorDisplayName: me.displayName.isEmpty
                          ? 'You'
                          : me.displayName,
                      creatorPreferredName: me.preferredName,
                      creatorAvatarUrl: me.avatarURL,
                    )
                    .timeout(const Duration(seconds: 15));
                battleId = result.battleId;
                AppLogger.tour.i('battlesListener:teamFlow:lobbyCreated',
                    fields: {'battleId': battleId});
              } catch (e) {
                AppLogger.tour.e('battlesListener:teamFlow:createFailed',
                    fields: {'error': e.toString()});
                if (!mounted) return;
                // ignore: use_build_context_synchronously
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('Could not open team lobby: $e')),
                );
                // Skip past confirm + team steps → land on Discover.
                state = ref.read(tourControllerProvider);
                while (state.active &&
                    (state.currentStep?.sheet ==
                            TourSheet.teamConfirmDialog ||
                        state.currentStep?.sheet == TourSheet.teamLobby ||
                        state.currentStep?.sheet == TourSheet.addFriends)) {
                  await notifier.next();
                  state = ref.read(tourControllerProvider);
                }
                return;
              }
              if (!mounted) return;
              // Push TeamLobbyPage onto the shell branch navigator
              // (NOT root) so the overlay stays above. Named route
              // 'tour_team_lobby' lets the outbound branch teardown
              // popUntil it precisely. Store the Future so we can
              // advance the tour NOW (page's TourTargets register
              // during their first frame, right after push) and
              // await the pop only afterwards.
              AppLogger.tour.i(
                  'battlesListener:teamFlow:pushTeamLobbyPage');
              final teamLobbyFuture =
                  // ignore: use_build_context_synchronously
                  Navigator.of(context, rootNavigator: false).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: 'tour_team_lobby'),
                  builder: (_) => TeamLobbyPage(battleId: battleId),
                ),
              );
              // Advance past teamConfirmDialog now that the page is
              // on the nav stack (it will be measurable within a
              // frame or two).
              state = ref.read(tourControllerProvider);
              while (state.active &&
                  state.currentStep?.sheet ==
                      TourSheet.teamConfirmDialog) {
                AppLogger.tour.i(
                    'battlesListener:teamFlow:advancePastConfirm',
                    fields: {'at': state.stepIndex.toString()});
                await notifier.next();
                state = ref.read(tourControllerProvider);
              }
              await teamLobbyFuture;
              if (!mounted) return;
              AppLogger.tour.i(
                  'battlesListener:teamFlow:teamLobbyPageClosed');
              // If the user backed out of the team lobby before the
              // tour advanced through it (e.g. system back), skip
              // remaining team steps to land on Discover.
              state = ref.read(tourControllerProvider);
              while (state.active &&
                  (state.currentStep?.sheet == TourSheet.teamLobby ||
                      state.currentStep?.sheet == TourSheet.addFriends)) {
                AppLogger.tour.i(
                    'battlesListener:teamFlow:advancePastTeamLobbyStep',
                    fields: {'at': state.stepIndex.toString()});
                await notifier.next();
                state = ref.read(tourControllerProvider);
              }
            }
          } else {
            // choice == 0 (1v1) or null (default). The next state
            // transition (entering battle1v1Setup) is picked up by
            // the else branch below on the next listener firing.
          }
          return;
        }
        // Guard added 2026-09-13: only open Battle1v1SetupSheet when
        // it's actually the target of the transition. Without this,
        // any transition where prevSheet ∈ relevant and nextSheet is
        // neither newBattleSelection nor battle1v1Setup — e.g. tour
        // advancing to step 12 (Discover, sheet:null), or a residual
        // firing after the tour-just-ended branch above — would fall
        // through and OPEN a fresh setup sheet on a screen that
        // shouldn't have one. (The tour-just-ended branch already
        // early-returns; this is defence-in-depth for state
        // transitions like battle1v1Setup → null on the last battle
        // step advance.)
        if (nextSheet != TourSheet.battle1v1Setup) {
          AppLogger.tour.i('battlesListener:noop', fields: {
            'reason': 'guardNotBattle1v1Setup',
            'nextSheet': nextSheet?.name ?? 'null',
          });
          return;
        }
        // Multi/Team guard (2026-09-21). When the user picks Multi
        // (or Team) at step 7 and hits Next on the tour card BEFORE
        // tapping Continue in the picker, tour advances 7 → 8
        // (sheet: battle1v1Setup) and this listener firing lands
        // here. Without the guard we'd blindly open Battle1v1Setup
        // Sheet on top of an in-progress Multi/Team flow — the
        // outer newBattleSelection branch's post-await code (which
        // resumes when we popped NewBattleSelectionSheet above)
        // ALREADY handles the Multi path (skip 1v1 steps → open
        // BattleGroupSetupSheet → advance past battleGroupSetup)
        // and the Team path (out to team lobby). Short-circuit so
        // only ONE of the two branches acts on this transition.
        // The 1v1 flow lands here with choice == 0 or null.
        final choice = ref.read(tourBattleFormatChoiceProvider);
        if (choice == 1 || choice == 2) {
          AppLogger.tour.i('battlesListener:noop', fields: {
            'reason': 'multiTeamGuard',
            'choice': choice.toString(),
          });
          return;
        }
        AppLogger.tour.i('battlesListener:openBattle1v1SetupSheet');
        // nextSheet == TourSheet.battle1v1Setup — steps 8-11.
        await Battle1v1SetupSheet.show(
          context,
          useRootNavigator: false,
          barrierColor: Colors.transparent,
          useSafeArea: true,
          // Push Send Battle Invite button above the shell's own
          // bottom nav bar during the tour.
          extraBottomInset: 90,
        );
        if (!mounted) return;
        AppLogger.tour.i('battlesListener:battle1v1SetupSheetClosed');
        final notifier = ref.read(tourControllerProvider.notifier);
        var state = ref.read(tourControllerProvider);
        // Advance past every downstream battle-setup step so the tour
        // lands cleanly on Discover after 1v1 wraps up. Covers:
        //   • TourSheet.battle1v1Setup      — 1v1 steps 8-12
        //   • TourSheet.battleGroupSetup    — Multi steps 13, 15-17
        //   • TourSheet.addFriends          — Multi step 14, Team step 24
        //     (also 1v1 step 9, though we normally get here from 12)
        //   • TourSheet.teamConfirmDialog   — Team step 18
        //   • TourSheet.teamLobby           — Team steps 19-23, 25
        // Without the extra branches the tour would stall on the first
        // step whose sheet isn't listed (2026-09-22 evening — user
        // request: Next on step 12 must advance regardless of Send
        // Battle Invite state).
        while (state.active &&
            (state.currentStep?.sheet == TourSheet.battle1v1Setup ||
                state.currentStep?.sheet == TourSheet.battleGroupSetup ||
                state.currentStep?.sheet == TourSheet.addFriends ||
                state.currentStep?.sheet == TourSheet.teamConfirmDialog ||
                state.currentStep?.sheet == TourSheet.teamLobby)) {
          await notifier.next();
          state = ref.read(tourControllerProvider);
        }
      });
    });

    final theme = Theme.of(context);
    // Strava-style hero header:
    //   ── Row 1 (AppBar) ──────────────────────────────────
    //   Battles                              [+ New Battle]
    //   ── Row 2 (AppBar.bottom) ───────────────────────────
    //   0/60 · Pro Pass · B/W —
    //
    // Title is left-aligned (not centered like the other shell tabs)
    // and up-sized to headlineMedium/w800 so it acts as the anchor
    // for the whole tab. Primary action pinned right, thumb-reachable.
    // Stats collapse to a single muted caption below — one line of
    // secondary information instead of two competing pills.
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 20,
        title: Text(
          'Battles',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: AppColors.onSurface,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          // Info icon — replays the tour SCOPED to the Battles flow
          // (indices 6-12 after 2026-09-13's change-goal INTRO shift:
          // New Battle → selection → 1v1 setup → Discover). Hidden
          // while the tour is running.
          const TourReplayIconButton(
            fromIndex: TourStepRanges.battleFrom,
            untilExclusive: TourStepRanges.battleUntilExclusive,
            tooltip: 'Battles tour',
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            // TourTarget (migration 0062) — step 6 of the new-user
            // tour spotlights the New Battle button (was step 4 pre-
            // 2026-09-13's change-goal INTRO shift).
            child: TourTarget(
              id: TourTargetId.battlesCreateButton,
              child: FilledButton.icon(
                onPressed: () => _showNewBattleSheet(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Battle'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  textStyle: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(28),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _BattlesHeaderCaption(),
            ),
          ),
        ),
      ),
      body: const _BattlesBody(),
    );
  }

  Future<void> _showNewBattleSheet(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Push to root navigator so the sheet covers the shell's bottom nav.
      // Without this, the CTA at the bottom of the setup sheets is hidden
      // behind the floating nav (extendBody: true on the shell scaffold).
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

/// Returns the "Start Now" callback for the pending-battle card when the
/// current user is the creator AND enough people have joined to actually
/// start. Applies to BOTH Group and Team battles under the 24h lifecycle
/// (Migration 0040) — 1v1 has no manual start (opponent's accept fires
/// activation automatically).
///
/// Gating rules mirror [BattleService.startBattleNow]:
///   • Group: creator + ≥1 non-creator acceptor
///   • Team:  creator + ≥1 non-creator acceptor + ≥2 teams have members
VoidCallback? _startBattleNowCallback(
  BuildContext context,
  WidgetRef ref,
  BattleModel b,
  String uid,
) {
  if (b.type == BattleType.oneVsOne) return null;
  if (b.status != BattleStatus.pending) return null;
  if (b.createdBy != uid) return null;

  final accepted = b.participants
      .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
      .toList();
  final nonCreatorAcceptors =
      accepted.where((p) => p.userId != uid).length;
  if (nonCreatorAcceptors < 1) return null;

  if (b.type == BattleType.team) {
    final teamsWithMembers = <String>{
      for (final p in accepted)
        if (p.teamLabel != null) p.teamLabel!,
    };
    if (teamsWithMembers.length < 2) return null;
  }

  return () async {
    final pending = b.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.pending)
        .length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start with current players?'),
        content: Text(
          pending == 0
              ? 'Roster locks and the clock starts immediately.'
              : '$pending player${pending == 1 ? "" : "s"} still pending. '
                  "They'll be dropped and the clock starts immediately.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Start now'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(battleServiceProvider).startBattleNow(
            battleId: b.battleId,
            actorId: uid,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Battle started!')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
    }
  };
}

/// Returns the "Leave lobby" callback for non-creator participants of a
/// pending team battle. Returns null unless ALL of these hold:
///   • Battle is a team battle
///   • Battle is still pending (lobby, not active/completed)
///   • Current user IS a participant with `invite_status = accepted`
///   • Current user is NOT the creator (they use the sheet's Cancel
///     button to end the whole lobby)
///
/// On tap: confirmation dialog, then [BattleService.leaveTeamBattle]
/// (Migration 0042's `refund_participant_stake` RPC — refunds the
/// leaver's stake + marks them rejected). Everyone else's pot shrinks
/// in real time via the participants stream.
VoidCallback? _leaveLobbyCallback(
  BuildContext context,
  WidgetRef ref,
  BattleModel b,
  String uid,
) {
  if (b.type != BattleType.team) return null;
  if (b.status != BattleStatus.pending) return null;
  if (b.createdBy == uid) return null;
  final me = b.participantFor(uid);
  if (me == null) return null;
  if (me.inviteStatus != ParticipantInviteStatus.accepted) return null;
  return () async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Leave this lobby?'),
        content: Text(
          b.stakeXp > 0
              ? 'You\'ll get your ${b.stakeXp} XP stake back. The remaining players stay in the lobby.'
              : 'You\'ll leave the lobby. The remaining players stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(battleServiceProvider).leaveTeamBattle(
            battleId: b.battleId,
            userId: uid,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              b.stakeXp > 0
                  ? 'Left the lobby. ${b.stakeXp} XP refunded.'
                  : 'Left the lobby.',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not leave: $e')),
        );
      }
    }
  };
}

/// Returns the `onStopRecurring` callback to pass to [BattleCard] for `b`,
/// or null when the action shouldn't render (battle isn't part of a series,
/// or the current user isn't its creator). The callback prompts the user
/// for confirmation and then calls [BattleService.stopSeries].
VoidCallback? _stopRecurringCallback(
  BuildContext context,
  WidgetRef ref,
  BattleModel b,
  String uid,
) {
  if (b.seriesId == null || b.createdBy != uid) return null;
  // Hide the button after the creator has stopped the series in this
  // session. Reads (not watches) — the caller is `build` which already
  // watches the battle stream via other providers, and a change to the
  // stopped-set triggers a rebuild via the `.watch` in the section
  // header (see _StoppedSeriesWatcher). See
  // `_clientStoppedSeriesIdsProvider` for why session-local is fine.
  if (ref.watch(_clientStoppedSeriesIdsProvider).contains(b.seriesId)) {
    return null;
  }
  return () async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop daily recurrence?'),
        content: const Text(
          "Today's battle still finishes normally. No new daily instances "
          'will be created starting tomorrow.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep recurring'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Stop recurring'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(battleServiceProvider).stopSeries(b.seriesId!);
      // Optimistically mark the series stopped so the button hides
      // on the next rebuild. Any provider watching this set (see
      // _stopRecurringCallback above) will re-evaluate and now
      // return null instead of the callback.
      ref.read(_clientStoppedSeriesIdsProvider.notifier).update(
            (s) => {...s, b.seriesId!},
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Daily series stopped. No new instances tomorrow.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stop: $e')),
        );
      }
    }
  };
}

/// Muted single-line caption under the Battles title. Collapses what
/// used to be two pills (subscription usage + B/W ratio) plus the tier
/// name into one Strava-style stats line:
///
///   `0/60 · Pro Pass · B/W 45%`
///
/// The usage segment tints amber/red as the user nears their monthly
/// cap so the free-tier ceiling is still visible at a glance — the
/// rest of the line stays in the muted secondary tone. Tap anywhere
/// opens the upgrade CTA sheet (same affordance the old pill had).
class _BattlesHeaderCaption extends ConsumerWidget {
  const _BattlesHeaderCaption();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final uid = ref.watch(authStateProvider).valueOrNull?.id;
    final sub = ref.watch(subscriptionProvider);
    final used = sub.usage.totalEntries;
    final cap = sub.limits.monthlyBattleEntries;
    final ratio = cap == 0 ? 0.0 : used / cap;

    // Same colour ladder the old SubscriptionUsagePill used, so the
    // free-tier ceiling still telegraphs urgency once you're close.
    final Color usageColor = ratio < 0.5
        ? AppColors.onSurfaceVariant
        : (ratio < 0.85 ? AppColors.amber : AppColors.error);

    String bwLabel = 'B/W —';
    if (uid != null) {
      final stats = ref.watch(battleWinStatsProvider(uid)).valueOrNull;
      final bw = stats == null ? null : battleWinRatioOf(stats);
      if (bw != null) bwLabel = 'B/W ${(bw * 100).toStringAsFixed(0)}%';
    }

    final baseStyle = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.onSurfaceVariant,
      fontFamily: 'Manrope',
      fontWeight: FontWeight.w600,
      fontSize: 12.5,
      letterSpacing: 0.1,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showUpgradeCtaSheet(context),
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: baseStyle,
          children: [
            TextSpan(
              text: '$used/$cap',
              style: TextStyle(color: usageColor, fontWeight: FontWeight.w800),
            ),
            const TextSpan(text: '  ·  '),
            TextSpan(text: sub.tier.displayName),
            const TextSpan(text: '  ·  '),
            TextSpan(text: bwLabel),
          ],
        ),
      ),
    );
  }
}

class _BattlesBody extends ConsumerWidget {
  const _BattlesBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allBattles = ref.watch(allBattlesProvider);

    // Show the live reconnecting pill above whatever the body renders.
    // Realtime errors should never reach the user as raw exception text;
    // `retryingRealtimeStream` (see battle_provider.dart) keeps the
    // StreamProvider in a value state and surfaces the reconnect state
    // via [battlesReconnectingProvider] instead.
    final reconnecting = ref.watch(battlesReconnectingProvider);

    Widget body;
    body = allBattles.when(
      // Phase 2 cache-then-network normally paints the last-known list
      // immediately, so this loading branch only fires on true cold
      // boot with no cache (fresh install / just-signed-in). Shimmer
      // cards read as "content coming" instead of the ambiguous spinner
      // that made a fresh install look like a broken load.
      loading: () => ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        children: const [
          SizedBox(height: 8),
          ShimmerCard(),
          SizedBox(height: 12),
          ShimmerCard(),
          SizedBox(height: 12),
          ShimmerCard(),
        ],
      ),
      // Non-transient errors only — transient realtime drops are caught
      // by the retry wrapper before they ever reach this branch.
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load battles. Pull to retry.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
      ),
      data: (_) => const _BattlesListOrEmpty(),
    );

    // Stack the body under a slim "Reconnecting…" pill while the
    // realtime stream is retrying. Pill is intentionally small + at the
    // top so it doesn't obscure content during normal reconnects.
    //
    // Wrap the body in a RefreshIndicator so the user can pull down to
    // re-fetch the battles list on demand. The realtime provider stays
    // live in normal operation; refresh is the escape hatch after a
    // long offline stretch or when the tester wants a definitive
    // "give me the latest right now."
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(allBattlesProvider);
            await Future<void>.delayed(const Duration(milliseconds: 400));
          },
          child: body,
        ),
        if (reconnecting)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.primary),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Reconnecting…',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// Body dispatcher — picks between empty state and the per-section list.
// Consumers below each watch ONE bucket so a step-count tick on an active
// battle only rebuilds the Active section, not the Completed / Scheduled /
// Discover / Invites tree above and below it.
// =============================================================================

class _BattlesListOrEmpty extends ConsumerWidget {
  const _BattlesListOrEmpty();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `.select` narrows the uid watch so an auth-provider tick that
    // doesn't change the user id (e.g. token refresh) doesn't rebuild
    // the whole list.
    final uid = ref.watch(
      authStateProvider.select((a) => a.valueOrNull?.id ?? ''),
    );
    // `hasAnyBattlesProvider` is a plain bool so the empty \u2194 non-empty
    // transition is the only thing that rebuilds this widget. The
    // per-section consumers below take care of their own live updates.
    final hasAny = ref.watch(hasAnyBattlesProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      cacheExtent: 800,
      children: [
        // Discover tile ALWAYS renders \u2014 including for brand-new
        // users with zero battles. A newcomer's fastest path to
        // their first battle is joining a public one; hiding this
        // behind "have at least one battle first" inverted the
        // funnel. The RepaintBoundary keeps ambient ticks from
        // dirtying the compositor here.
        //
        // TourTarget (tour step 11 \u2014 "Discover public battles"): wraps
        // this entry tile on the Battles MAIN screen instead of the
        // first _PublicLobbyCard on the /battles/discover subroute so
        // the tour stays on the shell tab, doesn't need a route push,
        // and highlights the discovery entry point users actually see.
        RepaintBoundary(
          child: TourTarget(
            id: TourTargetId.discoverLobbyCard,
            child: _DiscoverEntryTile(
              onTap: () => context.push('/battles/discover'),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Pending Family-Pass invites \u2014 self-hides when empty.
        const IncomingFamilyInviteSection(),

        if (hasAny) ...[
          // Each section subscribes to ONLY its own bucket. An
          // Active-battle step tick doesn't walk the Completed /
          // Scheduled / Discover subtrees.
          _IncomingBattleInvitesSection(uid: uid),
          _ActiveBattlesSection(uid: uid),
          _ScheduledBattlesSection(uid: uid),
          _CompletedBattlesSection(uid: uid),
        ] else
          _EmptyBattlesInlineCard(
            onStartBattle: () => _showNewBattleSheet(context),
          ),
      ],
    );
  }

  void _showNewBattleSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

/// Compact inline empty-state card shown BELOW the persistent
/// Discover tile when the user has no battles yet. Deliberately
/// smaller than the full-screen `EmptyState` widget so it doesn't
/// out-shout the Discover CTA above it \u2014 the primary invitation is
/// "jump into a public battle"; this is the secondary "or start
/// your own".
class _EmptyBattlesInlineCard extends StatelessWidget {
  final VoidCallback onStartBattle;
  const _EmptyBattlesInlineCard({required this.onStartBattle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.onSurface.withValues(alpha: 0.05),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.bolt, color: AppColors.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No battles yet',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Jump into a public battle above, or challenge a friend to a private one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: onStartBattle,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Start a Battle'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingBattleInvitesSection extends ConsumerWidget {
  final String uid;
  const _IncomingBattleInvitesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming =
        ref.watch(incomingBattleInvitesProvider).valueOrNull ?? const [];
    if (incoming.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Incoming Invites',
          count: incoming.length,
          highlight: true,
        ),
        const SizedBox(height: 12),
        ...incoming.map((b) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: RepaintBoundary(
                child: _IncomingInviteCard(battle: b, currentUserId: uid),
              ),
            )),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ActiveBattlesSection extends ConsumerWidget {
  final String uid;
  const _ActiveBattlesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeBattlesProvider);
    if (active.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title: 'Active Battles', count: active.length),
        const SizedBox(height: 12),
        // Stagger only the first 6 cards on mount — a long active-list
        // shouldn't stall the section render. Cards use battleId in
        // their outer Padding key so identity stays stable across
        // Riverpod ticks and animations don't replay.
        MountStagger(
          animateCount: 6,
          children: [
            for (final b in active)
              Padding(
                key: ValueKey('active-${b.battleId}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: BattleCard(
                  battle: b,
                  currentUserId: uid,
                  onTap: () => context.push('/battle-ground/${b.battleId}'),
                  onStopRecurring:
                      _stopRecurringCallback(context, ref, b, uid),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ScheduledBattlesSection extends ConsumerWidget {
  final String uid;
  const _ScheduledBattlesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduled = ref.watch(scheduledBattlesProvider);
    if (scheduled.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Waiting for Opponent',
          count: scheduled.length,
          onChevronTap: () => context.go('/battles/pending'),
        ),
        const SizedBox(height: 12),
        MountStagger(
          animateCount: 6,
          children: [
            for (final b in scheduled)
              Padding(
                key: ValueKey('scheduled-${b.battleId}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: BattleCard(
                  battle: b,
                  currentUserId: uid,
                  onTap: () {
                    // Team battle cards route to the full-screen lobby
                    // page — creator + joiners share the same URL so an
                    // accidental back-swipe out of the lobby leaves it
                    // reopenable in the same state.
                    if (b.type == BattleType.team) {
                      context.push('/team-lobby/${b.battleId}');
                    } else {
                      showPendingBattleActionsSheet(
                        context,
                        battle: b,
                        currentUserId: uid,
                      );
                    }
                  },
                  onStopRecurring:
                      _stopRecurringCallback(context, ref, b, uid),
                  onStartTeamBattle:
                      _startBattleNowCallback(context, ref, b, uid),
                  onLeaveLobby:
                      _leaveLobbyCallback(context, ref, b, uid),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _CompletedBattlesSection extends ConsumerWidget {
  final String uid;
  const _CompletedBattlesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Preview uses the lean top-5 provider so this section only
    // rebuilds when one of the visible five actually changes —
    // historical completed churn is invisible here.
    final recent = ref.watch(recentCompletedBattlesProvider);
    if (recent.isEmpty) return const SizedBox.shrink();
    // Peek the full provider only for the "show all" chevron count
    // — reading it here doesn't materialise the full list into
    // widget space, just uses its length for the badge.
    final fullLength = ref.watch(completedBattlesProvider).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Completed',
          count: fullLength,
          onChevronTap: fullLength > 5
              ? () => context.push('/battles/completed')
              : null,
        ),
        const SizedBox(height: 12),
        MountStagger(
          animateCount: 6,
          children: [
            for (final b in recent)
              Padding(
                key: ValueKey('completed-${b.battleId}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: BattleCard(
                  battle: b,
                  currentUserId: uid,
                  onTap: () => context.push('/battle-status/${b.battleId}'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// Incoming battle invite card with Accept / Reject
// =============================================================================
class _IncomingInviteCard extends ConsumerStatefulWidget {
  final BattleModel battle;
  final String currentUserId;

  const _IncomingInviteCard({
    required this.battle,
    required this.currentUserId,
  });

  @override
  ConsumerState<_IncomingInviteCard> createState() =>
      _IncomingInviteCardState();
}

class _IncomingInviteCardState extends ConsumerState<_IncomingInviteCard> {
  bool _busy = false;

  Future<void> _accept() async {
    // Subscription gate — pick the right decision by battle visibility.
    // Invites always flow through the private-join counter unless the
    // battle is a public one someone tapped-to-join with a code (which
    // is discover_battles flow, not this).
    final isPublic = widget.battle.visibility == BattleVisibility.public;
    final decision = isPublic
        ? ref.read(canJoinPublicBattleProvider)
        : ref.read(canJoinPrivateBattleProvider);
    if (!decision.allowed) {
      await showUpgradeCtaSheet(
        context,
        focusTier: decision.upgradeTo,
      );
      return;
    }
    // Insufficient-XP pre-check on the accept side. acceptInvite
    // charges the stake server-side; if we let it run, the RPC
    // rejects with a generic error and the invite gets stuck in a
    // half-accepted state. Show the buy-XP path first, and only
    // call acceptInvite if the user has (or gains) enough XP.
    final stake = widget.battle.stakeXp;
    if (stake > 0) {
      final me = ref.read(currentUserProvider).valueOrNull;
      final balance = me?.totalXP ?? 0;
      if (balance < stake) {
        await showInsufficientXpDialog(
          context,
          required: stake,
          balance: balance,
          action: 'accept this invite',
        );
        return;
      }
    }
    setState(() => _busy = true);
    var accepted = false;
    try {
      await ref.read(battleServiceProvider).acceptInvite(
            battleId: widget.battle.battleId,
            userId: widget.currentUserId,
          );
      accepted = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not accept: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
    // Post-accept routing per battle type:
    //
    //   • Team  → team lobby. The battle stays pending until the
    //     creator hits Start, so pushing to arena early would show
    //     an empty leaderboard.
    //   • 1v1   → arena. acceptInvite runs _snapAndActivate the
    //     moment the opponent accepts, so the battle is already
    //     active by the time we push. This is what the tester asked
    //     for — accepting an invite should land the invitee in the
    //     arena, not leave them staring at the Battles list.
    //   • Group → arena, same reasoning (last-accept flips status
    //     to active via _snapAndActivate or _activateBattle).
    if (accepted && mounted) {
      if (widget.battle.type == BattleType.team) {
        context.push('/team-lobby/${widget.battle.battleId}');
      } else {
        context.push('/battle-ground/${widget.battle.battleId}');
      }
    }
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      await ref.read(battleServiceProvider).rejectInvite(
            battleId: widget.battle.battleId,
            userId: widget.currentUserId,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reject: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final battle = widget.battle;

    // Find the inviter (the first participant who accepted — usually the creator)
    final inviter = battle.participants.firstWhere(
      (p) => p.userId == battle.createdBy,
      orElse: () => battle.participants.first,
    );

    final typeLabel = switch (battle.type) {
      BattleType.oneVsOne => '1v1',
      BattleType.group => 'Multi battle',
      BattleType.team => 'Team',
    };

    return GlassCard(
      padding: const EdgeInsets.all(16),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarCircle(
                radius: 22,
                imageUrl: inviter.avatarURL,
                initials: inviter.friendlyName.isNotEmpty
                    ? inviter.friendlyName[0].toUpperCase()
                    : '?',
                borderColor: AppColors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Line 1: "who challenged you" — kept regardless of
                    // custom name, since on an invite tile the challenger
                    // identity is more important than the battle title.
                    Text('${inviter.friendlyName} challenged you',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    // Line 2: substitute the custom battle name for the
                    // type label when set (migration 0061). Falls back
                    // to "$typeLabel battle" (e.g. "1v1 battle") when
                    // the creator left the name blank.
                    Text(
                      '${battle.name ?? '$typeLabel battle'} · ${battle.durationDays}-day duration · +${battle.stakeXp} XP on win',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_busy)
            Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _reject,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.4)),
                      foregroundColor: AppColors.error,
                    ),
                    child: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _accept,
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Persistent tile that points to the public lobby list. Doubles as a
/// "paste join code" entry point (long-press → dialog).
class _DiscoverEntryTile extends ConsumerWidget {
  final VoidCallback onTap;
  const _DiscoverEntryTile({required this.onTap});

  Future<void> _pasteCode(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: const Text('Join with code'),
        content: TextField(
          controller: controller,
          textCapitalization: TextCapitalization.characters,
          maxLength: 6,
          decoration: const InputDecoration(
            hintText: 'e.g. A4X9KP',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim().toUpperCase()),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (code == null || code.length != 6) return;
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    try {
      final battleId =
          await ref.read(battleServiceProvider).joinByCode(
                code: code,
                userId: me.userId,
                displayName: me.displayName,
                preferredName: me.preferredName,
                avatarUrl: me.avatarURL,
              );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Joined!')),
        );
        context.push('/battle-ground/$battleId');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.travel_explore,
                    color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Discover open battles',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(
                      'Public lobbies you can drop into',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Join with code',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.qr_code, color: AppColors.primary),
                onPressed: () => _pasteCode(context, ref),
              ),
              Icon(Icons.chevron_right, color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool highlight;
  final VoidCallback? onChevronTap;

  const _SectionHeader({
    required this.title,
    required this.count,
    this.highlight = false,
    this.onChevronTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chevron = Icon(
      Icons.chevron_right,
      color: onChevronTap != null
          ? AppColors.primary
          : AppColors.primary.withValues(alpha: 0.25),
      size: 24,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: highlight ? AppColors.amber : AppColors.onSurface,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: highlight
                      ? AppColors.amber.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: highlight ? AppColors.amber : AppColors.primary,
                      fontWeight: FontWeight.w900,
                    )),
              ),
            ],
          ],
        ),
        onChevronTap != null
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onChevronTap,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: chevron,
                ),
              )
            : chevron,
      ],
    );
  }
}
