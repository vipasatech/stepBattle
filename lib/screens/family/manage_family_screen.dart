import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/colors.dart';
import '../../models/family_membership_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/subscription_provider.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';

/// Owner-only Family-Pass management. Reached from the "Manage Family"
/// button in [UpgradeCTASheet] (visible only when the current user is
/// a family owner).
///
/// Sections:
///   1. Active members — list of accepted members (up to 3) with a
///      Remove button on each row.
///   2. Invite by user code — text field + send button.
///   3. Pending invites — outgoing invites awaiting a response, with
///      a Cancel button.
class ManageFamilyScreen extends ConsumerStatefulWidget {
  const ManageFamilyScreen({super.key});

  @override
  ConsumerState<ManageFamilyScreen> createState() =>
      _ManageFamilyScreenState();
}

class _ManageFamilyScreenState extends ConsumerState<ManageFamilyScreen> {
  final _codeController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendInvite() async {
    final uid = ref.read(authStateProvider).valueOrNull?.id ?? '';
    if (uid.isEmpty) return;
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(familyServiceProvider)
          .inviteByUserCode(ownerId: uid, memberUserCode: code);
      if (!mounted) return;
      _codeController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invite sent to $code')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is StateError ? e.message : 'Failed: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _confirmBoot(FamilyMembership m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerLow,
        title: const Text('Remove member?'),
        content: const Text(
            'They\'ll be reverted to the Free plan immediately. You can re-invite them later.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final uid = ref.read(authStateProvider).valueOrNull?.id ?? '';
    try {
      await ref.read(familyServiceProvider).bootMember(
            membershipId: m.id,
            memberId: m.memberId,
            ownerId: uid,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Member removed.')),
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

  Future<void> _cancelInvite(FamilyMembership m) async {
    final uid = ref.read(authStateProvider).valueOrNull?.id ?? '';
    try {
      await ref.read(familyServiceProvider).cancelPendingInvite(
            membershipId: m.id,
            ownerId: uid,
          );
    } catch (_) {
      // silent
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = ref.watch(subscriptionProvider);
    final members = ref.watch(familyMembersProvider);
    final pending = ref.watch(pendingSentInvitesProvider);
    final totalSeats = 1 + members.length; // owner + members
    const seatCap = 4;
    final canInviteMore = members.length + pending.length < seatCap - 1;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Family sharing'),
      ),
      body: !sub.isFamilyOwner
          ? const _NonOwnerView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                // Header — seats used
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  border: Border.all(
                      color: AppColors.tertiary.withValues(alpha: 0.35)),
                  child: Row(
                    children: [
                      Icon(Icons.family_restroom,
                          color: AppColors.tertiary, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('$totalSeats / $seatCap seats used',
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(
                                        fontWeight: FontWeight.w800)),
                            Text(
                              'You + ${members.length} member${members.length == 1 ? '' : 's'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Members section
                Text('MEMBERS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w800,
                    )),
                const SizedBox(height: 10),
                if (members.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: AppColors.outlineVariant
                              .withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      'No members yet. Invite a friend by their user code below.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ...members.map((m) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _MemberRow(
                          membership: m,
                          onRemove: () => _confirmBoot(m),
                        ),
                      )),

                const SizedBox(height: 28),

                // Invite section
                Text('INVITE BY USER CODE',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w800,
                    )),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _codeController,
                        enabled: canInviteMore && !_sending,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          UpperCaseTextFormatter(),
                          LengthLimitingTextInputFormatter(10),
                        ],
                        decoration: InputDecoration(
                          hintText: '#U4X92',
                          prefixIcon:
                              Icon(Icons.tag, color: AppColors.primary),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed:
                          canInviteMore && !_sending ? _sendInvite : null,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                      ),
                      child: _sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Send'),
                    ),
                  ],
                ),
                if (!canInviteMore) ...[
                  const SizedBox(height: 8),
                  Text(
                    'You\'ve used all 3 invitation seats. Remove a member to invite someone else.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.amber,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  Text(
                    'They\'ll get a Family invite in their Battles tab.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],

                // Pending outgoing invites
                if (pending.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text('PENDING INVITES',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w800,
                      )),
                  const SizedBox(height: 10),
                  ...pending.map((m) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _MemberRow(
                          membership: m,
                          isPending: true,
                          onRemove: () => _cancelInvite(m),
                        ),
                      )),
                ],
              ],
            ),
    );
  }
}

/// Fetches a profile row on demand and renders a member card. Uses a
/// FutureBuilder so each row loads its own data (~1 request per
/// member — usually 0-3 total, negligible).
class _MemberRow extends StatelessWidget {
  final FamilyMembership membership;
  final bool isPending;
  final VoidCallback onRemove;
  const _MemberRow({
    required this.membership,
    required this.onRemove,
    this.isPending = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Map<String, dynamic>?>(
      future: Supabase.instance.client
          .from('profiles_public')
          .select('display_name, preferred_name, avatar_url, user_code')
          .eq('id', membership.memberId)
          .maybeSingle(),
      builder: (context, snapshot) {
        final row = snapshot.data;
        final display = (row?['preferred_name'] as String?) ??
            (row?['display_name'] as String?) ??
            'Member';
        final userCode = row?['user_code'] as String? ?? '';
        final avatarUrl = row?['avatar_url'] as String?;

        return GlassCard(
          padding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 12),
          border: Border.all(
            color: isPending
                ? AppColors.amber.withValues(alpha: 0.3)
                : AppColors.outlineVariant.withValues(alpha: 0.35),
          ),
          child: Row(
            children: [
              AvatarCircle(
                radius: 20,
                imageUrl: avatarUrl,
                initials:
                    display.isNotEmpty ? display[0].toUpperCase() : '?',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      display,
                      style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (userCode.isNotEmpty)
                      Text(
                        userCode,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                    if (isPending)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Waiting for response…',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.amber,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  isPending ? Icons.close : Icons.person_remove_outlined,
                  color: AppColors.error,
                ),
                tooltip: isPending ? 'Cancel invite' : 'Remove member',
                onPressed: onRemove,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NonOwnerView extends ConsumerWidget {
  const _NonOwnerView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sub = ref.watch(subscriptionProvider);
    if (sub.isFamilyMember) {
      return EmptyState(
        icon: Icons.family_restroom,
        title: 'You\'re on a family plan',
        subtitle:
            'Only the family owner can manage members. Ask them to invite / remove people.',
      );
    }
    // Family sharing is a grandfathered feature — the Basic / Pro / Max
    // rename (migration 0051) dropped it from new signups. Existing
    // Family (now Max) owners still see this screen with their linked
    // members; nobody new lands here.
    return const EmptyState(
      icon: Icons.workspace_premium_outlined,
      title: 'Family sharing not available',
      subtitle:
          'Family sharing is no longer offered on new plans. Existing shares stay intact.',
    );
  }
}

/// Uppercase-only text formatter for the user-code input.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
