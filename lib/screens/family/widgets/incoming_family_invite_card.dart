import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/colors.dart';
import '../../../models/family_membership_model.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/family_provider.dart';
import '../../../providers/subscription_provider.dart';
import '../../../widgets/avatar_circle.dart';
import '../../../widgets/glass_card.dart';

/// Card rendered on the Battles tab when the current user has one or
/// more pending Family Pass invites. Accept → joins the owner's
/// family and inherits Family-tier entitlements; Decline → dismisses
/// the invite (owner can re-invite later after v2 deletes the row).
class IncomingFamilyInviteSection extends ConsumerWidget {
  const IncomingFamilyInviteSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invites = ref.watch(incomingFamilyInvitesProvider);
    if (invites.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Family Invites',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        for (final m in invites) ...[
          _IncomingFamilyInviteCard(membership: m),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
      ],
    );
  }
}

class _IncomingFamilyInviteCard extends ConsumerStatefulWidget {
  final FamilyMembership membership;
  const _IncomingFamilyInviteCard({required this.membership});

  @override
  ConsumerState<_IncomingFamilyInviteCard> createState() =>
      _IncomingFamilyInviteCardState();
}

class _IncomingFamilyInviteCardState
    extends ConsumerState<_IncomingFamilyInviteCard> {
  bool _busy = false;
  Map<String, dynamic>? _ownerProfile;

  @override
  void initState() {
    super.initState();
    _loadOwner();
  }

  Future<void> _loadOwner() async {
    try {
      final row = await Supabase.instance.client
          .from('profiles_public')
          .select('display_name, preferred_name, avatar_url, user_code')
          .eq('id', widget.membership.ownerId)
          .maybeSingle();
      if (mounted) setState(() => _ownerProfile = row);
    } catch (_) {
      // Non-fatal — card falls back to a generic label.
    }
  }

  Future<void> _accept() async {
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) return;

    // Warn if user is currently on their own paid tier — accepting
    // will replace it.
    final sub = ref.read(subscriptionProvider);
    if (sub.isPaid && !sub.isFamilyMember) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceContainerLow,
          title: const Text('Accept family invite?'),
          content: Text(
              'You\'re currently on ${sub.tier.displayName}. Accepting will replace it with the family plan. Continue?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Accept'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(familyServiceProvider).acceptInvite(
            membershipId: widget.membership.id,
            memberId: uid,
            ownerId: widget.membership.ownerId,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Welcome to the family plan!')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _decline() async {
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(familyServiceProvider).declineInvite(
            membershipId: widget.membership.id,
            memberId: uid,
          );
    } catch (_) {
      // silent — the invite disappears when the stream re-emits
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = (_ownerProfile?['preferred_name'] as String?) ??
        (_ownerProfile?['display_name'] as String?) ??
        'Someone';
    final avatarUrl = _ownerProfile?['avatar_url'] as String?;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      border: Border.all(
          color: AppColors.tertiary.withValues(alpha: 0.4)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarCircle(
                radius: 22,
                imageUrl: avatarUrl,
                initials:
                    display.isNotEmpty ? display[0].toUpperCase() : '?',
                borderColor:
                    AppColors.tertiary.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$display invited you',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'to join their Family Pass',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      AppColors.tertiary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color:
                          AppColors.tertiary.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.family_restroom,
                        size: 12, color: AppColors.tertiary),
                    const SizedBox(width: 4),
                    Text(
                      'FAMILY',
                      style: TextStyle(
                        color: AppColors.tertiary,
                        fontFamily: 'Manrope',
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _decline,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.onSurfaceVariant,
                    side: BorderSide(
                        color: AppColors.outlineVariant
                            .withValues(alpha: 0.4)),
                    padding:
                        const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _accept,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.tertiary,
                    foregroundColor: Colors.black,
                    padding:
                        const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black),
                        )
                      : const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
