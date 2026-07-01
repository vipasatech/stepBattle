import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';
import '../config/constants.dart';
import '../providers/auth_provider.dart';
import '../services/goal_formula.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Set daily step goal sheet — presets + custom stepper.
class SetGoalSheet extends ConsumerStatefulWidget {
  final int currentGoal;

  const SetGoalSheet({super.key, required this.currentGoal});

  @override
  ConsumerState<SetGoalSheet> createState() => _SetGoalSheetState();
}

class _SetGoalSheetState extends ConsumerState<SetGoalSheet> {
  late int _goal;
  bool _saving = false;

  /// Personalized [min, max] range — populated in build() from the
  /// current user's onboarding fields (DOB/gender/fitness_level). If
  /// any are missing (pre-survey users), falls back to
  /// [GoalFormula.fallback]'s loose range.
  StepGoalRecommendation? _range;

  @override
  void initState() {
    super.initState();
    _goal = widget.currentGoal;
  }

  /// Personalized presets — the formula-recommended target plus snapped
  /// points evenly distributed across the allowed range. Falls back to
  /// the legacy [5K, 8K, 10K, 15K] chips when the user hasn't completed
  /// the survey yet.
  List<int> _presetsFor(StepGoalRecommendation r) {
    // Three chips: min, target, max — all clamped multiples of 500.
    final p = <int>{r.min, r.target, r.max}.toList()..sort();
    return p;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final uid = Supabase.instance.client.auth.currentUser!.id;
      await ref
          .read(authServiceProvider)
          .updateProfile(uid, {'daily_step_goal': _goal});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Personalized range. If the user hasn't completed the new survey
    // we fall back to a wide [4,000, 11,000] range so they're not blocked
    // from editing — the "Complete your profile" sheet catches them
    // separately to tighten this later.
    final user = ref.watch(currentUserProvider).valueOrNull;
    _range = user == null
        ? GoalFormula.fallback
        : (GoalFormula.forUser(user) ?? GoalFormula.fallback);
    final range = _range!;
    // Clamp any out-of-range value the caller passed in. Defensive — should
    // never trip in practice unless the user's fitness level just changed.
    if (_goal < range.min || _goal > range.max) {
      _goal = range.clamp(_goal);
    }
    final presets = _presetsFor(range);

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          children: [
            const BottomSheetHandle(),

            // Title
            Center(
              child: Text('Set Your Daily Step Goal',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                  'Your current goal: ${_fmt(widget.currentGoal)} steps/day',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant)),
            ),

            const SizedBox(height: 32),

            // Hero number
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
              ),
              child: Column(
                children: [
                  Text(_fmt(_goal),
                      style: theme.textTheme.displayLarge?.copyWith(
                        color: AppColors.primary,
                        fontSize: 64,
                      )),
                  const SizedBox(height: 4),
                  Text('STEPS PER DAY',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.primary.withValues(alpha: 0.6),
                        letterSpacing: 3,
                      )),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.onSurface.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: AppColors.onSurface.withValues(alpha: 0.1)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sync_alt,
                            size: 14, color: AppColors.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(
                          _goal == widget.currentGoal
                              ? 'Same as current'
                              : _goal > widget.currentGoal
                                  ? '\u2191 ${_fmt(_goal - widget.currentGoal)} more'
                                  : '\u2193 ${_fmt(widget.currentGoal - _goal)} less',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Recommendation strip + preset chips (min / target / max
            // from the personalized formula).
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome,
                      size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Recommended: ${_fmt(range.target)} '
                      '· Range ${_fmt(range.min)} – ${_fmt(range.max)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: presets.map((p) {
                final sel = p == _goal;
                final label = p == range.target
                    ? 'Suggested'
                    : p == range.min
                        ? 'Min'
                        : p == range.max
                            ? 'Max'
                            : '${p ~/ 1000}K';
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () => setState(() => _goal = p),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: sel
                              ? AppColors.primary.withValues(alpha: 0.2)
                              : AppColors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                          border: sel
                              ? Border.all(
                                  color: AppColors.primary
                                      .withValues(alpha: 0.3))
                              : null,
                        ),
                        child: Column(
                          children: [
                            Text('${p ~/ 1000}K',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: sel
                                      ? AppColors.primary
                                      : AppColors.onSurface,
                                  fontWeight: FontWeight.w700,
                                )),
                            Text(label,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: AppColors.onSurfaceVariant,
                                  fontSize: 9,
                                  letterSpacing: 0.5,
                                )),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 24),

            // Custom stepper
            Text('OR ENTER A CUSTOM GOAL',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onSurfaceVariant, letterSpacing: 2)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StepperBtn(
                  icon: Icons.remove,
                  // Clamp to the formula's [min, max] — the user can't
                  // dial below their personalized floor (e.g., 2,500 for
                  // a sedentary elderly user, 5,000 for an advanced
                  // young adult). Going below would lie about health
                  // benefit; going above would invent a target out of
                  // their fitness band.
                  onTap: _goal > range.min
                      ? () => setState(() {
                            final next = _goal - AppConstants.stepGoalIncrement;
                            _goal = next < range.min ? range.min : next;
                          })
                      : null,
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 100,
                  child: Text(_fmt(_goal),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 24),
                _StepperBtn(
                  icon: Icons.add,
                  onTap: _goal < range.max
                      ? () => setState(() {
                            final next = _goal + AppConstants.stepGoalIncrement;
                            _goal = next > range.max ? range.max : next;
                          })
                      : null,
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Motivation card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.tertiary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: AppColors.tertiary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.emoji_events, color: AppColors.tertiary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: theme.textTheme.bodySmall,
                        children: [
                          const TextSpan(text: 'Users who set a goal are '),
                          TextSpan(
                            text: '3\u00d7 more likely',
                            style: TextStyle(
                                color: AppColors.tertiary,
                                fontWeight: FontWeight.w700),
                          ),
                          const TextSpan(text: ' to hit it.'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Save Goal'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
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

class _StepperBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _StepperBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: AppColors.outlineVariant.withValues(alpha: 0.2)),
        ),
        child: Icon(icon,
            color: onTap != null
                ? AppColors.onSurface
                : AppColors.onSurfaceVariant.withValues(alpha: 0.3)),
      ),
    );
  }
}
