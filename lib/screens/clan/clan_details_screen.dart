import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../models/clan_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clan_provider.dart';
import '../../services/clan_service.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/glass_card.dart';

/// Clan Details — reachable from the gear icon on the Clan tab.
/// Shows clan metadata, full member list with role actions, and the
/// destructive Leave / Delete buttons.
class ClanDetailsScreen extends ConsumerWidget {
  const ClanDetailsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clan = ref.watch(currentClanProvider).valueOrNull;
    final members = ref.watch(clanMembersProvider).valueOrNull ?? [];
    final uid = ref.watch(authStateProvider).valueOrNull?.uid ?? '';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Clan Details',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: AppColors.onSurface,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
      body: clan == null
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                _ClanHeader(clan: clan),
                const SizedBox(height: 24),
                _MembersSection(
                  clan: clan,
                  members: members,
                  currentUserId: uid,
                ),
                if (clan.pendingInviteIds.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _PendingInvitesCard(count: clan.pendingInviteIds.length),
                ],
                const SizedBox(height: 32),
                _DangerZone(clan: clan, members: members, currentUserId: uid),
                const SizedBox(height: 40),
              ],
            ),
    );
  }
}

// =============================================================================
// Header
// =============================================================================
class _ClanHeader extends StatelessWidget {
  final ClanModel clan;
  const _ClanHeader({required this.clan});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.shield,
                    color: AppColors.onPrimary, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clan.name.toUpperCase(),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: AppColors.primaryBrand,
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${clan.memberCount} / ${clan.maxMembers} members',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: clan.clanIdCode));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Clan ID copied!')),
              );
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Clan ID: ${clan.clanIdCode}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.content_copy,
                      size: 14, color: AppColors.primaryBrand),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Members list
// =============================================================================
class _MembersSection extends ConsumerWidget {
  final ClanModel clan;
  final List<ClanMember> members;
  final String currentUserId;

  const _MembersSection({
    required this.clan,
    required this.members,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sorted = [...members];
    sorted.sort((a, b) {
      int rank(ClanMember m) => m.isCaptain ? 0 : (m.isAdmin ? 1 : 2);
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Members',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        ...sorted.map((m) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _MemberDetailRow(
                clan: clan,
                member: m,
                currentUserId: currentUserId,
              ),
            )),
      ],
    );
  }
}

class _MemberDetailRow extends ConsumerWidget {
  final ClanModel clan;
  final ClanMember member;
  final String currentUserId;

  const _MemberDetailRow({
    required this.clan,
    required this.member,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final actorIsCaptain = clan.isCaptain(currentUserId);
    final actorIsAdmin = clan.adminIds.contains(currentUserId);
    final isSelf = member.userId == currentUserId;
    final isCaptainRow = member.isCaptain;

    final canShowMenu = !isSelf &&
        !isCaptainRow &&
        (actorIsCaptain ||
            (actorIsAdmin && member.isSoldier)); // admins can only kick soldiers

    return GlassCard(
      padding: const EdgeInsets.all(14),
      borderRadius: 16,
      child: Row(
        children: [
          AvatarCircle(
            radius: 22,
            imageUrl: member.avatarURL,
            initials: member.displayName.isNotEmpty
                ? member.displayName[0].toUpperCase()
                : '?',
            borderColor: member.isCaptain
                ? AppColors.primary
                : (member.isAdmin
                    ? AppColors.tertiary
                    : Colors.white.withValues(alpha: 0.05)),
            borderWidth: member.isCaptain || member.isAdmin ? 2 : 1,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        member.displayName +
                            (isSelf ? ' (you)' : ''),
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _RoleBadge(role: member.role, label: member.roleLabel),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmt(member.stepsToday)} steps today',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (canShowMenu)
            _MemberActionsMenu(
              clan: clan,
              member: member,
              currentUserId: currentUserId,
              actorIsCaptain: actorIsCaptain,
            ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _RoleBadge extends StatelessWidget {
  final String role;
  final String label;
  const _RoleBadge({required this.role, required this.label});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (role) {
      'captain' => (
          AppColors.amber.withValues(alpha: 0.12),
          AppColors.amber,
        ),
      'admin' => (
          AppColors.tertiary.withValues(alpha: 0.12),
          AppColors.tertiary,
        ),
      _ => (
          AppColors.onSurfaceVariant.withValues(alpha: 0.1),
          AppColors.onSurfaceVariant,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Manrope',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

class _MemberActionsMenu extends ConsumerStatefulWidget {
  final ClanModel clan;
  final ClanMember member;
  final String currentUserId;
  final bool actorIsCaptain;

  const _MemberActionsMenu({
    required this.clan,
    required this.member,
    required this.currentUserId,
    required this.actorIsCaptain,
  });

  @override
  ConsumerState<_MemberActionsMenu> createState() =>
      _MemberActionsMenuState();
}

class _MemberActionsMenuState extends ConsumerState<_MemberActionsMenu> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() op) async {
    setState(() => _busy = true);
    try {
      await op();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'.replaceFirst('Bad state: ', ''))),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.primary),
          ),
        ),
      );
    }

    final svc = ref.read(clanServiceProvider);
    final clan = widget.clan;
    final m = widget.member;
    final actorId = widget.currentUserId;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: AppColors.onSurfaceVariant),
      color: AppColors.surfaceContainerLow,
      onSelected: (value) async {
        switch (value) {
          case 'promote':
            await _run(() => svc.promoteToAdmin(
                  clanId: clan.clanId,
                  captainId: actorId,
                  userId: m.userId,
                ));
            break;
          case 'demote':
            await _run(() => svc.demoteAdmin(
                  clanId: clan.clanId,
                  captainId: actorId,
                  userId: m.userId,
                ));
            break;
          case 'transfer':
            final confirmed = await _confirm(
              context,
              title: 'Transfer captaincy?',
              body:
                  '${m.displayName} will become the new captain. You will be demoted to soldier.',
              confirmLabel: 'Transfer',
              destructive: false,
            );
            if (confirmed) {
              await _run(() => svc.transferCaptaincy(
                    clanId: clan.clanId,
                    currentCaptainId: actorId,
                    newCaptainId: m.userId,
                  ));
            }
            break;
          case 'kick':
            final confirmed = await _confirm(
              context,
              title: 'Kick ${m.displayName}?',
              body: 'They will be removed from the clan immediately.',
              confirmLabel: 'Kick',
              destructive: true,
            );
            if (confirmed) {
              await _run(() => svc.kickMember(
                    clanId: clan.clanId,
                    actorId: actorId,
                    targetId: m.userId,
                  ));
            }
            break;
        }
      },
      itemBuilder: (_) => [
        if (widget.actorIsCaptain && m.isSoldier)
          const PopupMenuItem(
              value: 'promote', child: Text('Promote to Admin')),
        if (widget.actorIsCaptain && m.isAdmin)
          const PopupMenuItem(
              value: 'demote', child: Text('Demote to Soldier')),
        if (widget.actorIsCaptain)
          const PopupMenuItem(
              value: 'transfer', child: Text('Transfer Captaincy')),
        const PopupMenuItem(
            value: 'kick',
            child: Text('Kick from Clan',
                style: TextStyle(color: AppColors.error))),
      ],
    );
  }
}

// =============================================================================
// Pending invites card
// =============================================================================
class _PendingInvitesCard extends StatelessWidget {
  final int count;
  const _PendingInvitesCard({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.hourglass_top, size: 16, color: AppColors.amber),
          const SizedBox(width: 8),
          Text(
            '$count pending invite${count == 1 ? '' : 's'}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: AppColors.amber,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Danger zone (Leave / Delete)
// =============================================================================
class _DangerZone extends ConsumerStatefulWidget {
  final ClanModel clan;
  final List<ClanMember> members;
  final String currentUserId;

  const _DangerZone({
    required this.clan,
    required this.members,
    required this.currentUserId,
  });

  @override
  ConsumerState<_DangerZone> createState() => _DangerZoneState();
}

class _DangerZoneState extends ConsumerState<_DangerZone> {
  bool _busy = false;

  ClanService get _svc => ref.read(clanServiceProvider);

  Future<void> _handleLeave() async {
    final clan = widget.clan;
    final uid = widget.currentUserId;
    final isCaptain = clan.isCaptain(uid);

    if (isCaptain) {
      // Force transfer before leaving
      final eligible =
          widget.members.where((m) => m.userId != uid).toList();
      if (eligible.isEmpty) {
        _snack(
            'You are the only member. Delete the clan instead of leaving.');
        return;
      }
      final picked = await _showCaptainPicker(context, eligible);
      if (picked == null) return;

      setState(() => _busy = true);
      try {
        await _svc.transferCaptaincy(
          clanId: clan.clanId,
          currentCaptainId: uid,
          newCaptainId: picked.userId,
        );
        await _svc.leaveClan(clanId: clan.clanId, userId: uid);
        if (mounted) {
          _snack('Captaincy transferred to ${picked.displayName}. You left the clan.');
          context.pop();
        }
      } catch (e) {
        _snack('Failed: $e');
      }
      if (mounted) setState(() => _busy = false);
      return;
    }

    // Non-captain confirm + leave
    final confirmed = await _confirm(
      context,
      title: 'Leave clan?',
      body: 'You will no longer be a member of "${clan.name}".',
      confirmLabel: 'Leave',
      destructive: true,
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await _svc.leaveClan(clanId: clan.clanId, userId: uid);
      if (mounted) {
        _snack('You left the clan.');
        context.pop();
      }
    } catch (e) {
      _snack('Failed: $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _handleDelete() async {
    final clan = widget.clan;
    final confirmed = await _confirm(
      context,
      title: 'Delete "${clan.name}"?',
      body:
          'The clan will be permanently disbanded. All ${clan.memberCount} member${clan.memberCount == 1 ? '' : 's'} will be removed and any active clan battles will end.',
      confirmLabel: 'Delete Clan',
      destructive: true,
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await _svc.deleteClan(
          clanId: clan.clanId, captainId: widget.currentUserId);
      if (mounted) {
        _snack('Clan deleted.');
        context.pop();
      }
    } catch (e) {
      _snack('Failed: $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCaptain = widget.clan.isCaptain(widget.currentUserId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Danger Zone',
          style: theme.textTheme.labelLarge?.copyWith(
            color: AppColors.error,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _handleLeave,
            icon: const Icon(Icons.logout, size: 18),
            label: Text(isCaptain
                ? 'Transfer & Leave Clan'
                : 'Leave Clan'),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
              foregroundColor: AppColors.error,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        if (isCaptain) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _handleDelete,
              icon: const Icon(Icons.delete_forever, size: 18),
              label: const Text('Delete Clan'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.error,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 12),
          const Center(
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.primary),
          ),
        ],
      ],
    );
  }
}

// =============================================================================
// Captain picker (modal)
// =============================================================================
Future<ClanMember?> _showCaptainPicker(
  BuildContext context,
  List<ClanMember> candidates,
) {
  ClanMember? selected;
  return showModalBottomSheet<ClanMember>(
    context: context,
    backgroundColor: AppColors.surfaceContainerLow,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Choose new captain',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'They will inherit captain powers. You will become a soldier and leave the clan.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.5,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: candidates.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final m = candidates[i];
                      final isPicked = selected?.userId == m.userId;
                      return InkWell(
                        onTap: () => setModalState(() => selected = m),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isPicked
                                ? AppColors.primary.withValues(alpha: 0.12)
                                : AppColors.surfaceContainerHigh
                                    .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isPicked
                                  ? AppColors.primary
                                  : Colors.white.withValues(alpha: 0.05),
                            ),
                          ),
                          child: Row(
                            children: [
                              AvatarCircle(
                                radius: 18,
                                imageUrl: m.avatarURL,
                                initials: m.displayName.isNotEmpty
                                    ? m.displayName[0].toUpperCase()
                                    : '?',
                                borderColor: Colors.white
                                    .withValues(alpha: 0.05),
                                borderWidth: 1,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(m.displayName,
                                        style: Theme.of(ctx)
                                            .textTheme
                                            .titleSmall),
                                    Text(m.roleLabel,
                                        style: Theme.of(ctx)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                                color: AppColors
                                                    .onSurfaceVariant)),
                                  ],
                                ),
                              ),
                              if (isPicked)
                                const Icon(Icons.check_circle,
                                    color: AppColors.primary),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, null),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: selected == null
                            ? null
                            : () => Navigator.pop(ctx, selected),
                        child: const Text('Transfer & Leave'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

// =============================================================================
// Shared confirm dialog
// =============================================================================
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required bool destructive,
}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceContainerLow,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor:
                destructive ? AppColors.error : AppColors.primary,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return res == true;
}
