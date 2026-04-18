import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../models/clan_model.dart';
import '../../providers/clan_provider.dart';
import '../../sheets/create_clan_sheet.dart';
import '../../sheets/join_clan_sheet.dart';

/// Clan tab entry state — shown when user has no clan.
/// Shows pending clan invites at the top if any, then the Create/Join CTAs.
class ClanEntryView extends ConsumerWidget {
  const ClanEntryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final invites = ref.watch(incomingClanInvitesProvider).valueOrNull ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Pending invites section at the top
          if (invites.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'PENDING CLAN INVITES',
                style: theme.textTheme.labelMedium?.copyWith(
                    color: AppColors.amber, letterSpacing: 2),
              ),
            ),
            const SizedBox(height: 10),
            ...invites.map((c) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PendingInviteCard(clan: c),
                )),
            const SizedBox(height: 28),
          ],

          // Hero
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.08),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.2),
                      blurRadius: 60,
                    ),
                  ],
                ),
              ),
              Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceContainerLow,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                ),
                child: Icon(Icons.shield,
                    size: 80, color: AppColors.primary.withValues(alpha: 0.8)),
              ),
              Positioned(
                top: 20,
                right: 40,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.tertiary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                bottom: 40,
                left: 30,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),

          Text(
            'Join the Battle\nTogether',
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Team up. Compete together.\nDominate the leaderboard.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant, height: 1.5),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 36),

          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: () => _showCreateClan(context),
              icon: const Icon(Icons.add_circle, size: 20),
              label: const Text('CREATE CLAN'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: OutlinedButton(
              onPressed: () => _showJoinClan(context),
              child: const Text('JOIN CLAN'),
            ),
          ),
        ],
      ),
    );
  }

  void _showCreateClan(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CreateClanSheet(),
    );
  }

  void _showJoinClan(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const JoinClanSheet(),
    );
  }
}

// =============================================================================
// Pending clan invite card with Accept / Reject
// =============================================================================
class _PendingInviteCard extends ConsumerStatefulWidget {
  final ClanModel clan;

  const _PendingInviteCard({required this.clan});

  @override
  ConsumerState<_PendingInviteCard> createState() => _PendingInviteCardState();
}

class _PendingInviteCardState extends ConsumerState<_PendingInviteCard> {
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await ref
            .read(clanServiceProvider)
            .acceptClanInvite(clanId: widget.clan.clanId, userId: uid);
      }
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await ref
            .read(clanServiceProvider)
            .rejectClanInvite(clanId: widget.clan.clanId, userId: uid);
      }
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.shield, color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.clan.name,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      '${widget.clan.clanIdCode} · ${widget.clan.memberCount}/${widget.clan.maxMembers} members',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_busy)
            const Center(
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
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _accept,
                    child: const Text('Join Clan'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
