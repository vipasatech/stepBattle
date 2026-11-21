// ignore_for_file: use_build_context_synchronously
//
// _measureTarget crosses an intentional async gap (Future.delayed +
// Scrollable.ensureVisible) then re-fetches the target's context
// from the TourTargetRegistry via its GlobalKey. The re-fetched
// context is fresh at each use, and every use is preceded by a
// `mounted` guard on this state widget. The lint can't recognise
// this pattern because `mounted` refers to `this` widget, not the
// target's — so the warning is a false positive here.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../providers/capability_provider.dart';
import '../../services/capability_service.dart';
import '../../sheets/permission_help_sheet.dart';

import '../../utils/app_logger.dart';
import 'tour_controller.dart';
import 'tour_painters.dart';
import 'tour_step.dart';
import 'tour_target.dart';
import 'tour_tooltip.dart';

/// Full-screen tour overlay — v9 (2026-09-04).
///
/// Fixes vs v8:
///   • Removed the outer `Material` wrapper — Material's ink surface
///     was subtly participating in hit tests and blocking some taps
///     from reaching the underlying sheet's +/- and Save buttons.
///   • Interactive steps (`allowTargetInteraction`) now position the
///     card at the TOP of the screen, out of the way of ANY sheet
///     controls the user needs to hit. Notch points DOWN toward the
///     spotlighted target so the user knows what to touch.
///   • No AbsorbPointer, no `SizedBox.expand()` on interactive steps
///     — the only widget the overlay adds is the dim painter (behind
///     IgnorePointer) + the card (at Positioned). Taps go straight
///     through everywhere else.
///   • Dim stays at 0.75 for strong dark-mode contrast.
class OnboardingTourOverlay extends ConsumerStatefulWidget {
  const OnboardingTourOverlay({super.key});

  @override
  ConsumerState<OnboardingTourOverlay> createState() =>
      _OnboardingTourOverlayState();
}

class _OnboardingTourOverlayState extends ConsumerState<OnboardingTourOverlay> {
  /// True while a permission ask started from the card is in flight —
  /// the OS alert is up, or we are re-probing after it closed.
  bool _allowBusy = false;

  /// Runs the ask behind a step's "Allow" button.
  ///
  /// Deliberately does NOT advance the tour on success. The spotlight is
  /// sitting on the very widget this unlocks, so staying put lets the
  /// user watch the padlock become a number — and when the OS refuses to
  /// prompt and we have to send them to Settings, the flow is still here
  /// when they come back. The button re-reads the capability on every
  /// build, so it turns into "Next" by itself once granted.
  Future<void> _resolveStepPermission(AppCapability capability) async {
    if (_allowBusy) return;
    setState(() => _allowBusy = true);
    try {
      final outcome =
          await ref.read(capabilityServiceProvider).resolve(capability);
      if (outcome == LockOutcome.sentToSettings && mounted) {
        // Name the toggle before throwing them into Settings — the card
        // is still on screen behind the sheet, so the context holds.
        final go = await showPermissionHelpSheet(context, capability);
        if (go) await openAppSettings();
      }
    } finally {
      if (mounted) {
        setState(() => _allowBusy = false);
        ref.read(capabilityRefreshProvider.notifier).state++;
      }
    }
  }

  Rect? _targetRect;
  int? _measuredStepIndex;
  bool _scrolling = false;

  /// Cinematic content swap (2026-09-22): the step whose TITLE +
  /// DESCRIPTION + STEP COUNTER the card is currently painting.
  /// Lags behind [tourState.stepIndex] during a transition — while
  /// the card is sliding to the new target and the spotlight is
  /// morphing to the new rect, we keep displaying the OLD content
  /// (because reading a new message while the box is mid-flight
  /// feels unfinished). Once the position tween settles the swap
  /// fires and an AnimatedSwitcher crossfades the content to the
  /// new step's copy. Null on the very first render — that path
  /// falls back to using the live step directly (no delay needed
  /// on the first ever content paint).
  int? _displayedStepIndex;

  /// Scheduled swap of [_displayedStepIndex] to catch up to
  /// [_measuredStepIndex] after the position tween settles. Cancelled
  /// on step change so successive rapid advances (e.g. user hammering
  /// Next) don't leave a stale prior-step swap racing behind.
  Timer? _swapTimer;

  /// Position tween length. Also the settle delay after which
  /// [_swapTimer] fires the content crossfade. Matched to the
  /// [TweenAnimationBuilder] duration below so the swap lands
  /// EXACTLY when the card is done moving.
  static const Duration _tweenDuration = Duration(milliseconds: 360);

  /// Ease used for both position and content crossfade. `easeInOutCubic`
  /// gives the deliberate ease-in AND ease-out shape that reads as
  /// cinematic, versus `easeOutCubic`'s "spring-arrival" feel.
  static const Curve _tweenCurve = Curves.easeInOutCubic;

  /// Cached gesture-recognizer factories for the target-rect scroll
  /// lock. Built ONCE in [initState] and reused across every rebuild
  /// so [RawGestureDetector] doesn't tear down + rebuild the
  /// [_EarlyPanRecognizer] on every animation frame — that
  /// tear-down cycle was reprocessing recognizer bookkeeping ~19
  /// times per 320 ms transition AND resetting our own accumulator
  /// mid-drag, both of which showed up as visible stutter / hang
  /// between steps (2026-09-21 user report).
  late final Map<Type, GestureRecognizerFactory<GestureRecognizer>>
      _scrollLockGestures;

  @override
  void initState() {
    super.initState();
    _scrollLockGestures =
        <Type, GestureRecognizerFactory<GestureRecognizer>>{
      _EarlyPanRecognizer:
          GestureRecognizerFactoryWithHandlers<_EarlyPanRecognizer>(
        () => _EarlyPanRecognizer(),
        (instance) {
          instance.onStart = (_) {};
          instance.onUpdate = (_) {};
          instance.onEnd = (_) {};
        },
      ),
    };
  }

  @override
  void dispose() {
    _swapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tourState = ref.watch(tourControllerProvider);
    if (!tourState.active) return const SizedBox.shrink();
    final step = tourState.currentStep;
    if (step == null) return const SizedBox.shrink();
    // Suspend flag (2026-09-22 evening) — set by callers who know
    // the underlying screen is mid-transition (currently just the
    // confirm-team-battle → team-lobby handoff). Renders nothing so
    // the user sees the loading UI without a floating card. Cleared
    // inside [_measureTarget] on the first successful measure of the
    // new step.
    //
    // IMPORTANT: read the flag here but do NOT return early yet — the
    // step-change / measure-scheduling code below MUST run even when
    // suspended, otherwise the clear-inside-measure never happens
    // (2026-09-22 evening log evidence: overlay stayed hidden after
    // team lobby loaded because no measure was ever scheduled).
    final suspended = ref.watch(tourOverlaySuspendedProvider);

    if (_measuredStepIndex != tourState.stepIndex) {
      final previousMeasured = _measuredStepIndex;
      _measuredStepIndex = tourState.stepIndex;
      AppLogger.tour.i('overlay:stepChanged', fields: {
        'from': previousMeasured?.toString() ?? 'null',
        'to': tourState.stepIndex.toString(),
        'targetId': step.targetId.name,
        'sheet': step.sheet?.name ?? 'null',
        'keepingOldRect': (_targetRect != null).toString(),
      });
      // First-ever paint: no old content to hold, swap immediately so
      // the tour card can render without a delay on its debut frame.
      // On every subsequent step change, the swap is deferred — the
      // scheduling happens INSIDE the measurement-committed path so
      // it lines up with when the position tween actually starts,
      // not when the state changed (which for sheet steps is ~700 ms
      // earlier than the position begins moving).
      _displayedStepIndex ??= tourState.stepIndex;
      // 2026-09-13: DO NOT clear _targetRect here. Keeping the
      // previous step's rect around lets the spotlight cutout AND
      // the tooltip card smoothly slide/morph to the new position
      // once _measureTarget completes — via the TweenAnimationBuilder
      // below, which auto-tracks the last `end` value as the next
      // tween's `begin`. If we cleared to null the card would
      // teleport to the centred fallback for 350 ms (sheet steps)
      // then teleport again to the measured position, which was
      // the jump-cut the user called out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          AppLogger.tour.i('overlay:measure:aborted', fields: {
            'reason': 'unmountedBeforePostFrame',
            'targetId': step.targetId.name,
          });
          return;
        }
        _measureTarget(step);
      });
    }

    // Suspend guard — return an empty overlay AFTER measure scheduling
    // so the flag can be cleared from inside a successful measure
    // (which is what un-suspends the overlay). See the header comment
    // where `suspended` is read.
    if (suspended) return const SizedBox.shrink();

    // Initial render (no measurement yet) — use the centred fallback
    // card WITHOUT animation; there's nothing to interpolate from.
    // Also block ALL input on this brief window, whether or not the
    // step is nominally interactive — the target isn't measured yet
    // so we have no rect to leave a hole for.
    //
    // The whole overlay is wrapped in a RepaintBoundary (2026-09-21):
    // during the 320 ms step transition the overlay redraws every
    // frame, and without an explicit repaint layer those redraws
    // marked the shell body's paint layer dirty as well — competing
    // with any incoming sheet animation / list layout for the frame
    // budget and showing up as visible stutter. Isolating the tour
    // to its own compositing layer keeps the shell unaffected.
    if (_targetRect == null) {
      return RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: CustomPaint(
                painter: SpotlightPainter(
                  targetRect: null,
                  dimOpacity: 0.75,
                  padding: 0,
                  cornerRadius: 6,
                  featherRadius: 0,
                ),
                size: Size.infinite,
              ),
            ),
            const Positioned.fill(
              child: AbsorbPointer(
                absorbing: true,
                child: SizedBox.expand(),
              ),
            ),
            _centeredCard(context, step, tourState),
          ],
        ),
      );
    }

    // Cinematic transitions between steps (2026-09-22 refinement of
    // the 2026-09-13 slide). TweenAnimationBuilder auto-uses the
    // PREVIOUS `end` value as the next tween's `begin`, so successive
    // rebuilds where _targetRect changes trigger an interpolation
    // between old and new rects. Both the spotlight cutout AND the
    // card position are computed from the ANIMATED rect (not the raw
    // _targetRect) so they slide together as one continuous motion.
    //
    // Cinematic content-swap (see [_displayedStepIndex]): the tooltip
    // TITLE, DESCRIPTION, and STEP COUNTER stay pinned to the OLD
    // step's copy while the card is mid-flight, then crossfade to the
    // NEW copy via AnimatedSwitcher once the position tween settles.
    // Reads as "message finishes moving → new message reveals" rather
    // than "message reflows mid-flight". Duration + curve come from
    // [_tweenDuration] and [_tweenCurve] so tuning is one place.
    return RepaintBoundary(
      child: TweenAnimationBuilder<Rect?>(
      tween: RectTween(end: _targetRect),
      duration: _tweenDuration,
      curve: _tweenCurve,
      builder: (context, animRect, _) {
        // animRect can be null momentarily during the very first
        // frame of a tween; fall back to the final rect so nothing
        // flickers.
        final effectiveRect = animRect ?? _targetRect!;
        final screen = MediaQuery.sizeOf(context);
        // Touch + scroll are BLOCKED outside the highlighted target
        // rect on EVERY step, whether interactive or not:
        //   • non-interactive → one full-screen AbsorbPointer covers
        //     the whole screen (target included), so the user can
        //     only tap the tour card's Next/Back/X buttons.
        //   • interactive → four spatial AbsorbPointer bands cover
        //     everywhere OUTSIDE the target rect (top / bottom /
        //     left / right of the rect). The rect itself has no
        //     absorber over it — taps AND scrolls that start inside
        //     the rect fall through to the underlying widget.
        // Tour card is stacked LAST so its hit tests come first, and
        // its own buttons stay clickable regardless of which region
        // they visually overlap.
        // 2026-09-21 user request: "touch and scroll should be
        // locked outside the highlighted part".
        final absorbers = <Widget>[];
        if (!step.allowTargetInteraction) {
          absorbers.add(const Positioned.fill(
            child: AbsorbPointer(
              absorbing: true,
              child: SizedBox.expand(),
            ),
          ));
        } else {
          final rTop = effectiveRect.top.clamp(0.0, screen.height);
          final rBottom = effectiveRect.bottom.clamp(0.0, screen.height);
          final rLeft = effectiveRect.left.clamp(0.0, screen.width);
          final rRight = effectiveRect.right.clamp(0.0, screen.width);
          final bandHeight =
              (rBottom - rTop).clamp(0.0, screen.height).toDouble();
          final rectWidth =
              (rRight - rLeft).clamp(0.0, screen.width).toDouble();
          absorbers.addAll([
            // Above the target — full-width band from top of screen
            // down to rect.top.
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: rTop,
              child: const AbsorbPointer(
                absorbing: true,
                child: SizedBox.expand(),
              ),
            ),
            // Below the target — full-width band from rect.bottom to
            // bottom of screen.
            Positioned(
              left: 0,
              right: 0,
              top: rBottom,
              bottom: 0,
              child: const AbsorbPointer(
                absorbing: true,
                child: SizedBox.expand(),
              ),
            ),
            // Left band — only across the target's vertical extent
            // (0 → rect.left, rect.top → rect.bottom). Doesn't
            // stretch top-to-bottom because the top/bottom bands
            // already cover those y ranges edge-to-edge.
            Positioned(
              left: 0,
              top: rTop,
              width: rLeft,
              height: bandHeight,
              child: const AbsorbPointer(
                absorbing: true,
                child: SizedBox.expand(),
              ),
            ),
            // Right band — mirror of left, from rect.right to right
            // edge of screen across the target's vertical extent.
            Positioned(
              left: rRight,
              top: rTop,
              right: 0,
              height: bandHeight,
              child: const AbsorbPointer(
                absorbing: true,
                child: SizedBox.expand(),
              ),
            ),
            // Scroll-lock over the target rect ITSELF (2026-09-21):
            // the previous translucent RawGestureDetector registered
            // a stock PanGestureRecognizer at kPanSlop (5 dp), which
            // in theory beats Scrollable's VerticalDragGestureRecognizer
            // at kTouchSlop (18 dp). In practice — especially on
            // Android where MediaQuery.gestureSettings can lift the
            // pan slop AND ties in the arena get resolved in favour
            // of the deeper/scroll-owning recognizer — that wasn't
            // reliable. User reported scroll still bringing outside
            // content into the highlighted rect.
            //
            // Fix: use `_EarlyPanRecognizer` — a PanGestureRecognizer
            // subclass with an aggressive 3-dp acceptance threshold
            // (well below Scrollable's 18) and an internal accumulator
            // that's independent of the parent's private
            // _globalDistanceMoved field. This DEFINITIVELY wins the
            // arena for any real drag before the Scrollable can
            // even declare readiness. Taps still fall through because
            // no TapGestureRecognizer is registered here AND the
            // widget is translucent, so pointer down + pointer up
            // with < 3 dp of drift never wakes the pan.
            Positioned(
              left: rLeft,
              top: rTop,
              width: rectWidth,
              height: bandHeight,
              child: RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                // Reuse the field-cached map — see [_scrollLockGestures]
                // for why identity matters for perf here.
                gestures: _scrollLockGestures,
                child: const SizedBox.expand(),
              ),
            ),
          ]);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: CustomPaint(
                painter: SpotlightPainter(
                  targetRect: effectiveRect,
                  dimOpacity: 0.75,
                  padding: 0,
                  cornerRadius: 6,
                  featherRadius: 0,
                ),
                size: Size.infinite,
              ),
            ),
            ...absorbers,
            _positionedCard(context, step, effectiveRect, tourState),
          ],
        );
      },
    ),
    );
  }

  Future<void> _measureTarget(TourStep step) async {
    // Stale-task guard (2026-09-22 afternoon). During a rapid-fire
    // burst of tour advances (e.g. the Team-flow orchestration that
    // sweeps state 7→8→…→18 in ~50 ms), every intermediate build
    // schedules a `_measureTarget(step)` for THAT frame's step. When
    // state settles at the final step, all the intermediate tasks
    // are still queued — each one captures a targetId whose widget
    // will never mount, and each retries indefinitely via
    // `addPostFrameCallback` on the noKeyOrContext branch below.
    // That's a per-frame spin that starves the RPC responses (like
    // `createTeamLobby`) waiting on the same microtask queue.
    //
    // Bail out silently the moment the captured step is no longer
    // current. The overlay's build path will have already scheduled
    // a fresh measure for the actual current step.
    final currentState = ref.read(tourControllerProvider);
    if (!currentState.active ||
        currentState.stepIndex != _measuredStepIndex ||
        currentState.currentStep?.targetId != step.targetId) {
      AppLogger.tour.i('overlay:measure:staleAbort', fields: {
        'capturedTargetId': step.targetId.name,
        'currentTargetId':
            currentState.currentStep?.targetId.name ?? 'null',
        'measuredStepIndex':
            _measuredStepIndex?.toString() ?? 'null',
        'currentStepIndex': currentState.stepIndex.toString(),
      });
      return;
    }
    if (_scrolling) {
      AppLogger.tour.i('overlay:measure:skipped', fields: {
        'reason': 'alreadyScrolling',
        'targetId': step.targetId.name,
      });
      return;
    }
    AppLogger.tour.i('overlay:measure:start', fields: {
      'targetId': step.targetId.name,
      'sheet': step.sheet?.name ?? 'null',
    });
    final key = ref.read(tourTargetsProvider)[step.targetId];
    final ctx = key?.currentContext;
    if (ctx == null) {
      AppLogger.tour.i('overlay:measure:noKeyOrContext', fields: {
        'targetId': step.targetId.name,
        'keyFound': (key != null).toString(),
        'contextFound': 'false',
        'registrySize':
            ref.read(tourTargetsProvider).length.toString(),
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _measureTarget(step);
      });
      return;
    }
    // Sheet targets get an extra delay so the sheet's slide-up
    // animation settles before we measure. Without this, the first
    // sheet step measures the target at its animating position
    // (typically off-screen) and the cutout is drawn nowhere.
    if (step.sheet != null) {
      AppLogger.tour.i('overlay:measure:sheetDelay', fields: {
        'targetId': step.targetId.name,
        'delayMs': '350',
      });
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) {
        AppLogger.tour.i('overlay:measure:unmountedDuringSheetDelay',
            fields: {'targetId': step.targetId.name});
        return;
      }
    }
    // Re-fetch the target's context after the delay — the widget may
    // have rebuilt during the animation. If it's gone, retry.
    final ctxAfterDelay =
        ref.read(tourTargetsProvider)[step.targetId]?.currentContext;
    if (ctxAfterDelay == null) {
      AppLogger.tour.i('overlay:measure:noContextAfterDelay', fields: {
        'targetId': step.targetId.name,
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _measureTarget(step);
      });
      return;
    }
    // Auto-scroll on every step — even sheet steps. DraggableScroll-
    // ableSheet + ListView is a proper Scrollable; ensureVisible
    // brings the target (e.g. Save Goal at the bottom of the list)
    // into view before we measure its rect. ctxAfterDelay was re-
    // fetched just above from the target's registered GlobalKey —
    // it's current at this point in time, so the lint's warning
    // about crossing async gaps is a false positive here.
    AppLogger.tour.i('overlay:measure:ensureVisible:start', fields: {
      'targetId': step.targetId.name,
    });
    final stopwatch = Stopwatch()..start();
    _scrolling = true;
    try {
      // alignment 0.25 lifts the target to ~25% from the top of the
      // scrollable viewport — well ABOVE the bottom nav bar so sheet
      // targets near the bottom of the list (e.g. Save Goal) come
      // fully into view rather than sitting behind the nav.
      await Scrollable.ensureVisible(
        ctxAfterDelay,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.25,
      );
      AppLogger.tour.i('overlay:measure:ensureVisible:done', fields: {
        'targetId': step.targetId.name,
        'elapsedMs': stopwatch.elapsedMilliseconds.toString(),
      });
    } catch (e) {
      AppLogger.tour.w('overlay:measure:ensureVisible:threw', fields: {
        'targetId': step.targetId.name,
        'err': e.toString(),
      });
    }
    _scrolling = false;
    if (!mounted) {
      AppLogger.tour.i('overlay:measure:unmountedAfterScroll', fields: {
        'targetId': step.targetId.name,
      });
      return;
    }
    // Measure INLINE (no addPostFrameCallback). The 2026-09-22 tour
    // log revealed a 9,692 ms hang between `ensureVisible:done` and
    // `measure:committed` on the step 6 → 7 transition (Start a
    // battle → Pick a format). Root cause: after the sheet was fully
    // mounted and no widget was animating, the app went idle — no
    // frame was scheduled — and the addPostFrameCallback we used to
    // wrap this measurement waited for the next frame, which only
    // fired when the user finally touched the screen. Meanwhile the
    // tour card content had already flipped to "Pick a format" but
    // the card position + spotlight were stuck on the old rect
    // because setState never ran.
    //
    // Scrollable.ensureVisible above already awaited layout of the
    // target ancestor's viewport, so the render object is up to date
    // and `findRenderObject` returns a laid-out box. Measuring here
    // synchronously and setState-ing skips the frame-scheduling
    // dependency entirely.
    //
    // Fallback: if for some odd reason the box isn't sized yet, we
    // request one more measure via a postFrame AND explicitly
    // schedule a frame so the callback isn't left orphaned. Only
    // taken when box.hasSize is false — rare, but guarded.
    final ctxFinal =
        ref.read(tourTargetsProvider)[step.targetId]?.currentContext;
    final box = ctxFinal?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      AppLogger.tour.i('overlay:measure:noBox', fields: {
        'targetId': step.targetId.name,
        'contextAfterScroll': (ctxFinal != null).toString(),
        'boxNull': (box == null).toString(),
        'hasSize': box?.hasSize.toString() ?? 'n/a',
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _measureTarget(step);
      });
      // Force a frame so the postFrame retry isn't orphaned in the
      // idle event loop.
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    final origin = box.localToGlobal(Offset.zero);
    final newRect = origin & box.size;
    AppLogger.tour.i('overlay:measure:committed', fields: {
      'targetId': step.targetId.name,
      'x': newRect.left.toStringAsFixed(1),
      'y': newRect.top.toStringAsFixed(1),
      'w': newRect.width.toStringAsFixed(1),
      'h': newRect.height.toStringAsFixed(1),
      'hadOldRect': (_targetRect != null).toString(),
    });
    // Clear the suspend flag now that we have a real target to
    // spotlight. If we set it during a transition (e.g. confirm-
    // team-battle → team-lobby) it stays true through the loading
    // window and drops back to false the moment the next step's
    // target actually measures — the overlay reappears in place.
    final suspendCtrl = ref.read(tourOverlaySuspendedProvider.notifier);
    if (suspendCtrl.state) {
      AppLogger.tour.i('overlay:suspend:clear',
          fields: {'targetId': step.targetId.name});
      suspendCtrl.state = false;
    }
    setState(() => _targetRect = newRect);
    // Position tween has just begun (TweenAnimationBuilder picks up
    // the new `end` value on next build). Schedule the content swap
    // to fire when the tween settles — user reads OLD copy while the
    // card slides, then NEW copy fades in once it stops. Only fires
    // if the displayed step is actually behind the current step; on
    // the FIRST paint the displayed index is already aligned so this
    // is a no-op.
    // `_measuredStepIndex` is always set BEFORE _measureTarget runs
    // (see the step-change branch in build()), so the fallback here
    // is defence-in-depth against direct call sites — never null in
    // practice.
    final swapTargetIndex = _measuredStepIndex ?? _displayedStepIndex ?? 0;
    if (_displayedStepIndex != swapTargetIndex) {
      _swapTimer?.cancel();
      _swapTimer = Timer(_tweenDuration, () {
        if (!mounted) return;
        AppLogger.tour.i('overlay:contentSwap', fields: {
          'from': (_displayedStepIndex ?? -1).toString(),
          'to': swapTargetIndex.toString(),
        });
        setState(() => _displayedStepIndex = swapTargetIndex);
      });
    }
  }

  /// [contentStep] — the step whose title / description / step counter
  /// the card should paint. During transitions this is the OLD step
  /// while the box is sliding to the new position, then the swap
  /// timer fires and it becomes the NEW step (crossfaded by the
  /// caller's AnimatedSwitcher). Distinct from the callback wiring
  /// (Back / Next / X / isLast) which always uses the LIVE state, so
  /// the user can tap Next mid-transition without the delayed text
  /// affecting what advancing means.
  Widget _card(
    TourStep contentStep,
    TourControllerState state, {
    TooltipNotchSide notchSide = TooltipNotchSide.none,
    double notchFraction = 0.5,
  }) {
    final notifier = ref.read(tourControllerProvider.notifier);
    // Back is hidden at the tour's floor: step 0 for the full tour,
    // OR the scoped-from index for an info-icon replay. Prevents
    // Back from surfacing a step outside the scoped tab's range
    // (2026-09-21 user feedback: Back on Battles-scoped step 6
    // was showing Home step 5 "Save your new goal").
    //
    // Also hidden when the LIVE current step's `hidesBackButton` is
    // set — used by the FIRST team-lobby step (added 2026-09-22) so
    // pressing Back cannot rewind past the "Use entry & open" confirm
    // dialog after the lobby has already been created on the server.
    // Read from the LIVE step (not the transition-displayed one) so
    // Back visibility flips at the same frame as the tour actually
    // lands on the new step — otherwise mid-transition the old
    // step's Back-visible state would linger while the card is
    // already showing the new step's text.
    final floor = state.scopedFromIndex ?? 0;
    final liveStep = state.currentStep;
    final liveHidesBack = liveStep?.hidesBackButton ?? false;
    final hasBack = state.stepIndex > floor && !liveHidesBack;
    // Step counter follows the DISPLAYED step so the number swaps in
    // step with the text ("8 / 20" flips to "9 / 20" at the same
    // frame as the title). Falls back to live index on the very
    // first paint before any swap has been scheduled.
    final displayedIdx = _displayedStepIndex ?? state.stepIndex;
    // A step that offers a permission shows Allow / Not now instead of
    // Next, but only while that capability is actually locked AND only
    // where the lock model is live (iOS today — Android still asks
    // during onboarding, so offering again here would double up).
    final capability = contentStep.permission;
    final offersPermission = capability != null &&
        CapabilityLocks.enabled &&
        ref.watch(capabilityUnlockedProvider(capability)).valueOrNull ==
            false;

    return TourTooltip(
      title: contentStep.title,
      description: contentStep.description,
      stepNumber: displayedIdx + 1,
      totalSteps: kTourSteps.length,
      onClose: notifier.skip,
      onBack: hasBack ? notifier.back : null,
      onNext: notifier.next,
      onAllow: offersPermission
          ? () => _resolveStepPermission(capability)
          : null,
      allowBusy: _allowBusy,
      isLast: state.stepIndex >= kTourSteps.length - 1,
      notchSide: notchSide,
      notchFraction: notchFraction,
    );
  }

  Widget _positionedCard(BuildContext context, TourStep step, Rect rect,
      TourControllerState state) {
    final screen = MediaQuery.sizeOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    const gap = 14.0;
    const sideMargin = 20.0;
    const approxCardHeight = 170.0;

    // Notch fraction — priority order:
    //   1. Step 6 (Pick a format): DYNAMIC — points at 1v1 / Multi /
    //      Team column based on tourBattleFormatChoiceProvider so
    //      when the user selects a different tile the notch follows.
    //      Defaults to 1v1 (left column) when nothing's picked.
    //   2. Step's notchFractionOverride (fixed, e.g. streak flame).
    //   3. Auto-compute from target rect's centre X.
    final cardLeft = sideMargin;
    final cardRight = screen.width - sideMargin;
    final cardWidth = cardRight - cardLeft;
    final double notchFraction;
    if (step.targetId == TourTargetId.battleSelect1v1Tile) {
      // 3-column tile row inside the target: 1v1 (left third), Multi
      // (middle), Team (right). Map selected format → notch fraction.
      final choice = ref.watch(tourBattleFormatChoiceProvider);
      final tileCenterX = switch (choice) {
        1 => rect.left + rect.width * 0.5,   // Multi
        2 => rect.left + rect.width * 0.83,  // Team (right)
        _ => rect.left + rect.width * 0.17,  // 1v1 default (left)
      };
      final rawFraction = (tileCenterX - cardLeft) / cardWidth;
      notchFraction = rawFraction.clamp(0.06, 0.94);
    } else if (step.notchFractionOverride != null) {
      notchFraction = step.notchFractionOverride!.clamp(0.06, 0.94);
    } else {
      final targetCenterX = rect.center.dx;
      final rawFraction = (targetCenterX - cardLeft) / cardWidth;
      notchFraction = rawFraction.clamp(0.06, 0.94);
    }

    // Dynamic positioning for ALL steps — including interactive
    // ones. Card sits directly above or below the target, whichever
    // side has more room. Previously interactive steps were docked
    // at the top of the screen (out of the way of sheet controls),
    // but the user wanted the card to sit JUST ABOVE the highlighted
    // target so the visual link is direct. Since the AbsorbPointer
    // is already skipped on interactive steps, taps outside the
    // card still reach the sheet buttons.
    // Effective gap adds the step's own offset so the card can sit
    // further from the target — useful when the target rect wraps
    // only a small icon inside a wider widget (e.g. flame inside
    // the streak strip: 90 dp offset pushes card below the whole
    // strip so the "N Days" caption isn't hidden by the card).
    final effectiveGap = gap + step.cardOffsetPastTarget;
    final spaceAbove =
        rect.top - viewPadding.top - approxCardHeight - effectiveGap;
    final spaceBelow = screen.height -
        rect.bottom -
        viewPadding.bottom -
        approxCardHeight -
        effectiveGap;
    final placeBelow = spaceBelow >= 0 && spaceBelow >= spaceAbove;

    // Content lags position by [_tweenDuration]; use the delayed step
    // for what the card SAYS, keep the notch pointing at the LIVE
    // target position so the arrow tracks the sliding spotlight.
    final contentStep = _displayedStepIndex != null
        ? kTourSteps[_displayedStepIndex!]
        : step;
    // AnimatedSwitcher crossfades the card content on swap. Keyed by
    // displayed step index so a step change alone doesn't trip it —
    // only the delayed swap does.
    Widget wrap(Widget card) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: child,
          ),
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.center,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          child: KeyedSubtree(
            key: ValueKey<int>(_displayedStepIndex ?? -1),
            child: card,
          ),
        );

    if (placeBelow) {
      // Symmetrical clamp on below-placement so the card never
      // extends past the bottom safe area either (same rationale as
      // the above-placement clamp below).
      final rawTop = rect.bottom + effectiveGap;
      final maxTop = screen.height -
          viewPadding.bottom -
          approxCardHeight -
          8;
      final clampedTop = rawTop > maxTop ? maxTop : rawTop;
      return Positioned(
        top: clampedTop,
        left: sideMargin,
        right: sideMargin,
        child: wrap(_card(
          contentStep,
          state,
          notchSide: TooltipNotchSide.top,
          notchFraction: notchFraction,
        )),
      );
    }
    // Above placement. 2026-09-20 fix: when the target is very
    // large (e.g. the entire AddFriendsSheet, ~85 % of screen
    // height), the raw `bottom = screen.height - rect.top +
    // effectiveGap` positions the card so its TOP goes negative —
    // the card's title clips into the status bar. Clamp the top
    // edge to sit just below the safe-area top with an 8 dp gutter.
    // The notch stays TooltipNotchSide.bottom (pointing DOWN into
    // the target), and its horizontal fraction still points at the
    // target's centre — so the visual "message about this thing"
    // link is preserved; the card just no longer floats off-screen.
    final rawBottom = screen.height - rect.top + effectiveGap;
    final rawTop = screen.height - rawBottom - approxCardHeight;
    final safeTop = viewPadding.top + 8;
    if (rawTop < safeTop) {
      return Positioned(
        top: safeTop,
        left: sideMargin,
        right: sideMargin,
        child: wrap(_card(
          contentStep,
          state,
          notchSide: TooltipNotchSide.bottom,
          notchFraction: notchFraction,
        )),
      );
    }
    return Positioned(
      bottom: rawBottom,
      left: sideMargin,
      right: sideMargin,
      child: wrap(_card(
        contentStep,
        state,
        notchSide: TooltipNotchSide.bottom,
        notchFraction: notchFraction,
      )),
    );
  }

  Widget _centeredCard(BuildContext context, TourStep step,
      TourControllerState state) {
    return Positioned.fill(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Align(
            alignment: Alignment.center,
            child: _card(step, state),
          ),
        ),
      ),
    );
  }
}

/// PanGestureRecognizer subclass with an aggressive 3-dp acceptance
/// threshold. Registered inside [_OnboardingTourOverlayState]'s
/// target-rect drag-blocker so we DEFINITIVELY beat any underlying
/// Scrollable's VerticalDrag / HorizontalDrag / Pan recognizers in
/// the gesture arena. Those default to kTouchSlop (~18 dp); ours
/// declares acceptance almost the instant the pointer moves at all,
/// leaving the underlying Scrollable's recognizer to lose.
///
/// The 3-dp floor is high enough that a normal tap's tiny drift
/// (typically 0-2 dp) never wakes this recognizer, so tap events
/// keep falling through the translucent RawGestureDetector to the
/// underlying widget. Only movements > 3 dp (real drags) trigger us.
class _EarlyPanRecognizer extends PanGestureRecognizer {
  double _accumMoved = 0.0;

  static const double _threshold = 3.0;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _accumMoved += event.delta.distance;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
      PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) {
    return _accumMoved > _threshold;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _accumMoved = 0.0;
    super.didStopTrackingLastPointer(pointer);
  }
}
