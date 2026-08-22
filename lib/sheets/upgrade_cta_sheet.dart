import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/colors.dart';
import '../models/subscription_model.dart';
import '../providers/auth_provider.dart';
import '../providers/subscription_provider.dart';

/// Full subscription-plans sheet. Opens when the user taps a
/// disabled Create/Join button, the "Remaining X entries" usage
/// pill on Battles, or any explicit "Upgrade" affordance.
///
/// Shows three plan cards (Free / Pro / Family) side-by-side with
/// prices, feature bullets, and an "Upgrade" button that opens the
/// hosted Razorpay checkout in the OS browser. The mobile app never
/// touches Razorpay directly — it hands off with the current user's
/// uid so the webhook can attribute the payment.
///
/// Monthly / Yearly toggle changes the price on the plan cards AND
/// the query param sent to the checkout URL.
Future<void> showUpgradeCtaSheet(
  BuildContext context, {
  /// Pre-highlight this tier (typically comes from
  /// [LimitDecision.upgradeTo] — the tier the user would need to
  /// unblock whatever they just tried).
  SubscriptionTier? focusTier,
  /// Contextual upsell headline shown above the plan cards, replacing
  /// the generic "Upgrade your plan" header. Pass this when the sheet
  /// is opened as a Pro-gate for a specific feature (e.g. direct 1-on-1
  /// battle invites), so the user immediately sees WHY they're here.
  /// [contextDescription] is the short second line under it.
  String? contextTitle,
  String? contextDescription,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    builder: (_) => _UpgradeCtaSheet(
      focusTier: focusTier,
      contextTitle: contextTitle,
      contextDescription: contextDescription,
    ),
  );
}

class _UpgradeCtaSheet extends ConsumerStatefulWidget {
  final SubscriptionTier? focusTier;
  final String? contextTitle;
  final String? contextDescription;
  const _UpgradeCtaSheet({
    this.focusTier,
    this.contextTitle,
    this.contextDescription,
  });

  @override
  ConsumerState<_UpgradeCtaSheet> createState() => _UpgradeCtaSheetState();
}

class _UpgradeCtaSheetState extends ConsumerState<_UpgradeCtaSheet> {
  bool _yearly = true; // default to yearly — bigger effective saving

  Future<void> _launchCheckout(SubscriptionTier tier) async {
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null || uid.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please sign in to subscribe.')),
        );
      }
      return;
    }
    final url = Uri.parse(
      '$kSubscriptionUpgradeUrlBase'
      '?uid=$uid'
      '&plan=${tier.wire}'
      '&period=${_yearly ? 'yearly' : 'monthly'}',
    );
    try {
      final ok =
          await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open checkout.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open checkout.')),
        );
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = ref.watch(subscriptionProvider);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        // Theme-aware sheet background — dark in dark mode, near-
        // white in light mode. All child colors also read from the
        // colorScheme so the sheet adapts across the whole tree.
        final scheme = theme.colorScheme;
        return Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(24),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.only(top: 12, bottom: 32),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (widget.contextTitle != null) ...[
                // Contextual header — sheet was opened as a Pro-gate
                // for a specific feature. Show what they're unlocking
                // instead of the generic "Upgrade your plan" copy.
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline,
                          color: scheme.primary, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.contextTitle!,
                              style:
                                  theme.textTheme.titleMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if ((widget.contextDescription ?? '')
                                .isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                widget.contextDescription!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Text(
                  'Upgrade your plan',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sub.tier == SubscriptionTier.basic
                      ? 'You\'re on Free. Unlock more battles + rewards.'
                      : 'You\'re on ${sub.tier.displayName}. Switch anytime.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _BillingToggle(
                yearly: _yearly,
                onChanged: (v) => setState(() => _yearly = v),
              ),
              const SizedBox(height: 20),
              _PlanCard(
                tier: SubscriptionTier.basic,
                currentTier: sub.tier,
                focused: widget.focusTier == SubscriptionTier.basic,
                yearly: _yearly,
                onUpgrade: null, // Free has no upgrade action
              ),
              const SizedBox(height: 12),
              _PlanCard(
                tier: SubscriptionTier.pro,
                currentTier: sub.tier,
                focused: widget.focusTier == SubscriptionTier.pro,
                yearly: _yearly,
                onUpgrade: () => _launchCheckout(SubscriptionTier.pro),
              ),
              const SizedBox(height: 12),
              _PlanCard(
                tier: SubscriptionTier.max,
                currentTier: sub.tier,
                focused: widget.focusTier == SubscriptionTier.max,
                yearly: _yearly,
                onUpgrade: () =>
                    _launchCheckout(SubscriptionTier.max),
              ),
              // "Manage Family" — only for owners. Members don't have
              // management privileges (only the owner does).
              if (sub.isFamilyOwner) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      context.push('/family');
                    },
                    icon: const Icon(Icons.family_restroom),
                    label: const Text('Manage Family'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.tertiary,
                      side: BorderSide(
                          color: AppColors.tertiary
                              .withValues(alpha: 0.5)),
                      padding:
                          const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Payments are processed on our website via Razorpay. '
                'The Upgrade button opens your browser.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BillingToggle extends StatelessWidget {
  final bool yearly;
  final ValueChanged<bool> onChanged;
  const _BillingToggle({required this.yearly, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: _TogglePill(
            selected: !yearly,
            onTap: () => onChanged(false),
            label: 'Monthly',
          )),
          Expanded(child: _TogglePill(
            selected: yearly,
            onTap: () => onChanged(true),
            label: 'Yearly',
            badge: 'Save 16%',
          )),
        ],
      ),
    );
  }
}

class _TogglePill extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final String label;
  final String? badge;
  const _TogglePill({
    required this.selected,
    required this.onTap,
    required this.label,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                // Selected pill has a purple bg → white text reads
                // correctly in both light & dark modes.
                // Unselected sits on the sheet bg → theme-aware muted
                // color adapts.
                color: selected
                    ? Colors.white
                    : scheme.onSurface.withValues(alpha: 0.7),
                fontFamily: 'Manrope',
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.2)
                      : AppColors.tertiary.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge!,
                  style: TextStyle(
                    color: selected ? Colors.white : AppColors.tertiary,
                    fontFamily: 'Manrope',
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final SubscriptionTier tier;
  final SubscriptionTier currentTier;
  final bool focused;
  final bool yearly;
  final VoidCallback? onUpgrade;

  const _PlanCard({
    required this.tier,
    required this.currentTier,
    required this.focused,
    required this.yearly,
    this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final limits = SubscriptionLimits.forTier(tier);
    final pricing = SubscriptionPricing.forTier(tier);
    final isCurrent = currentTier == tier;

    final accent = tier == SubscriptionTier.max
        ? AppColors.tertiary
        : (tier == SubscriptionTier.pro
            ? AppColors.primary
            : scheme.onSurface.withValues(alpha: 0.4));

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: focused
            ? accent.withValues(alpha: 0.12)
            : scheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: focused
              ? accent
              : scheme.onSurface.withValues(alpha: 0.1),
          width: focused ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                // Max was previously `family_restroom` back when the
                // top tier was "Family". After the rename (migration
                // 0051) it's "Max" — a personal premium tier — so a
                // diamond reads correctly without implying multi-seat.
                tier == SubscriptionTier.max
                    ? Icons.diamond_outlined
                    : (tier == SubscriptionTier.pro
                        ? Icons.workspace_premium
                        : Icons.circle_outlined),
                color: accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                // Clarify Basic = $0 in the heading. Every other tier
                // already carries a price row underneath, so it only
                // needs the "(Free)" qualifier here.
                tier == SubscriptionTier.basic
                    ? '${tier.displayName} (Free)'
                    : tier.displayName,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'CURRENT',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontFamily: 'Manrope',
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Price line — always framed per month, even on Yearly,
          // so the user can compare apples-to-apples. The small
          // amber line below clarifies the actual charge amount +
          // billing cadence for the yearly view.
          if (pricing != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '₹${yearly ? pricing.yearlyMonthEquivalent : pricing.monthlyRupees}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '/ month',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (yearly) ...[
              const SizedBox(height: 4),
              Text(
                'billed annually · ₹${NumberFormat.decimalPattern("en_IN").format(pricing.yearlyRupees)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.tertiary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ] else
            Text(
              // Basic replaced Free in migration 0051. The plan name
              // sits in the heading above; this slot occupies the
              // price-line position so it just reads "Free" to make
              // the $0 story unambiguous.
              'Free',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
          const SizedBox(height: 14),
          _bullet(
            context,
            '${limits.monthlyBattleEntries} battle entries / month',
          ),
          _bullet(
              context, '${limits.monthlyCreates} battles you can create'),
          _bullet(
            context,
            limits.unlimitedPublic
                ? 'Unlimited public joins'
                : '${limits.monthlyJoinPublic} public joins',
          ),
          _bullet(context, '${limits.monthlyJoinPrivate} private joins'),
          _bullet(
            context,
            '${limits.perfectMonthXpBonus} XP monthly streak bonus',
          ),
          _bullet(
            context,
            limits.battleHistoryDays >= 180
                ? '6 months battle history'
                : '${limits.battleHistoryDays} days battle history',
          ),
          if (tier == SubscriptionTier.max)
            _bullet(context, 'Up to 4 accounts on one plan'),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: isCurrent ? null : onUpgrade,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    scheme.onSurface.withValues(alpha: 0.08),
                disabledForegroundColor:
                    scheme.onSurface.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                isCurrent
                    ? 'Current plan'
                    : (tier == SubscriptionTier.basic
                        ? 'Default'
                        : 'Upgrade to ${tier.displayName}'),
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bullet(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_rounded,
              size: 15,
              color: scheme.onSurface.withValues(alpha: 0.75)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onSurface,
                fontFamily: 'Manrope',
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
