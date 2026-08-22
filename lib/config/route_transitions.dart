import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'motion.dart';

/// Named transition helpers for GoRouter routes. Every `builder:` slot
/// in `routes.dart` that used to hand GoRouter a raw widget now hands
/// it a [CustomTransitionPage] built via one of these — giving the app
/// a coherent motion identity instead of the default Android
/// slide-in-from-right on every push.
///
/// Which one to use where:
///
///   • [fadeThroughPage]      — peer-level pushes within a tab, or any
///                              time the destination is conceptually
///                              a sibling of the origin (not deeper in
///                              the hierarchy). Feels like a swap.
///
///   • [sharedAxisYPage]      — drill-downs (settings → nested prefs,
///                              profile → step sources, battle card
///                              → battle status). Origin slides up
///                              and out, destination slides up and
///                              in. Reads as "deeper".
///
///   • [scaleFadePage]        — full-screen destinations that cover
///                              the shell (`/battle-ground`, `/team-
///                              lobby`, `/family`, `/battle-status`).
///                              Slight scale + fade signals "this is
///                              its own world".
///
/// Every transition uses `Motion.d.base` and `Motion.curves.standard`
/// / `Motion.curves.decel` so all page transitions across the app
/// feel like they came from the same design system. Reduced-motion
/// users get `Duration.zero` via [Motion.adaptDuration] which
/// collapses the transition to an instant swap without breaking the
/// navigation.
///
/// Compositor-only: FadeTransition, SlideTransition, ScaleTransition
/// all operate on the compositor layer — no layout re-flow, no paint
/// invalidation of the underlying tree. Safe for smooth scrolling.
class RouteTransitions {
  const RouteTransitions._();

  /// Fade-through: origin fades out to a scrim, destination fades in.
  /// Cheapest visual, safest for high-frequency navigation.
  static CustomTransitionPage<T> fadeThroughPage<T>({
    required LocalKey? key,
    required Widget child,
    Object? arguments,
    String? restorationId,
    String? name,
  }) {
    return CustomTransitionPage<T>(
      key: key,
      child: child,
      arguments: arguments,
      restorationId: restorationId,
      name: name,
      transitionDuration: Motion.d.base,
      reverseTransitionDuration: Motion.d.base,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final effective = Motion.adaptDuration(context, Motion.d.base);
        if (effective == Duration.zero) return child;
        final fade = CurvedAnimation(
          parent: animation,
          curve: Motion.curves.standard,
          reverseCurve: Motion.curves.decel,
        );
        return FadeTransition(opacity: fade, child: child);
      },
    );
  }

  /// Shared-axis Y: slight upward slide (28dp) + fade. Use for drill-
  /// downs so the destination reads as one step "deeper" than the
  /// origin. Small distance keeps it snappy — a full-screen slide
  /// would feel slow for the base duration.
  static CustomTransitionPage<T> sharedAxisYPage<T>({
    required LocalKey? key,
    required Widget child,
    Object? arguments,
    String? restorationId,
    String? name,
  }) {
    return CustomTransitionPage<T>(
      key: key,
      child: child,
      arguments: arguments,
      restorationId: restorationId,
      name: name,
      transitionDuration: Motion.d.base,
      reverseTransitionDuration: Motion.d.base,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final effective = Motion.adaptDuration(context, Motion.d.base);
        if (effective == Duration.zero) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Motion.curves.emphasized,
          reverseCurve: Motion.curves.decel,
        );
        // Enter: slide up 28dp and fade in. Reverse: slide back down
        // and fade out. Compositor-layer transforms only.
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.035),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  /// Scale-fade: destination scales from 0.96 → 1.0 with a fade. Use
  /// for full-screen routes that cover the shell — Battle Ground,
  /// Team Lobby, Battle Status. The small scale-up sells the "own
  /// world" feel without being showy.
  static CustomTransitionPage<T> scaleFadePage<T>({
    required LocalKey? key,
    required Widget child,
    Object? arguments,
    String? restorationId,
    String? name,
  }) {
    return CustomTransitionPage<T>(
      key: key,
      child: child,
      arguments: arguments,
      restorationId: restorationId,
      name: name,
      transitionDuration: Motion.d.slow,
      reverseTransitionDuration: Motion.d.base,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final effective = Motion.adaptDuration(context, Motion.d.slow);
        if (effective == Duration.zero) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Motion.curves.emphasized,
          reverseCurve: Motion.curves.decel,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}
