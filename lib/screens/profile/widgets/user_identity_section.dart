import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/user_model.dart';
import '../../../widgets/avatar_circle.dart';

/// Profile header: large avatar, display name with edit icon, 4 stat pills.
class UserIdentitySection extends StatelessWidget {
  final UserModel user;

  const UserIdentitySection({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Avatar with edit button
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.tertiary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: AvatarCircle(
                radius: 56,
                imageUrl: user.avatarURL,
                initials: user.displayName.isNotEmpty
                    ? user.displayName[0].toUpperCase()
                    : '?',
                borderColor: AppColors.background,
                borderWidth: 3,
              ),
            ),
            Positioned(
              bottom: 2,
              right: 2,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.edit,
                    size: 16, color: AppColors.onPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Username + edit
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(user.displayName,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Icon(Icons.edit,
                size: 18,
                color: AppColors.outline),
          ],
        ),
        const SizedBox(height: 20),

        // 4 stat pills
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            _StatChip(label: 'Level ${user.level}', color: AppColors.primary),
            _StatChip(label: '${user.totalXP} XP', color: AppColors.tertiary),
            _StatChip(
                label: '${user.currentStreak} Day Streak',
                color: AppColors.primary),
            _StatChip(
                label: 'Rank #${user.rank}', color: AppColors.secondary),
          ],
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: Text(label,
          style: TextStyle(
            fontFamily: 'Space Grotesk',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.3,
          )),
    );
  }
}
