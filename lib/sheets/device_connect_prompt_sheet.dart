import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';
import '../services/native_step_service.dart';
import '../utils/app_logger.dart';
import '../widgets/bottom_sheet_handle.dart';

/// One-shot post-onboarding sheet that nudges the user to connect a
/// smartwatch / fitness band / Health Connect–linked app so steps from
/// non-phone workouts also count toward battles and streaks.
///
/// **Discoverability, not a requirement.** The sheet fires ONCE PER
/// USER on this device (Hive-flagged per uid — see [_shownKeyFor]),
/// after the mandatory permissions primer + first-run health-setup
/// wizard have both closed and the whole new-user signup flow has
/// finished. Skip is a first-class action — swipe-to-dismiss,
/// tap-outside, or the explicit "Skip for now" text button all mark
/// the sheet as seen and it never re-fires automatically. Users who
/// dismissed can always re-open it from Settings → Step tracking →
/// Connect a device.
///
/// Trigger predicate (all must hold — enforced by the caller,
/// currently `_HomeScreenState._maybeShowDeviceConnectPrompt`):
///   • `hasCompletedOnboarding == true`
///   • `PermissionGate.primerOpen == false`     (Almost Ready dismissed)
///   • `HealthSetupScreen.shouldShowFirstRunWizard() == false`
///   • `NoSourceGate.blockerOpen == false`      (no hard blocker up)
///   • no XP celebration on screen              (signup bonus settled)
///   • new-user tour neither running nor owed   (signup flow over)
///   • `shouldShow() == true`                   (not seen by this uid)
///
/// The prompt is deliberately OPTIONAL. If StepBattle can't count steps
/// AT ALL (phone pedometer denied + no HC feeder + no GFit), the
/// hard-blocking [NoSourceGate] fires instead — this sheet is for the
/// happy path where a source exists but the user could benefit from
/// adding another.
class DeviceConnectPromptSheet {
  DeviceConnectPromptSheet._();

  /// Legacy install-wide Hive key (pre-2026-11-02): a single unix-ms
  /// timestamp with no user attached. Kept only so [shouldShow] can
  /// migrate it — never written again. See [_shownKeyFor].
  static const String _legacyShownKey = 'device_connect_prompt_shown_at_ms';

  /// Per-user Hive key: unix-ms timestamp this uid dismissed the
  /// prompt. Any non-null value means "this user has seen it — don't
  /// auto-fire for them again".
  ///
  /// **Why per-user (2026-11-02).** This used to be one install-wide
  /// key, which made the prompt once-per-install. That was wrong once
  /// the sheet became the tail of the new-user signup flow: the tour
  /// it now waits behind is keyed per-user (`profiles.has_completed_tour`),
  /// so on a device where anyone had already dismissed the prompt, a
  /// newly-created account ran the whole tour and then got nothing.
  /// Testers creating successive accounts saw it exactly once, ever,
  /// and so would a real user handing their phone to a family member.
  ///
  /// Still Hive-local rather than a server column: the nudge is about
  /// the DEVICE's capabilities ("connect the watch you're wearing"),
  /// so it's correct for it to re-ask the same user on a new phone.
  /// That's the opposite of the tour, which is about the app and
  /// rightly never repeats.
  static String _shownKeyFor(String uid) => '$_legacyShownKey::$uid';

  /// Signed-in uid, or null if there's no session. Read live rather
  /// than passed in so the two call sites below stay parameterless.
  static String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  /// Whether the sheet should auto-fire on the next Home mount.
  /// Returns false once THIS user has dismissed it via any path.
  static bool shouldShow() {
    final uid = _uid;
    // No session → nothing to attribute a dismissal to. Defer; the
    // caller re-checks on the next Home mount.
    if (uid == null) return false;
    try {
      final box = Hive.box(NativeStepService.boxName);
      if (box.get(_shownKeyFor(uid)) != null) return false;

      // One-time migration off the install-wide key. Whoever is signed
      // in the first time we look after the upgrade inherits it, which
      // keeps the ~140 existing users who already dismissed the prompt
      // from being re-prompted. Every OTHER uid on the same install
      // starts clean — the whole point of the rekey.
      //
      // The write is a side effect inside a predicate, which is worth
      // being explicit about: Hive's `put` updates the in-memory map
      // synchronously and flushes to disk after, so the very next
      // `shouldShow()` in this session already reads the new value.
      // Unawaited for that reason — there is nothing to wait for.
      final legacy = box.get(_legacyShownKey);
      if (legacy != null) {
        AppLogger.permission.i('deviceConnectPrompt:legacyKeyClaimed',
            fields: {'uid': uid});
        unawaited(box.put(_shownKeyFor(uid), legacy));
        unawaited(box.delete(_legacyShownKey));
        return false;
      }
      return true;
    } catch (_) {
      // Defensive — if Hive isn't ready for some reason, don't crash;
      // just skip the prompt. It'll show on a later mount.
      return false;
    }
  }

  /// Marks the sheet as shown for the current user. Fires from every
  /// dismissal path so a swipe-down + a Skip tap + a Set-up tap all
  /// have the same "don't re-fire" semantic.
  static Future<void> markShown() async {
    final uid = _uid;
    if (uid == null) {
      // Can't attribute the dismissal, so don't record one — the
      // prompt re-fires on a later mount rather than being silently
      // burned for whoever signs in next.
      AppLogger.permission.w('deviceConnectPrompt:mark_skipped_no_uid');
      return;
    }
    try {
      final box = Hive.box(NativeStepService.boxName);
      await box.put(
          _shownKeyFor(uid), DateTime.now().millisecondsSinceEpoch);
      AppLogger.permission
          .i('deviceConnectPrompt:marked_shown', fields: {'uid': uid});
    } catch (e) {
      AppLogger.permission.w('deviceConnectPrompt:mark_failed',
          fields: {'err': e.toString()});
    }
  }

  /// Imperative opener. Callable both from the auto-fire path on Home
  /// and from the Settings → Connect a device row (which passes
  /// `manual: true` so the sheet's own dismiss handler doesn't
  /// re-write the Hive flag — a manual re-visit shouldn't reset the
  /// timestamp because the timestamp is already set from the first
  /// auto-fire).
  static Future<void> show(BuildContext context, {bool manual = false}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      builder: (_) => _DeviceConnectPromptSheetBody(manual: manual),
    );
  }
}

class _DeviceConnectPromptSheetBody extends StatelessWidget {
  final bool manual;
  const _DeviceConnectPromptSheetBody({required this.manual});

  Future<void> _dismiss(BuildContext context) async {
    // Auto-fire path marks the Hive flag; manual re-visit doesn't need
    // to because the flag is already set (set on first auto-fire OR
    // the user wouldn't have needed to open it manually to see the
    // Settings row exists).
    if (!manual) {
      await DeviceConnectPromptSheet.markShown();
    }
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _setUp(BuildContext context) async {
    if (!manual) {
      await DeviceConnectPromptSheet.markShown();
    }
    if (!context.mounted) return;
    Navigator.of(context).pop();
    context.push('/profile/health-setup');
  }

  /// Brand chip tap → dismiss + route to that brand's mini-setup
  /// screen. Same "mark shown" semantics as [_setUp].
  Future<void> _openBrand(BuildContext context, String brandId) async {
    if (!manual) {
      await DeviceConnectPromptSheet.markShown();
    }
    if (!context.mounted) return;
    Navigator.of(context).pop();
    context.push('/profile/health-setup/brand/$brandId');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopScope(
      // Back-button pop should mark shown too — same UX as swipe-down.
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !manual) {
          // Fire-and-forget; sheet is already popping. The Hive write
          // is fast (SharedPreferences underneath).
          DeviceConnectPromptSheet.markShown();
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BottomSheetHandle(),
                // Hero icon — smartwatch glyph on a soft violet disc.
                // Matches the visual language of the streak sheet's
                // hero + the No-Source dialog's warning disc.
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.watch,
                    color: AppColors.primary,
                    size: 34,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Sync from a device',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Got a smartwatch or fitness band? Connect it so those '
                  'workouts count toward your steps.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                // Generic 3-item visual — smartwatch, fitness band,
                // Health Connect apps. Avoids brand-specific logos
                // (which would need SVG assets + a maintenance
                // relationship with each brand) while still conveying
                // "we support most sources".
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: scheme.onSurface.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    children: [
                      _DeviceRow(
                        icon: Icons.watch,
                        label: 'Smartwatch',
                        subtitle: 'Wear OS · Galaxy Watch · Pixel Watch · Apple Watch',
                      ),
                      _Divider(scheme: scheme),
                      _DeviceRow(
                        icon: Icons.fitness_center,
                        label: 'Fitness band',
                        subtitle: 'Fitbit · Mi Band · Garmin · boAt',
                      ),
                      _Divider(scheme: scheme),
                      _DeviceRow(
                        icon: Icons.favorite,
                        label: 'Health Connect apps',
                        subtitle: 'Samsung Health · Google Fit · MyFitnessPal',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // Brand chip picker — one tap → mini setup guide for
                // that brand. Scrollable so the chip row survives a
                // narrow phone or a large font scale.
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'PICK YOUR BRAND',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.zero,
                    children: [
                      _BrandChip(
                        label: 'Samsung',
                        onTap: () => _openBrand(context, 'samsung'),
                      ),
                      _BrandChip(
                        label: 'Fitbit',
                        onTap: () => _openBrand(context, 'fitbit'),
                      ),
                      _BrandChip(
                        label: 'boAt',
                        onTap: () => _openBrand(context, 'boat'),
                      ),
                      _BrandChip(
                        label: 'Xiaomi / Mi',
                        onTap: () => _openBrand(context, 'xiaomi'),
                      ),
                      _BrandChip(
                        label: 'Wear OS',
                        onTap: () => _openBrand(context, 'wearos'),
                      ),
                      _BrandChip(
                        label: 'Other',
                        onTap: () => _openBrand(context, 'other'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Small footnote — sets expectations honestly. Not
                // every device auto-syncs; the setup screen tells the
                // user how to enable it per brand.
                Text(
                  'Not sure which one? Tap Set up device for the full '
                  'guide.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                // Primary CTA — routes to the existing health-setup
                // screen. That screen already knows how to guide the
                // user per device type.
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => _setUp(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Set up device',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.arrow_forward_rounded,
                            size: 20, color: Colors.white),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Skip is a first-class action — same visual weight
                // range as a normal text button, muted so it doesn't
                // pull focus from the primary CTA but obvious enough
                // that no user feels trapped in the sheet.
                TextButton(
                  onPressed: () => _dismiss(context),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(
                    manual ? 'Close' : 'Skip for now',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  const _DeviceRow({
    required this.icon,
    required this.label,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final ColorScheme scheme;
  const _Divider({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: scheme.onSurface.withValues(alpha: 0.06),
    );
  }
}

/// Brand chip for the picker row. Slim violet-outlined pill with a
/// centred label; on tap, the caller dismisses the sheet and routes
/// to the matching brand-setup screen.
class _BrandChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _BrandChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(100),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(100),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.4),
              ),
              color: AppColors.primary.withValues(alpha: 0.06),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
