import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/colors.dart';
import '../../../models/subscription_model.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/family_provider.dart';
import '../../../providers/subscription_provider.dart';
import '../../../sheets/upgrade_cta_sheet.dart';
import '../../../widgets/glass_card.dart';

/// Card on the Profile screen showing the user's current subscription
/// state + the action appropriate for their role:
///
///   * **Free**   → "Upgrade" opens [showUpgradeCtaSheet].
///   * **Pro**    → "Manage" opens the CTA sheet (which shows Current +
///                  the switch-plan / upgrade-to-Family options).
///   * **Family owner**  → "Manage Family" jumps to `/family`.
///   * **Family member** → "Leave Family" fires the confirm dialog
///                         → `familyServiceProvider.leaveFamily()`.
class SubscriptionSection extends ConsumerStatefulWidget {
  const SubscriptionSection({super.key});

  @override
  ConsumerState<SubscriptionSection> createState() =>
      _SubscriptionSectionState();
}

class _SubscriptionSectionState
    extends ConsumerState<SubscriptionSection> {
  String? _familyOwnerDisplay;

  @override
  void initState() {
    super.initState();
    // Load the owner's display name once the tree has settled — only
    // relevant if the current user is a family MEMBER.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadOwnerName());
  }

  Future<void> _loadOwnerName() async {
    final sub = ref.read(subscriptionProvider);
    if (!sub.isFamilyMember) return;
    try {
      final row = await Supabase.instance.client
          .from('profiles_public')
          .select('display_name, preferred_name')
          .eq('id', sub.familyOwnerId!)
          .maybeSingle();
      final name = (row?['preferred_name'] as String?) ??
          (row?['display_name'] as String?);
      if (mounted) setState(() => _familyOwnerDisplay = name);
    } catch (_) {}
  }

  Future<void> _confirmLeaveFamily() async {
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerLow,
        title: const Text('Leave family plan?'),
        content: const Text(
            'You\'ll be reverted to the Free plan immediately. The owner can re-invite you later.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Stay')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(familyServiceProvider).leaveFamily(memberId: uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You\'ve left the family plan.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Failed: $e'),
            backgroundColor: AppColors.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = ref.watch(subscriptionProvider);
    final members = ref.watch(familyMembersProvider);

    final accent = sub.tier == SubscriptionTier.max
        ? AppColors.tertiary
        : (sub.tier == SubscriptionTier.pro
            ? AppColors.primary
            : AppColors.onSurfaceVariant);

    final icon = sub.tier == SubscriptionTier.max
        ? Icons.family_restroom
        : (sub.tier == SubscriptionTier.pro
            ? Icons.workspace_premium
            : Icons.workspace_premium_outlined);

    return GlassCard(
      padding: const EdgeInsets.all(16),
      border: Border.all(color: accent.withValues(alpha: 0.35)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          sub.tier.displayName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (sub.isFamilyOwner) ...[
                          const SizedBox(width: 6),
                          _RolePill(label: 'OWNER', color: accent),
                        ] else if (sub.isFamilyMember) ...[
                          const SizedBox(width: 6),
                          _RolePill(label: 'MEMBER', color: accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitleFor(sub, members.length),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (sub.isFamilyMember) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color:
                        AppColors.outlineVariant.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.person_outline,
                      size: 14, color: AppColors.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _familyOwnerDisplay == null
                          ? 'Loading owner…'
                          : 'You\'re on $_familyOwnerDisplay\'s plan',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          _actionButton(context, sub),
        ],
      ),
    );
  }

  String _subtitleFor(SubscriptionState sub, int memberCount) {
    if (sub.tier == SubscriptionTier.basic) {
      return 'Upgrade for more battles + rewards.';
    }
    final parts = <String>[];
    if (sub.isFamilyOwner) {
      parts.add('${1 + memberCount}/4 seats used');
    }
    final expiry = sub.expiresAt;
    if (expiry != null) {
      final fmt = DateFormat('d MMM y');
      final days = sub.daysUntilExpiry ?? 0;
      parts.add(days < 0
          ? 'Expired ${fmt.format(expiry)}'
          : 'Renews ${fmt.format(expiry)}');
    }
    if (sub.subscriptionBillingPeriodLabel != null) {
      parts.add(sub.subscriptionBillingPeriodLabel!);
    }
    return parts.join(' · ');
  }

  Widget _actionButton(BuildContext context, SubscriptionState sub) {
    if (sub.isFamilyOwner) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => context.push('/family'),
          icon: const Icon(Icons.family_restroom, size: 18),
          label: const Text('Manage Family'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.tertiary,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      );
    }
    if (sub.isFamilyMember) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _confirmLeaveFamily,
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('Leave family plan'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            side: BorderSide(
                color: AppColors.error.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      );
    }
    // Free or Pro (non-family): show CTA sheet.
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () => showUpgradeCtaSheet(context),
        icon: Icon(
          sub.tier == SubscriptionTier.basic
              ? Icons.rocket_launch
              : Icons.tune,
          size: 18,
        ),
        label: Text(sub.tier == SubscriptionTier.basic
            ? 'Upgrade plan'
            : 'Manage subscription'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}

/// "OWNER" / "MEMBER" mini-pill shown next to the tier name.
class _RolePill extends StatelessWidget {
  final String label;
  final Color color;
  const _RolePill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontFamily: 'Manrope',
          fontSize: 9,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Extension exposing the billing-period label — kept out of the
/// model file because it's a UI concern (title case + human words).
extension _BillingPeriodLabel on SubscriptionState {
  String? get subscriptionBillingPeriodLabel {
    switch (billingPeriod) {
      case 'monthly':
        return 'Monthly';
      case 'yearly':
        return 'Yearly';
      default:
        return null;
    }
  }
}
