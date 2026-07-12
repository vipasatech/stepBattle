import 'package:flutter/material.dart';

import '../../config/colors.dart';

/// Shared pill-shaped social/email button used by both login and signup
/// screens. Kept in its own file so signup can reuse it without pulling
/// in `login_screen.dart`.
class AuthSocialButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color? textColor;

  const AuthSocialButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final fgColor = textColor ?? AppColors.onSurface;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: fgColor, size: 24),
        label: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fgColor),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: backgroundColor,
          side: BorderSide(color: AppColors.onSurface.withValues(alpha: 0.05)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }
}
