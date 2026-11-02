import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';

/// Optional battle-name input (migration 0061, 2026-09-04).
///
/// Reused verbatim across all three setup sheets — 1v1, group, team —
/// so the field always looks / feels the same regardless of format.
///
/// **Contract**:
///   • The parent owns the [controller] (so it can read `.text` at
///     submit and dispose it).
///   • [onChanged] is optional — used by the team-lobby sheet where the
///     name persists via a debounced `setBattleName` mutator on the
///     already-drafted battle row. For 1v1 / group the parent reads
///     `controller.text` at submit-time only.
///   • Max length is hard-clamped at 30 to match the server-side CHECK
///     constraint on `battles.name` / `battle_series.name`. The counter
///     ("12/30") appears only when the user starts typing so the field
///     doesn't feel busy at rest.
///
/// The design deliberately matches the tone of the surrounding pickers
/// (BattleDurationPicker, BattleStakePicker) — a plain label ABOVE the
/// input, no card wrapper, so the sheet stays visually calm.
class BattleNameField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  const BattleNameField({
    super.key,
    required this.controller,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Match the label style used by BattleDurationPicker /
        // BattleStakePicker headers so the sections read as siblings,
        // not competing widgets.
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Text(
                'Battle name',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'optional',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        TextField(
          controller: controller,
          onChanged: onChanged,
          maxLength: 30,
          textCapitalization: TextCapitalization.sentences,
          // Single line — battle names never wrap.
          maxLines: 1,
          // Allow letters, numbers, spaces, common punctuation, AND
          // emoji (any non-control character). Blocking would make
          // "🌅 Morning Warriors" feel wrong; the server CHECK enforces
          // the only real rule (length).
          inputFormatters: [
            LengthLimitingTextInputFormatter(30),
          ],
          style: theme.textTheme.bodyLarge?.copyWith(
            color: AppColors.onSurface,
          ),
          decoration: InputDecoration(
            hintText: 'e.g. Morning Warriors, Revenge match',
            hintStyle: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            filled: true,
            fillColor: AppColors.surfaceContainerLow,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.onSurface.withValues(alpha: 0.08),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.onSurface.withValues(alpha: 0.08),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.primary,
                width: 1.4,
              ),
            ),
            // Hide the default counter — we render our own only when the
            // user actually types (see the AnimatedBuilder below). The
            // default counter is always visible and adds visual noise
            // when the field is empty.
            counterText: '',
          ),
        ),
        // On-demand counter — only when text is present. Keeps the
        // field visually quiet at rest, informative when in use.
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final len = controller.text.characters.length;
            if (len == 0) return const SizedBox.shrink();
            final atCap = len >= 30;
            return Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '$len/30',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: atCap
                        ? AppColors.error
                        : AppColors.onSurfaceVariant,
                    fontWeight:
                        atCap ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
