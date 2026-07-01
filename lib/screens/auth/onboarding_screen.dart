import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/colors.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/goal_formula.dart';

/// Mandatory, no-skip onboarding (8 steps).
///
/// Design follows the user-supplied Strava-inspired reference set:
///   • Full-screen black background, no logo, no progress bar.
///   • Each step: large bold title + muted subtitle + body widget
///     (text field, picker, option cards, or info block).
///   • Brand-purple [PrimaryButton] pill at the bottom, disabled until
///     the step's validity rule is met.
///
/// Steps:
///   1. Display name (3–20 chars)
///   2. Date of birth (wheel picker dialog, min age 13)
///   3. Gender
///   4. Fitness level
///   5. Activity recognition permission
///   6. Location permission (precise foreground)
///   7. Step-source confirmation (info-only)
///   8. Goal pick (clamped to [GoalFormula] range)
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  /// Minimum age (COPPA / DPDP Act safety).
  static const int _minAge = 13;
  static const int _totalSteps = 8;

  final _pageController = PageController();
  int _currentPage = 0;

  // Step 1 — name
  final _usernameController = TextEditingController();
  String? _usernameError;

  // Step 2 — DOB
  DateTime? _dateOfBirth;

  // Step 3 — gender
  Gender? _gender;

  // Step 4 — fitness
  FitnessLevel? _fitnessLevel;

  // Step 5 / 6 — permission grants. Tracks whether the user has been
  // prompted; we don't BLOCK on denial (the app degrades gracefully and
  // the Home banner re-prompts). The button becomes "Continue" once
  // either Allow or system-skip has been observed.
  bool _activityRecognitionPrompted = false;
  bool _activityRecognitionGranted = false;
  bool _locationPrompted = false;
  bool _locationGranted = false;

  // Step 8 — goal value (seeded from the formula on first arrival).
  int? _dailyGoal;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Keep the username field in sync with setState() so the Continue
    // button enables/disables as the user types.
    _usernameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pageController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  bool get _canContinue {
    switch (_currentPage) {
      case 0:
        final name = _usernameController.text.trim();
        return name.length >= 3 && name.length <= 20;
      case 1:
        return _dateOfBirth != null && _ageFromDob(_dateOfBirth!) >= _minAge;
      case 2:
        return _gender != null;
      case 3:
        return _fitnessLevel != null;
      case 4:
        return _activityRecognitionPrompted;
      case 5:
        return _locationPrompted;
      case 6:
        return true; // info-only
      case 7:
        return _dailyGoal != null;
    }
    return false;
  }

  void _nextPage() {
    if (!_canContinue) return;
    if (_currentPage == 0) {
      final name = _usernameController.text.trim();
      if (name.length < 3 || name.length > 20) {
        setState(() => _usernameError = 'Name must be 3–20 characters');
        return;
      }
      setState(() => _usernameError = null);
    }
    // Seed goal from formula on first arrival at the goal step.
    if (_currentPage == 6) {
      _dailyGoal ??= _recommended()?.target ?? GoalFormula.fallback.target;
    }
    if (_currentPage < _totalSteps - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _completeOnboarding();
    }
  }

  StepGoalRecommendation? _recommended() {
    final dob = _dateOfBirth;
    final g = _gender;
    final f = _fitnessLevel;
    if (dob == null || g == null || f == null) return null;
    return GoalFormula.compute(
      age: _ageFromDob(dob),
      gender: g,
      fitnessLevel: f,
    );
  }

  int _ageFromDob(DateTime dob) {
    final now = DateTime.now();
    var years = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      years--;
    }
    return years;
  }

  Future<void> _completeOnboarding() async {
    setState(() => _submitting = true);
    try {
      final user = Supabase.instance.client.auth.currentUser!;
      await ref.read(authServiceProvider).completeOnboarding(
            userId: user.id,
            displayName: _usernameController.text.trim(),
            dailyStepGoal: _dailyGoal!,
            dateOfBirth: _dateOfBirth!,
            gender: _gender!.wire,
            fitnessLevel: _fitnessLevel!.wire,
            avatarUrl: user.userMetadata?['avatar_url'] as String?,
          );
      if (mounted) {
        ref.invalidate(hasCompletedOnboardingProvider);
        ref.invalidate(currentUserProvider);
        context.go('/home');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong. Please retry.')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _usernameController.text.trim();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _StepName(
                    controller: _usernameController,
                    errorText: _usernameError,
                  ),
                  _StepDob(
                    name: name,
                    value: _dateOfBirth,
                    minAge: _minAge,
                    onPicked: (d) => setState(() => _dateOfBirth = d),
                  ),
                  _StepGender(
                    value: _gender,
                    onPicked: (g) => setState(() => _gender = g),
                  ),
                  _StepFitness(
                    value: _fitnessLevel,
                    onPicked: (f) => setState(() => _fitnessLevel = f),
                  ),
                  _StepPermission(
                    icon: Icons.directions_walk,
                    title: 'Allow activity tracking',
                    body:
                        'StepBattle reads your phone\'s step counter to track your daily activity. We never share this data.',
                    granted: _activityRecognitionGranted,
                    prompted: _activityRecognitionPrompted,
                    onRequest: () async {
                      final status =
                          await Permission.activityRecognition.request();
                      setState(() {
                        _activityRecognitionPrompted = true;
                        _activityRecognitionGranted = status.isGranted;
                      });
                    },
                  ),
                  _StepPermission(
                    icon: Icons.location_on_outlined,
                    title: 'Allow precise location access',
                    body:
                        'Used during Track sessions to draw your route and to power district / state / country leaderboards.',
                    granted: _locationGranted,
                    prompted: _locationPrompted,
                    onRequest: () async {
                      final status =
                          await Permission.locationWhenInUse.request();
                      setState(() {
                        _locationPrompted = true;
                        _locationGranted = status.isGranted;
                      });
                    },
                  ),
                  const _StepSourceInfo(),
                  _StepGoal(
                    recommendation: _recommended() ?? GoalFormula.fallback,
                    value: _dailyGoal,
                    onChanged: (g) => setState(() => _dailyGoal = g),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: _PrimaryPillButton(
                label: _currentPage == _totalSteps - 1
                    ? 'Finish'
                    : 'Continue',
                enabled: _canContinue && !_submitting,
                loading: _submitting,
                onPressed: _nextPage,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Step 1 — Display name
// =============================================================================
class _StepName extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;
  const _StepName({required this.controller, required this.errorText});

  @override
  Widget build(BuildContext context) {
    return _StepShell(
      title: 'What should we\ncall you?',
      subtitle:
          'This is the name your friends, opponents, and clan will see.',
      body: TextField(
        controller: controller,
        textCapitalization: TextCapitalization.words,
        maxLength: 20,
        cursorColor: AppColors.primary,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        decoration: InputDecoration(
          labelText: 'Display name',
          labelStyle: TextStyle(color: AppColors.onSurfaceVariant),
          hintText: 'e.g. Prashanth',
          hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
          errorText: errorText,
          counterText: '',
          filled: true,
          fillColor: _OnboardingTokens.cardFill,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: AppColors.primary, width: 2),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Step 2 — Date of birth (wheel picker dialog)
// =============================================================================
class _StepDob extends StatelessWidget {
  final String name;
  final DateTime? value;
  final int minAge;
  final ValueChanged<DateTime> onPicked;
  const _StepDob({
    required this.name,
    required this.value,
    required this.minAge,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    final formatted = value == null
        ? 'Tap to choose'
        : '${value!.day} ${_monthName(value!.month)} ${value!.year}';
    final greeting = name.isEmpty ? 'Welcome!' : 'Welcome, $name!';

    return _StepShell(
      // Two-line title with the personalised greeting on the first line
      // and the question on the second.
      title: '$greeting\nWhen\'s your birthday?',
      subtitle:
          'We\'ll use this for performance analysis, filtering leaderboards, and to keep younger users safe.',
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
                color: _OnboardingTokens.cardFill,
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
          if (value != null) ...[
            const SizedBox(height: 10),
            Text(
              'You\'re ${_ageFromDob(value!)} — looks good.',
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
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
        backgroundColor: _OnboardingTokens.dialogFill,
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

  int _ageFromDob(DateTime dob) {
    final now = DateTime.now();
    var y = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      y--;
    }
    return y;
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

// =============================================================================
// Step 3 — Gender
// =============================================================================
class _StepGender extends StatelessWidget {
  final Gender? value;
  final ValueChanged<Gender> onPicked;
  const _StepGender({required this.value, required this.onPicked});

  @override
  Widget build(BuildContext context) {
    return _StepShell(
      title: 'What\'s your\ngender?',
      subtitle:
          'We\'ll use this to determine which leaderboards you appear on.',
      body: Column(
        // Stretch so every option card spans the full available width;
        // without this the Column defaults to centre alignment and the
        // cards stagger by label length.
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

// =============================================================================
// Step 4 — Fitness level (option cards with descriptions)
// =============================================================================
class _StepFitness extends StatelessWidget {
  final FitnessLevel? value;
  final ValueChanged<FitnessLevel> onPicked;
  const _StepFitness({required this.value, required this.onPicked});

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
// Step 5 / 6 — Permission asks (big icon + title + body + Allow CTA)
// =============================================================================
class _StepPermission extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final bool granted;
  final bool prompted;
  final VoidCallback onRequest;

  const _StepPermission({
    required this.icon,
    required this.title,
    required this.body,
    required this.granted,
    required this.prompted,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          // Big icon centered in a soft circle backdrop.
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: AppColors.primary, size: 44),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 15,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          // Allow / Granted / Ask again button.
          _SecondaryPillButton(
            label: granted
                ? 'Granted'
                : prompted
                    ? 'Ask again'
                    : 'Allow',
            disabled: granted,
            onPressed: onRequest,
          ),
          if (prompted && !granted) ...[
            const SizedBox(height: 12),
            Text(
              'Permission not granted — you can re-enable it in Settings later, or continue and re-prompt from Home.',
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Step 7 — Source confirmation (info card)
// =============================================================================
class _StepSourceInfo extends StatelessWidget {
  const _StepSourceInfo();

  @override
  Widget build(BuildContext context) {
    return _StepShell(
      title: 'How we track\nyour steps',
      subtitle:
          'StepBattle uses your phone\'s built-in step counter (and Health Connect, if installed). No wearable needed.',
      body: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: _OnboardingTokens.cardFill,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SourceRow(
              icon: Icons.smartphone,
              label: 'Phone pedometer',
              body: 'The always-on baseline. Works even with the app closed.',
            ),
            const SizedBox(height: 16),
            const _SourceRow(
              icon: Icons.favorite_outline,
              label: 'Health Connect / Google Fit',
              body:
                  'Pulled in automatically if installed — usually more accurate than the raw pedometer.',
            ),
            const SizedBox(height: 16),
            Text(
              'You can connect / disconnect sources later from Profile → Step Sources.',
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String body;
  const _SourceRow({
    required this.icon,
    required this.label,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.primary, size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: TextStyle(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Step 8 — Goal pick
// =============================================================================
class _StepGoal extends StatelessWidget {
  final StepGoalRecommendation recommendation;
  final int? value;
  final ValueChanged<int> onChanged;

  const _StepGoal({
    required this.recommendation,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = value ?? recommendation.target;
    return _StepShell(
      title: 'Your daily\nstep target',
      subtitle:
          'Based on your age, gender, and fitness level. You can change it later — we\'ll keep it within your personalized range.',
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: _OnboardingTokens.cardFill,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                Text(
                  _fmt(current),
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 56,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  'STEPS PER DAY',
                  style: TextStyle(
                    color: AppColors.primary.withValues(alpha: 0.6),
                    fontSize: 11,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${GoalFormula.stepsToKm(current).toStringAsFixed(1)} km',
                  style: TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.outlined(
                onPressed: current > recommendation.min
                    ? () => onChanged(
                          (current - 500)
                              .clamp(recommendation.min, recommendation.max),
                        )
                    : null,
                icon: const Icon(Icons.remove),
              ),
              const SizedBox(width: 16),
              IconButton.outlined(
                onPressed: current < recommendation.max
                    ? () => onChanged(
                          (current + 500)
                              .clamp(recommendation.min, recommendation.max),
                        )
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Range: ${_fmt(recommendation.min)} – ${_fmt(recommendation.max)} · Suggested ${_fmt(recommendation.target)}',
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
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
}

// =============================================================================
// Shared scaffolding
// =============================================================================

/// Visual constants reused across every onboarding step so the design is
/// consistent and tweakable from one place. Flip per brightness so the
/// onboarding flow reads on light mode too — dark mode keeps the exact
/// original hexes.
class _OnboardingTokens {
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

/// Full-width selectable card used by the Gender + Fitness steps.
/// • Title-only when [description] is null.
/// • Selected state: brand-purple border + slightly lifted fill.
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
        // Force the card to fill the parent's horizontal extent so every
        // option in the list lines up at the same width regardless of
        // its label length. Without this, AnimatedContainer would shrink
        // to its intrinsic (text-width) size and the buttons stack at
        // jagged widths.
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        decoration: BoxDecoration(
          color: selected
              ? _OnboardingTokens.cardSelectedFill
              : _OnboardingTokens.cardFill,
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

/// Brand-purple filled pill, full-width — used as the bottom Continue
/// CTA. Disabled state is a muted darker purple matching the Strava
/// reference's grey-orange treatment.
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
    final fg = enabled
        ? Colors.white
        : AppColors.onSurface.withValues(alpha: 0.45);
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

/// Outlined (brand-purple stroke) pill used inside permission steps for
/// the "Allow" CTA. Stays inline with the step content so the bottom
/// "Continue" stays the primary action.
class _SecondaryPillButton extends StatelessWidget {
  final String label;
  final bool disabled;
  final VoidCallback onPressed;
  const _SecondaryPillButton({
    required this.label,
    required this.onPressed,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      width: double.infinity,
      child: OutlinedButton(
        onPressed: disabled ? null : onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: disabled
                ? AppColors.primary.withValues(alpha: 0.35)
                : AppColors.primary,
            width: 1.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
          foregroundColor: AppColors.primary,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
