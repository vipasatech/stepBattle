import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/user_model.dart';

/// Account details section — email, phone, connected health app.
class AccountDetails extends StatelessWidget {
  final UserModel user;

  const AccountDetails({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Account',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              _AccountRow(
                icon: Icons.mail,
                label: 'Email',
                value: user.email,
              ),
              const SizedBox(height: 16),
              _AccountRow(
                icon: Icons.phone,
                label: 'Phone',
                value: user.phone ?? '+91 XXXXXXXXXX',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.sync, size: 20, color: AppColors.outline),
                  const SizedBox(width: 12),
                  Text('Connected to',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.onSurfaceVariant)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.secondaryContainer.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.health_and_safety,
                            size: 14, color: AppColors.primary),
                        const SizedBox(width: 4),
                        Text('Apple Health',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _AccountRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.outline),
        const SizedBox(width: 12),
        Text(label,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant)),
        const Spacer(),
        Text(value,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w500)),
      ],
    );
  }
}
