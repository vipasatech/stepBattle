import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../models/clan_model.dart';
import '../../providers/clan_provider.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/dual_fill_bar.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/status_pill.dart';

/// Clan dashboard — members list + active clan battle + action buttons.
class ClanDashboardView extends ConsumerWidget {
  const ClanDashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(clanMembersProvider).valueOrNull ?? [];
    final clanBattle = ref.watch(activeClanBattleProvider).valueOrNull;
    final clan = ref.watch(currentClanProvider).valueOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      children: [
        // ===== SOLDIERS SECTION =====
        _SoldiersSection(members: members, clanCode: clan?.clanIdCode ?? ''),

        const SizedBox(height: 28),

        // ===== CLAN BATTLES SECTION =====
        Text('Clan Battles',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),

        // Active battle card
        if (clanBattle != null)
          _ClanBattleCard(
            yourClan: clanBattle.clanA.clanName,
            opponentClan: clanBattle.clanB.clanName,
            yourSteps: clanBattle.clanA.totalSteps,
            opponentSteps: clanBattle.clanB.totalSteps,
            timeLeft: clanBattle.timeRemainingLabel,
            xpPerMember: clanBattle.xpPerMember,
          ),

        const SizedBox(height: 16),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => context.go('/clan/create-battle'),
                  icon: const Icon(Icons.bolt, size: 18),
                  label: const Text('Create Battle'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => context.go('/clan/join-battle'),
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('Join Battle'),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.4)),
                    foregroundColor: AppColors.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// Soldiers section
// =============================================================================
class _SoldiersSection extends StatelessWidget {
  final List<ClanMember> members;
  final String clanCode;

  const _SoldiersSection({required this.members, required this.clanCode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header + clan ID
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Soldiers',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            if (clanCode.isNotEmpty)
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: clanCode));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Clan ID copied!')),
                  );
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.05)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Clan ID: $clanCode',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: AppColors.onSurfaceVariant,
                              letterSpacing: 1)),
                      const SizedBox(width: 4),
                      Icon(Icons.content_copy,
                          size: 12, color: AppColors.primaryBrand),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),

        // Member rows
        ...members.map((m) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _MemberRow(member: m),
            )),

        // Add members button
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              // TODO: Open Add Friends sheet in multi-select mode
            },
            icon: const Icon(Icons.group_add, size: 16),
            label: const Text('+ Add Members'),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.1),
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignInside),
              foregroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  final ClanMember member;

  const _MemberRow({required this.member});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      borderRadius: 16,
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AvatarCircle(
                radius: 22,
                imageUrl: member.avatarURL,
                initials: member.displayName.isNotEmpty
                    ? member.displayName[0].toUpperCase()
                    : '?',
                borderColor: member.isCaptain
                    ? AppColors.primary
                    : Colors.white.withValues(alpha: 0.05),
                borderWidth: member.isCaptain ? 2 : 1,
              ),
              if (member.isCaptain)
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.star,
                        size: 10, color: AppColors.onPrimary),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(member.displayName,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: member.isCaptain
                            ? AppColors.amber.withValues(alpha: 0.1)
                            : AppColors.onSurfaceVariant
                                .withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        member.isCaptain ? 'Captain' : 'Soldier',
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: member.isCaptain
                              ? AppColors.amber
                              : AppColors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _fmt(member.stepsToday),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text('Steps',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant, letterSpacing: 1)),
            ],
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

// =============================================================================
// Clan battle card
// =============================================================================
class _ClanBattleCard extends StatelessWidget {
  final String yourClan;
  final String opponentClan;
  final int yourSteps;
  final int opponentSteps;
  final String timeLeft;
  final int xpPerMember;

  const _ClanBattleCard({
    required this.yourClan,
    required this.opponentClan,
    required this.yourSteps,
    required this.opponentSteps,
    required this.timeLeft,
    required this.xpPerMember,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(20),
      border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      child: Column(
        children: [
          // Live + time
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const StatusPill(type: StatusType.live),
              Text(timeLeft,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 16),

          // Matchup icons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ClanIcon(name: yourClan, color: AppColors.primary),
              Icon(Icons.bolt, color: AppColors.tertiary, size: 24),
              _ClanIcon(
                  name: opponentClan, color: AppColors.surfaceContainerHigh),
            ],
          ),
          const SizedBox(height: 16),

          // Step totals
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your Clan',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: AppColors.onSurfaceVariant)),
                  Text(_fmt(yourSteps),
                      style: theme.textTheme.headlineSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w900)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(opponentClan,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: AppColors.onSurfaceVariant)),
                  Text(_fmt(opponentSteps),
                      style: theme.textTheme.headlineSmall?.copyWith(
                          color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
                          fontWeight: FontWeight.w900)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          DualFillBar(yourSteps: yourSteps, opponentSteps: opponentSteps),

          const SizedBox(height: 14),

          // XP reward
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.tertiary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.tertiary.withValues(alpha: 0.1)),
            ),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.workspace_premium,
                      size: 14, color: AppColors.tertiary),
                  const SizedBox(width: 6),
                  Text(
                    '+$xpPerMember XP per member on win',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.tertiary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
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

class _ClanIcon extends StatelessWidget {
  final String name;
  final Color color;

  const _ClanIcon({required this.name, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Icon(Icons.shield, color: color, size: 28),
        ),
        const SizedBox(height: 6),
        Text(name,
            style: TextStyle(
              fontFamily: 'Space Grotesk',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.8),
            )),
      ],
    );
  }
}
