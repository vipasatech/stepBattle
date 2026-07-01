import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../services/goal_formula.dart';

/// In-profile edit sheet for the three survey fields (DOB / gender /
/// fitness level). Distinct from [CompleteProfileSheet] which is the
/// no-skip catch-up for pre-survey users:
///
///   • Pre-fills with the current user's values.
///   • Lets the user dismiss without saving.
///   • Single scrollable form (all three sections visible at once) so
///     tweaking one field doesn't require stepping through pages.
///   • On save, recomputes the personalised daily step goal via
///     [GoalFormula] and surfaces an "Apply" SnackBar so the user can
///     opt-in to the new target. We don't silently rewrite an explicitly
///     customised goal.
class EditSurveySheet extends ConsumerStatefulWidget {
  const EditSurveySheet({super.key});

  @override
  ConsumerState<EditSurveySheet> createState() => _EditSurveySheetState();
}

class _EditSurveySheetState extends ConsumerState<EditSurveySheet> {
  /// Min age (COPPA / DPDP Act safety).
  static const int _minAge = 13;

  DateTime? _dateOfBirth;
  Gender? _gender;
  FitnessLevel? _fitnessLevel;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Seed from current user. `ref.read` at init time is fine — the
    // sheet doesn't need to react to live profile changes mid-edit.
    final me = ref.read(currentUserProvider).valueOrNull;
    _dateOfBirth = me?.dateOfBirth;
    _gender = me?.gender;
    _fitnessLevel = me?.fitnessLevel;
  }

  bool get _canSave =>
      _dateOfBirth != null &&
      _gender != null &&
      _fitnessLevel != null &&
      !_saving &&
      _hasChanges;

  bool get _hasChanges {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return true;
    return _dateOfBirth != me.dateOfBirth ||
        _gender != me.gender ||
        _fitnessLevel != me.fitnessLevel;
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) throw StateError('Not signed in');

      // 1. Persist the new survey values.
      await ref.read(authServiceProvider).updateSurveyFields(
            userId: me.userId,
            dateOfBirth: _dateOfBirth!,
            gender: _gender!.wire,
            fitnessLevel: _fitnessLevel!.wire,
          );

      // 2. Recompute the personalised goal from the new values.
      final rec = GoalFormula.compute(
        age: _ageFromDob(_dateOfBirth!),
        gender: _gender!,
        fitnessLevel: _fitnessLevel!,
      );

      ref.invalidate(currentUserProvider);

      if (!mounted) return;
      Navigator.of(context).pop();

      // 3. If the new recommendation differs from the user's current
      //    goal, offer to adopt it — never silently overwrite.
      if (rec.target != me.dailyStepGoal) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Profile updated. Your recommended target is now '
              '${_fmt(rec.target)} steps/day (was ${_fmt(me.dailyStepGoal)}).',
            ),
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Apply',
              onPressed: () async {
                await ref.read(authServiceProvider).updateProfile(
                  me.userId,
                  {'daily_step_goal': rec.target},
                );
                ref.invalidate(currentUserProvider);
              },
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated.'),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  int _ageFromDob(DateTime dob) {
    final now = DateTime.now();
    var y = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      y--;
    }
    return y;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.6,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                  children: [
                    Text(
                      'Edit your info',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Changing any of these recomputes your personalized daily step target.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Birthday
                    _SectionLabel(text: 'BIRTHDAY'),
                    const SizedBox(height: 10),
                    _DobField(
                      value: _dateOfBirth,
                      minAge: _minAge,
                      onPicked: (d) => setState(() => _dateOfBirth = d),
                    ),

                    const SizedBox(height: 24),

                    // Gender
                    _SectionLabel(text: 'GENDER'),
                    const SizedBox(height: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final g in Gender.values)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _OptionCard(
                              title: _genderLabel(g),
                              selected: _gender == g,
                              onTap: () => setState(() => _gender = g),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    // Fitness
                    _SectionLabel(text: 'FITNESS LEVEL'),
                    const SizedBox(height: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final f in FitnessLevel.values)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _OptionCard(
                              title: _fitnessLabel(f),
                              description: _fitnessSublabel(f),
                              selected: _fitnessLevel == f,
                              onTap: () =>
                                  setState(() => _fitnessLevel = f),
                            ),
                          ),
                      ],
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(color: AppColors.error),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: _PrimaryPillButton(
                  label: 'Save',
                  enabled: _canSave,
                  loading: _saving,
                  onPressed: _save,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static String _genderLabel(Gender g) => switch (g) {
        Gender.man => 'Man',
        Gender.woman => 'Woman',
        Gender.nonBinary => 'Non-binary',
        Gender.preferNotToSay => 'Prefer not to say',
      };

  static String _fitnessLabel(FitnessLevel f) => switch (f) {
        FitnessLevel.beginner => 'Beginner',
        FitnessLevel.intermediate => 'Intermediate',
        FitnessLevel.advanced => 'Advanced',
        FitnessLevel.pro => 'Pro',
      };

  static String _fitnessSublabel(FitnessLevel f) => switch (f) {
        FitnessLevel.beginner =>
          'I\'m new to fitness or getting back into it.',
        FitnessLevel.intermediate =>
          'I can do easy-moderate activities.',
        FitnessLevel.advanced =>
          'I like to push myself with difficult activities.',
        FitnessLevel.pro => 'I\'m a professional athlete.',
      };
}

// =============================================================================
// Helper widgets — same visual language as the onboarding flow. These
// duplicate code from onboarding_screen.dart + complete_profile_sheet.dart;
// extracting a shared `lib/widgets/survey/...` file is a follow-up
// cleanup task.
// =============================================================================

class _Tokens {
  static Color get cardFill => AppColors.isDark
      ? const Color(0xFF2A2A2D)
      : AppColors.surfaceContainerHigh;
  static Color get cardSelectedFill => AppColors.isDark
      ? const Color(0xFF323036)
      : AppColors.surfaceContainerHighest;
  static Color get dialogFill => AppColors.isDark
      ? const Color(0xFF1C1C1F)
      : AppColors.surfaceContainer;
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppColors.onSurfaceVariant,
        fontWeight: FontWeight.w800,
        fontSize: 12,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _DobField extends StatelessWidget {
  final DateTime? value;
  final int minAge;
  final ValueChanged<DateTime> onPicked;
  const _DobField({
    required this.value,
    required this.minAge,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    final formatted = value == null
        ? 'Tap to choose'
        : '${value!.day} ${_monthName(value!.month)} ${value!.year}';
    return GestureDetector(
      onTap: () => _openWheelPicker(context),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        decoration: BoxDecoration(
          color: _Tokens.cardFill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          formatted,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: value == null
                ? AppColors.onSurfaceVariant
                : Colors.white,
          ),
        ),
      ),
    );
  }

  Future<void> _openWheelPicker(BuildContext context) async {
    final now = DateTime.now();
    final initial = value ?? DateTime(now.year - 20, now.month, now.day);
    final maxDate = DateTime(now.year - minAge, now.month, now.day);
    var picked = initial;
    final result = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        backgroundColor: _Tokens.dialogFill,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 22, 0, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose Date of Birth',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 220,
                child: CupertinoTheme(
                  data: const CupertinoThemeData(
                    brightness: Brightness.dark,
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: initial,
                    minimumDate: DateTime(now.year - 100),
                    maximumDate: maxDate,
                    onDateTimeChanged: (d) => picked = d,
                  ),
                ),
              ),
              Container(
                height: 1,
                color: AppColors.onSurface.withValues(alpha: 0.08),
              ),
              IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: const SizedBox(
                          height: 52,
                          child: Center(
                            child: Text(
                              'Cancel',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 1,
                      color: AppColors.onSurface.withValues(alpha: 0.08),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(picked),
                        child: SizedBox(
                          height: 52,
                          child: Center(
                            child: Text(
                              'OK',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) onPicked(result);
  }

  static String _monthName(int m) => const [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ][m - 1];
}

class _OptionCard extends StatelessWidget {
  final String title;
  final String? description;
  final bool selected;
  final VoidCallback onTap;
  const _OptionCard({
    required this.title,
    required this.selected,
    required this.onTap,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: selected ? _Tokens.cardSelectedFill : _Tokens.cardFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 4),
              Text(
                description!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PrimaryPillButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback onPressed;
  const _PrimaryPillButton({
    required this.label,
    required this.enabled,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final bg = enabled
        ? AppColors.primary
        : AppColors.primary.withValues(alpha: 0.25);
    final fg =
        enabled ? Colors.white : AppColors.onSurface.withValues(alpha: 0.45);
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(27),
        child: InkWell(
          onTap: enabled && !loading ? onPressed : null,
          borderRadius: BorderRadius.circular(27),
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Opens the [EditSurveySheet] over the root navigator. Returns when
/// the sheet is dismissed.
Future<void> showEditSurveySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const EditSurveySheet(),
  );
}
