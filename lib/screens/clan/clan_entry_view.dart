import 'package:flutter/material.dart';
import '../../config/colors.dart';
import '../../sheets/create_clan_sheet.dart';
import '../../sheets/join_clan_sheet.dart';

/// Clan tab entry state — shown when user has no clan.
/// Large shield illustration + "Join the Battle Together" + two CTAs.
class ClanEntryView extends StatelessWidget {
  const ClanEntryView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Ambient glow behind shield
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
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.05)),
                  ),
                  child: Icon(Icons.shield,
                      size: 80,
                      color: AppColors.primary.withValues(alpha: 0.8)),
                ),
                // Spark dots
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

            const SizedBox(height: 40),

            Text(
              'Join the Battle\nTogether',
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Team up. Compete together.\nDominate the leaderboard.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant, height: 1.5),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 48),

            // Create Clan button
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
            // Join Clan button
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
