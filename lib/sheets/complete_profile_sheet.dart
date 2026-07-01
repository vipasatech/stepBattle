import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../services/goal_formula.dart';

/// Catch-up sheet for users who onboarded BEFORE migration 0016 added the
/// mandatory survey fields (DOB / gender / fitness level). Triggered by
/// [maybeShowCompleteProfileSheet] on the Home tab's first build per
/// session.
///
/// Visual language matches the new onboarding screen (Strava-inspired:
/// black background, large bold question titles, dark grey option cards
/// with purple selected-state border, full-width purple Continue pill).
/// Modal and no-skip — same gating semantics as the onboarding flow.
class CompleteProfileSheet extends ConsumerStatefulWidget {
  const CompleteProfileSheet({super.key});

  @override
  ConsumerState<CompleteProfileSheet> createState() =>
      _CompleteProfileSheetState();
}

class _CompleteProfileSheetState extends ConsumerState<CompleteProfileSheet> {
  /// Min age (COPPA / DPDP Act safety).
  static const int _minAge = 13;

  /// Three-step PageView (DOB → gender → fitness). Matches the onboarding
  /// pattern so the user sees a consistent flow even though this is a
  /// shorter version for catch-up.
  static const int _totalSteps = 3;

  final _pageController = PageController();
  int _currentPage = 0;

  DateTime? _dateOfBirth;
  Gender? _gender;
  FitnessLevel? _fitnessLevel;
  bool _saving = false;
  String? _error;

  bool get _canContinue {
    switch (_currentPage) {
      case 0:
        return _dateOfBirth != null && _ageFromDob(_dateOfBirth!) >= _minAge;
      case 1:
        return _gender != null;
      case 2:
        return _fitnessLevel != null;
    }
    return false;
  }

  void _next() {
    if (!_canContinue) return;
    if (_currentPage < _totalSteps - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      setState(() => _currentPage++);
    } else {
      _save();
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) throw StateError('Not signed in');

      await ref.read(authServiceProvider).updateSurveyFields(
            userId: me.userId,
            dateOfBirth: _dateOfBirth!,
            gender: _gender!.wire,
            fitnessLevel: _fitnessLevel!.wire,
          );

      // Adopt the formula-recommended goal only if the user is still on
      // the legacy 8,000 default — never overwrite a deliberate custom
      // value the user already set.
      final rec = GoalFormula.compute(
        age: _ageFromDob(_dateOfBirth!),
        gender: _gender!,
        fitnessLevel: _fitnessLevel!,
      );
      if (me.dailyStepGoal == 8000) {
        await ref.read(authServiceProvider).updateProfile(
          me.userId,
          {'daily_step_goal': rec.target},
        );
      }

      ref.invalidate(currentUserProvider);
      if (mounted) Navigator.of(context).pop();
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
    return DraggableScrollableSheet(
      initialChildSize: 0.95,
      minChildSize: 0.85,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        // PopScope blocks Android back / swipe-down dismiss so the user
        // can't escape mid-flow.
        child: PopScope(
          canPop: false,
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
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _currentPage = i),
                    children: [
                      _DobStep(
                        value: _dateOfBirth,
                        minAge: _minAge,
                        onPicked: (d) => setState(() => _dateOfBirth = d),
                      ),
                      _GenderStep(
                        value: _gender,
                        onPicked: (g) => setState(() => _gender = g),
                      ),
                      _FitnessStep(
                        value: _fitnessLevel,
                        onPicked: (f) => setState(() => _fitnessLevel = f),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: AppColors.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: _PrimaryPillButton(
                    label: _currentPage == _totalSteps - 1
                        ? 'Save'
                        : 'Continue',
                    enabled: _canContinue && !_saving,
                    loading: _saving,
                    onPressed: _next,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Steps — DOB, Gender, Fitness (same visual language as onboarding)
// =============================================================================

class _DobStep extends StatelessWidget {
  final DateTime? value;
  final int minAge;
  final ValueChanged<DateTime> onPicked;
  const _DobStep({
    required this.value,
    required this.minAge,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    final formatted = value == null
        ? 'Tap to choose'
        : '${value!.day} ${_monthName(value!.month)} ${value!.year}';
    return _StepShell(
      title: 'Complete your\nprofile',
      subtitle:
          'A few new fields power StepBattle\'s personalized step target. Takes 30 seconds.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Birthday',
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _openWheelPicker(context),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
              decoration: BoxDecoration(
                color: _Tokens.cardFill,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                formatted,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: value == null
                      ? AppColors.onSurfaceVariant
                      : Colors.white,
                ),
              ),
            ),
          ),
        ],
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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

class _GenderStep extends StatelessWidget {
  final Gender? value;
  final ValueChanged<Gender> onPicked;
  const _GenderStep({required this.value, required this.onPicked});

  @override
  Widget build(BuildContext context) {
    return _StepShell(
      title: 'What\'s your\ngender?',
      subtitle:
          'We\'ll use this to determine which leaderboards you appear on.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final g in Gender.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _OptionCard(
                title: _label(g),
                selected: value == g,
                onTap: () => onPicked(g),
              ),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Your gender will not appear on your profile.',
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _label(Gender g) => switch (g) {
        Gender.man => 'Man',
        Gender.woman => 'Woman',
        Gender.nonBinary => 'Non-binary',
        Gender.preferNotToSay => 'Prefer not to say',
      };
}

class _FitnessStep extends StatelessWidget {
  final FitnessLevel? value;
  final ValueChanged<FitnessLevel> onPicked;
  const _FitnessStep({required this.value, required this.onPicked});

  @override
  Widget build(BuildContext context) {
    return _StepShell(
      title: 'Where are you in your\nfitness journey?',
      subtitle:
          'People of all experience levels use StepBattle, from total beginners to professional athletes.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in FitnessLevel.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _OptionCard(
                title: _label(f),
                description: _sublabel(f),
                selected: value == f,
                onTap: () => onPicked(f),
              ),
            ),
        ],
      ),
    );
  }

  static String _label(FitnessLevel f) => switch (f) {
        FitnessLevel.beginner => 'Beginner',
        FitnessLevel.intermediate => 'Intermediate',
        FitnessLevel.advanced => 'Advanced',
        FitnessLevel.pro => 'Pro',
      };

  static String _sublabel(FitnessLevel f) => switch (f) {
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
// Shared scaffolding (duplicated from onboarding so this file stands alone)
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

class _StepShell extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget body;
  const _StepShell({
    required this.title,
    required this.subtitle,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w900,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 15,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          body,
        ],
      ),
    );
  }
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
        // Force full width so the list stacks at one consistent
        // width regardless of label length.
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
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
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 6),
              Text(
                description!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
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
      height: 56,
      width: double.infinity,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: enabled && !loading ? onPressed : null,
          borderRadius: BorderRadius.circular(28),
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

/// Catch-up sheet trigger. Idempotent per session.
bool _sheetShown = false;
void maybeShowCompleteProfileSheet(BuildContext context, UserModel user) {
  if (_sheetShown) return;
  if (user.hasCompletedSurvey) return;
  _sheetShown = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CompleteProfileSheet(),
    );
  });
}
