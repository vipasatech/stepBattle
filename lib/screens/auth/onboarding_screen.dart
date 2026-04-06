import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../config/constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/step_provider.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/progress_bar.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  // Step 1: username
  final _usernameController = TextEditingController();
  String? _usernameError;

  // Step 2: health connection (placeholder for Phase 3)
  bool _healthConnected = false;

  // Step 3: daily goal
  int _dailyGoal = AppConstants.defaultDailyStepGoal;

  bool _submitting = false;

  @override
  void dispose() {
    _pageController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage == 0) {
      final name = _usernameController.text.trim();
      if (name.length < 3 || name.length > 20) {
        setState(() => _usernameError = 'Username must be 3–20 characters');
        return;
      }
      setState(() => _usernameError = null);
    }
    if (_currentPage < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      _completeOnboarding();
    }
  }

  Future<void> _completeOnboarding() async {
    setState(() => _submitting = true);
    try {
      final user = FirebaseAuth.instance.currentUser!;
      await ref.read(authServiceProvider).createUserDoc(
            uid: user.uid,
            email: user.email ?? '',
            displayName: _usernameController.text.trim(),
            dailyStepGoal: _dailyGoal,
            avatarURL: user.photoURL,
          );
      if (mounted) {
        // Invalidate onboarding check so router redirects to home
        ref.invalidate(hasCompletedOnboardingProvider);
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
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Progress indicator
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: StepProgressBar(
                progress: (_currentPage + 1) / 3,
                height: 6,
                showSpark: false,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Step ${_currentPage + 1} of 3',
                    style: theme.textTheme.labelMedium,
                  ),
                  if (_currentPage == 1)
                    TextButton(
                      onPressed: _nextPage,
                      child: Text('Skip',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: AppColors.primary)),
                    ),
                ],
              ),
            ),

            // Pages
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _UsernameStep(
                    controller: _usernameController,
                    error: _usernameError,
                  ),
                  _HealthConnectStep(
                    connected: _healthConnected,
                    onConnect: () async {
                      final granted = await ref
                          .read(healthServiceProvider)
                          .requestPermissions();
                      if (mounted) setState(() => _healthConnected = granted);
                    },
                  ),
                  _GoalStep(
                    goal: _dailyGoal,
                    onChanged: (v) => setState(() => _dailyGoal = v),
                  ),
                ],
              ),
            ),

            // CTA
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: _submitting ? null : _nextPage,
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(_currentPage == 2
                          ? "Let's Go!"
                          : 'Continue'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Step 1: Choose username
// =============================================================================
class _UsernameStep extends StatelessWidget {
  final TextEditingController controller;
  final String? error;

  const _UsernameStep({required this.controller, this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Text('Choose your\nbattle name',
              style: theme.textTheme.headlineLarge),
          const SizedBox(height: 8),
          Text(
            "This is how other players will see you.",
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: controller,
            style: theme.textTheme.headlineSmall,
            maxLength: 20,
            decoration: InputDecoration(
              hintText: 'e.g. StepKing_99',
              errorText: error,
              counterStyle: theme.textTheme.bodySmall,
              prefixIcon: const Icon(Icons.alternate_email, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Step 2: Connect health app (placeholder — real implementation in Phase 3)
// =============================================================================
class _HealthConnectStep extends StatelessWidget {
  final bool connected;
  final VoidCallback onConnect;

  const _HealthConnectStep(
      {required this.connected, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Text('Connect your\nhealth app', style: theme.textTheme.headlineLarge),
          const SizedBox(height: 8),
          Text(
            'StepBattle reads your steps from your health app so every step counts.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 32),
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.favorite,
                      color: AppColors.primary, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Apple Health / Google Fit',
                          style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        connected ? 'Connected' : 'Tap to connect',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: connected
                              ? AppColors.success
                              : AppColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (connected)
                  const Icon(Icons.check_circle,
                      color: AppColors.success, size: 24)
                else
                  FilledButton(
                    onPressed: onConnect,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: const Text('Connect'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'You can always connect later from your Profile.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.onSurfaceVariant.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Step 3: Set daily step goal
// =============================================================================
class _GoalStep extends StatelessWidget {
  final int goal;
  final ValueChanged<int> onChanged;

  const _GoalStep({required this.goal, required this.onChanged});

  static const _presets = [5000, 8000, 10000, 15000];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Text('Set your daily\nstep goal', style: theme.textTheme.headlineLarge),
          const SizedBox(height: 8),
          Text(
            'You can change this anytime from your profile.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 40),

          // Big number display
          Center(
            child: Text(
              _formatNumber(goal),
              style: theme.textTheme.displayLarge?.copyWith(
                color: AppColors.primary,
                fontSize: 64,
              ),
            ),
          ),
          Center(
            child: Text(
              'STEPS PER DAY',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.primary.withValues(alpha: 0.6),
                letterSpacing: 3,
              ),
            ),
          ),

          const SizedBox(height: 32),

          // Preset chips
          Row(
            children: _presets.map((preset) {
              final isSelected = preset == goal;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: GestureDetector(
                    onTap: () => onChanged(preset),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary.withValues(alpha: 0.2)
                            : AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                        border: isSelected
                            ? Border.all(
                                color: AppColors.primary.withValues(alpha: 0.3))
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          '${preset ~/ 1000}K',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 24),

          // Stepper row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StepperButton(
                icon: Icons.remove,
                onPressed: goal > AppConstants.minStepGoal
                    ? () => onChanged(goal - AppConstants.stepGoalIncrement)
                    : null,
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: 100,
                child: Text(
                  _formatNumber(goal),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              _StepperButton(
                icon: Icons.add,
                onPressed: goal < AppConstants.maxStepGoal
                    ? () => onChanged(goal + AppConstants.stepGoalIncrement)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatNumber(int n) {
    final s = n.toString();
    final result = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) result.write(',');
      result.write(s[i]);
    }
    return result.toString();
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _StepperButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
        child: Icon(
          icon,
          color: onPressed != null
              ? AppColors.onSurface
              : AppColors.onSurfaceVariant.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}
