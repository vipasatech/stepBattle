import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/colors.dart';
import '../../models/avatar.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/goal_formula.dart';
import '../../services/observability_service.dart';

/// 8-step onboarding — auto-skips steps whose answers are already on
/// file or whose permissions are already granted, so returning users
/// only see the pages they still need to fill.
///
/// Prefill sources:
///   • `currentUserProvider` → seeds display name, DOB, gender,
///     fitness level, and daily goal from the profile row (Google /
///     Apple sign-in often lands the display name pre-filled).
///   • `Permission.activityRecognition.status` and
///     `Permission.locationWhenInUse.status` — if already granted on
///     the device, the corresponding step is marked satisfied and
///     skipped during forward navigation.
///
/// Landing behaviour:
///   • Everything satisfied → runs `completeOnboarding` immediately
///     and routes to `/home` without ever painting a step page.
///   • Some fields missing → `initialPage` is set to the first
///     unsatisfied step so the user starts wherever they actually
///     have work to do.
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
///   2. Preferred name (optional casual name — leave blank to use
///      display name)
///   3. Date of birth (wheel picker dialog, min age 13)
///   4. Gender
///   5. Fitness level
///   6. Activity recognition permission
///   7. Location permission (precise foreground)
///   8. Step-source confirmation (info-only)
///   9. Goal pick (clamped to [GoalFormula] range)
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  /// Minimum age (COPPA / DPDP Act safety).
  static const int _minAge = 13;
  static const int _totalSteps = 9;
  /// Index of the info-only "How we track your steps" page. Kept in
  /// one place so the skip logic doesn't drift when steps are
  /// reordered.
  static const int _infoStepIndex = 7;

  /// Late so we can honour a computed `initialPage` after the prefill
  /// resolves. Constructed in [_applyPrefill], not in the field
  /// initialiser, and then handed to the [PageView] once we know where
  /// to land.
  PageController? _pageController;
  int _currentPage = 0;

  /// True while `_applyPrefill` is running (blocks the initial paint
  /// so we don't briefly show step 1 before jumping past it, and so
  /// we don't paint anything at all when the user is going to be
  /// silently sent to /home).
  bool _prefilling = true;

  // Step 0 — display name
  final _usernameController = TextEditingController();
  String? _usernameError;

  // Step 1 — preferred name. Nullable-until-answered: `null` means the
  // user has not yet been through this step; a non-null value
  // (including empty string) means they saw the step and either
  // typed a nickname or tapped Continue to accept "call me by my
  // display name". `hasCompletedOnboardingProvider` uses this
  // null-vs-non-null distinction to decide whether an existing user
  // needs to be routed back through onboarding.
  final _preferredNameController = TextEditingController();
  /// True once the user has landed on the preferred-name step at
  /// least once — used to satisfy `_stepIsSatisfied(1)` when they
  /// hit Continue on an empty field (which is a valid answer).
  bool _preferredNamePrompted = false;

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
    // Prefill from profile + permission status, then decide where to
    // land. Kicked from a post-frame callback so the widget is
    // mounted before we call setState / navigate.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyPrefill());
  }

  @override
  void dispose() {
    _pageController?.dispose();
    _usernameController.dispose();
    _preferredNameController.dispose();
    super.dispose();
  }

  /// Read whatever the profile already has + which permissions are
  /// already granted, seed local state, then either silently
  /// completeOnboarding (everything set) or land the PageView on the
  /// first unanswered step.
  Future<void> _applyPrefill() async {
    // --- profile fields ------------------------------------------
    try {
      final profile = await ref.read(currentUserProvider.future);
      if (profile != null) {
        if (profile.displayName.isNotEmpty &&
            _usernameController.text.isEmpty) {
          _usernameController.text = profile.displayName;
        }
        // Preferred name — populate the text field with whatever's
        // on file. A non-null value means the user has already
        // provided a nickname (or a previous session persisted
        // one), so mark the step prompted. If it's null but the
        // session flag says we've already asked in this login
        // session, also mark it prompted so re-mounting the
        // Onboarding screen doesn't re-show the step.
        if (profile.preferredName != null) {
          if (_preferredNameController.text.isEmpty) {
            _preferredNameController.text = profile.preferredName!;
          }
          _preferredNamePrompted = true;
        } else if (ref.read(preferredNameAskedThisSessionProvider)) {
          _preferredNamePrompted = true;
        }
        _dateOfBirth ??= profile.dateOfBirth;
        _gender ??= profile.gender;
        _fitnessLevel ??= profile.fitnessLevel;
        // Only accept the goal if it's a real user-set value — the
        // model defaults to 8000 for fresh rows, which we don't want
        // to treat as "already answered".
        if (_dailyGoal == null &&
            profile.dailyStepGoal > 0 &&
            profile.dailyStepGoal != 8000) {
          _dailyGoal = profile.dailyStepGoal;
        }
      }
    } catch (_) {
      // Prefill is best-effort. Any failure just means the user sees
      // the full onboarding flow — safer than blocking on it.
    }

    // --- permission grants ---------------------------------------
    try {
      final actGranted = await Permission.activityRecognition.isGranted;
      final locGranted = await Permission.locationWhenInUse.isGranted;
      // Marking `prompted` alongside `granted` lets the existing
      // `_canContinue` gating treat the step as satisfied, and the
      // permission body's button renders as "Granted" (disabled).
      _activityRecognitionGranted = actGranted;
      _activityRecognitionPrompted = actGranted;
      _locationGranted = locGranted;
      _locationPrompted = locGranted;
    } catch (_) {
      // As above — permission_handler can throw on some platforms
      // (desktop). If we can't read the status, treat as "not
      // granted" so the user sees the prompt.
    }

    if (!mounted) return;

    // --- decide landing page -------------------------------------
    final firstUnanswered = _firstUnansweredForLanding();
    if (firstUnanswered == null) {
      // Everything's already set + all perms granted → silent skip.
      // We call completeOnboarding directly to make sure any
      // remaining fields (e.g., a goal seeded from the formula)
      // land in the profile row and hasOnboarded flips to true.
      _dailyGoal ??=
          _recommended()?.target ?? GoalFormula.fallback.target;
      _completeOnboarding();
      return;
    }
    setState(() {
      _pageController = PageController(initialPage: firstUnanswered);
      _currentPage = firstUnanswered;
      _prefilling = false;
    });
  }

  /// Whether step [i]'s payload is already provided.
  ///
  /// Step [_infoStepIndex] (info-only "how we track your steps") has
  /// no payload and is treated as *unsatisfiable* — the walk never
  /// skips it on the way forward. The landing calc below strips it
  /// out separately so a fully-set-up returning user never sees it.
  bool _stepIsSatisfied(int i) {
    switch (i) {
      case 0:
        final name = _usernameController.text.trim();
        return name.length >= 3 && name.length <= 20;
      case 1:
        // Preferred name is satisfied once we've prompted the user
        // for it (even if they left it blank). Prefill sets the
        // prompted flag if the profile already has a non-null
        // preferred_name value.
        return _preferredNamePrompted;
      case 2:
        return _dateOfBirth != null &&
            _ageFromDob(_dateOfBirth!) >= _minAge;
      case 3:
        return _gender != null;
      case 4:
        return _fitnessLevel != null;
      case 5:
        return _activityRecognitionGranted;
      case 6:
        return _locationGranted;
      case 7:
        return false; // info page — always show in normal walk
      case 8:
        return _dailyGoal != null;
      default:
        return true;
    }
  }

  /// First step that still needs the user's attention, for the
  /// landing decision.
  ///
  /// Behaviour:
  ///   • **Silent full-skip**: if every field is resolved and every
  ///     permission granted, return null so the caller runs
  ///     `completeOnboarding` directly and the user goes straight to
  ///     `/home` without seeing any step.
  ///   • **Returning user** (has at least one of DOB / gender /
  ///     fitness set): skip to the first unresolved step. Their
  ///     display name was already collected before, so we don't
  ///     re-ask for it — the common case is an existing user
  ///     bounced back by `hasCompletedOnboardingProvider` because
  ///     `preferred_name` is null, and we want them to land
  ///     directly on the preferred-name step.
  ///   • **First-time user** (all survey fields null): always land
  ///     on step 0 (name) — even when it's prefilled from OAuth
  ///     metadata. Silently skipping a prefilled name left users
  ///     confused ("the survey didn't ask for my name"). The
  ///     prefill still buys them a one-tap Continue.
  ///
  /// Info-only step [_infoStepIndex] is stripped from the scan so
  /// returning users never open onboarding on the info page.
  int? _firstUnansweredForLanding() {
    var everythingSatisfied = true;
    for (int i = 0; i < _totalSteps; i++) {
      if (i == _infoStepIndex) continue;
      if (!_stepIsSatisfied(i)) {
        everythingSatisfied = false;
        break;
      }
    }
    if (everythingSatisfied) return null;

    // Returning user? Any prior survey answer is the signal — the
    // fields don't get set to non-null by the auth trigger, only by
    // a previous completeOnboarding call.
    final hasPriorSurvey = _dateOfBirth != null ||
        _gender != null ||
        _fitnessLevel != null;
    if (hasPriorSurvey) {
      for (int i = 0; i < _totalSteps; i++) {
        if (i == _infoStepIndex) continue;
        if (!_stepIsSatisfied(i)) return i;
      }
      return null;
    }

    // First-time user: force step 0 so they see / confirm the name
    // even when display_name is prefilled from OAuth metadata.
    return 0;
  }

  /// Next relevant step after [after] during forward navigation.
  /// Skips any step whose payload is already satisfied. Returns null
  /// when there's nothing left, which the caller treats as
  /// "onboarding complete".
  int? _nextRelevantStep(int after) {
    for (int i = after + 1; i < _totalSteps; i++) {
      if (_stepIsSatisfied(i)) continue;
      return i;
    }
    return null;
  }

  bool get _canContinue {
    switch (_currentPage) {
      case 0:
        final name = _usernameController.text.trim();
        return name.length >= 3 && name.length <= 20;
      case 1:
        // Preferred name — always allowed to advance (empty means "no
        // nickname, use display name").
        return true;
      case 2:
        return _dateOfBirth != null && _ageFromDob(_dateOfBirth!) >= _minAge;
      case 3:
        return _gender != null;
      case 4:
        return _fitnessLevel != null;
      case 5:
        return _activityRecognitionPrompted;
      case 6:
        return _locationPrompted;
      case 7:
        return true; // info-only
      case 8:
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
    // Mark the preferred-name step "seen" so _stepIsSatisfied(1)
    // returns true from here on (until the user gets bounced back
    // through onboarding for some other reason).
    if (_currentPage == 1) {
      _preferredNamePrompted = true;
    }
    // Seed goal from formula on first arrival at the info page (step
    // before goal). By the time the user reaches step _goalStepIndex
    // we want _dailyGoal to already have a value so the goal card
    // renders with the recommendation.
    if (_currentPage == _infoStepIndex) {
      _dailyGoal ??= _recommended()?.target ?? GoalFormula.fallback.target;
    }
    // Skip over any subsequent steps that are already satisfied by
    // prefill / prior grants, instead of the mechanical +1. If
    // nothing's left, we're done.
    final next = _nextRelevantStep(_currentPage);
    if (next == null) {
      _completeOnboarding();
      return;
    }
    _pageController?.animateToPage(
      next,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
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
      final displayName = _usernameController.text.trim();
      final preferredInput = _preferredNameController.text.trim();
      // NULL preserves the "user hasn't chosen a nickname" state so
      // we can re-prompt on the next login. The DB CHECK
      // (char_length BETWEEN 1 AND 40) is skipped when the value is
      // NULL, so this passes.
      final String? preferredName = preferredInput.isEmpty ? null : preferredInput;
      // Seed the user's battle-ground runner avatar from their
      // demographics + fitness level. Runs once at onboarding; the
      // user can override any time via the avatar-picker sheet.
      final defaultAvatar = Avatar.defaultForUser(
        gender: _gender,
        fitnessLevel: _fitnessLevel,
        ageYears: _ageFromDob(_dateOfBirth!),
      );
      await ref.read(authServiceProvider).completeOnboarding(
            userId: user.id,
            displayName: displayName,
            preferredName: preferredName,
            dailyStepGoal: _dailyGoal!,
            dateOfBirth: _dateOfBirth!,
            gender: _gender!.wire,
            fitnessLevel: _fitnessLevel!.wire,
            avatarUrl: user.userMetadata?['avatar_url'] as String?,
            battleAvatarId: defaultAvatar.id,
          );
      // Onboarding-complete funnel event — properties intentionally
      // omit anything user-identifying. Gender + fitness level are
      // low-cardinality demographic cohorts we already store server-side
      // via [completeOnboarding]; sending them here lets us slice
      // retention by cohort in the PostHog dashboard.
      ObservabilityService.trackEvent('onboarding_complete', properties: {
        'gender': _gender!.wire,
        'fitness_level': _fitnessLevel!.wire,
        'daily_step_goal': _dailyGoal!,
        'age_years': _ageFromDob(_dateOfBirth!),
      });
      if (mounted) {
        // Flip the session flag so the redirect gate stops
        // considering this user "unonboarded" over a null
        // preferred_name — otherwise we'd loop right back to
        // /onboarding. Next login (fresh Riverpod scope, new auth
        // id) resets the flag and we ask again.
        ref.read(preferredNameAskedThisSessionProvider.notifier).state = true;
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
    // While prefill is in flight (or on the way to a silent full-
    // skip) show a plain background — no logo, no spinner, no half-
    // painted step. This is invisible to the user because prefill
    // resolves in the same frame the splash screen was already
    // showing.
    if (_prefilling || _pageController == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: const SizedBox.shrink(),
      );
    }
    final name = _usernameController.text.trim();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Top-left back button — goes to the previous step (or, on
            // the first step, treats back as "abandon onboarding": sign
            // out and land on /welcome. Plain `context.go('/welcome')`
            // isn't enough because the router redirect gate sees the
            // still-authenticated session and immediately bounces the
            // user back to /onboarding — so signing out first is what
            // actually clears the guard.
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
                onPressed: () async {
                  if (_currentPage > 0) {
                    _pageController?.animateToPage(
                      _currentPage - 1,
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                    );
                    return;
                  }
                  if (context.canPop()) {
                    context.pop();
                    return;
                  }
                  // First step, nothing to pop — abandon the onboarding
                  // altogether. Sign out then route to /welcome.
                  try {
                    await ref.read(authServiceProvider).signOut();
                  } catch (_) {
                    // Best-effort — if signOut fails we still try to
                    // navigate; the router's redirect gate will send us
                    // wherever the resulting auth state warrants.
                  }
                  // Wait for authStateProvider to reflect the signed-
                  // out state so the redirect gate doesn't bounce us
                  // straight back to /onboarding on stale auth.
                  //
                  // Guard the poll on `mounted` FIRST every iteration
                  // — the signOut() above triggers the router redirect
                  // which may unmount THIS widget before the auth
                  // state fully drains, at which point `ref.read` on
                  // a disposed ConsumerStatefulElement throws
                  // "Cannot use ref after the widget was disposed."
                  // Bail out cleanly instead — the redirect gate has
                  // already taken over routing.
                  final deadline =
                      DateTime.now().add(const Duration(seconds: 2));
                  while (DateTime.now().isBefore(deadline)) {
                    if (!mounted) return;
                    if (ref.read(authStateProvider).valueOrNull == null) {
                      break;
                    }
                    await Future.delayed(const Duration(milliseconds: 25));
                  }
                  if (!context.mounted) return;
                  context.go('/welcome');
                },
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController!,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _StepName(
                    controller: _usernameController,
                    errorText: _usernameError,
                  ),
                  _StepPreferredName(
                    controller: _preferredNameController,
                    displayName: name,
                    onChanged: () => setState(() {}),
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Field label sits ABOVE the input (matches the DOB step).
          // Previously the label lived inside the InputDecoration as
          // `labelText`, but with no border to anchor to it floated
          // right on top of the typed text, causing the "Display
          // name" caption and the actual name to overlap.
          Text(
            'Display name',
            style: TextStyle(
              color: AppColors.onSurface,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            textCapitalization: TextCapitalization.words,
            maxLength: 20,
            cursorColor: AppColors.primary,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.onSurface,
            ),
            decoration: InputDecoration(
              hintText: 'e.g. Prashanth',
              hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
              errorText: errorText,
              counterText: '',
              filled: true,
              fillColor: _OnboardingTokens.cardFill,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: AppColors.primary, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Step 2 — Preferred name (optional casual name)
// =============================================================================
class _StepPreferredName extends StatelessWidget {
  final TextEditingController controller;

  /// The display name the user just entered on the previous step —
  /// shown as the "otherwise we'll use…" fallback text so the user
  /// knows exactly what leaving this blank does.
  final String displayName;

  /// Called on every keystroke so the shell can rebuild the Continue
  /// button state (unused for gating — preferred name is always
  /// allowed to advance — but harmless to notify).
  final VoidCallback onChanged;

  const _StepPreferredName({
    required this.controller,
    required this.displayName,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = displayName.trim().isEmpty ? 'your full name' : displayName;
    return _StepShell(
      title: 'What should\nwe call you?',
      subtitle:
          'A shorter, casual name that friends, opponents, and clan members will see. Leave blank to use $fallback.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label ABOVE the field — same fix as the display-name and
          // DOB steps. `labelText` inside a borderless InputDecoration
          // ends up floating on top of the typed value.
          Text(
            'Preferred name (optional)',
            style: TextStyle(
              color: AppColors.onSurface,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            textCapitalization: TextCapitalization.words,
            maxLength: 40,
            cursorColor: AppColors.primary,
            onChanged: (_) => onChanged(),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.onSurface,
            ),
            decoration: InputDecoration(
              hintText: 'e.g. Prash',
              hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
              counterText: '',
              filled: true,
              fillColor: _OnboardingTokens.cardFill,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: AppColors.primary, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Step 3 — Date of birth (wheel picker dialog)
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
        ? ''
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
          // Field label.
          Text(
            'Birthday',
            style: TextStyle(
              color: AppColors.onSurface,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          // Outlined tap target — transparent fill + subtle border,
          // no placeholder text so the empty state matches the
          // reference exactly. Once a date is picked the formatted
          // string appears inside.
          GestureDetector(
            onTap: () => _openWheelPicker(context),
            child: Container(
              height: 60,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.onSurface.withValues(alpha: 0.35),
                  width: 1.2,
                ),
              ),
              child: Text(
                formatted,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Static privacy caption — matches the reference. We used
          // to show a computed "You're 24 — looks good." helper
          // here; dropped in favour of the privacy note so first-
          // paint spacing matches whether a date is picked or not.
          Text(
            'Your birthday or age will not appear on your profile.',
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 13,
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
        backgroundColor: _OnboardingTokens.dialogFill,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 22, 0, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Choose Date of Birth',
                style: TextStyle(
                  color: AppColors.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                // Slightly taller than a default picker so the row
                // density matches the Strava reference the user
                // shared: ~7 rows visible with the selected row
                // clearly centred and the outer rows fading out.
                height: 240,
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    brightness: AppColors.isDark
                        ? Brightness.dark
                        : Brightness.light,
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        color: AppColors.onSurface,
                        fontSize: 21,
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
                        child: SizedBox(
                          height: 52,
                          child: Center(
                            child: Text(
                              'Cancel',
                              style: TextStyle(
                                color: AppColors.onSurface,
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
      title: 'What\'s your gender?',
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
            style: TextStyle(
              color: AppColors.onSurface,
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
                style: TextStyle(
                  color: AppColors.onSurface,
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
    // Top-anchored layout with a generous ~48 dp top offset for
    // breathing room from the status bar. Matches the Strava
    // reference the user shared: title just below the safe area,
    // body directly under the caption, everything hugs the top and
    // the primary CTA sits at the bottom via the parent Scaffold.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: AppColors.onSurface,
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
    // Selected card inverts the palette. In dark mode the selected
    // fill is white with black text; in light mode it flips — the
    // selected fill is the app's near-black onSurface with white text.
    // Unselected cards use the theme's card fill with the theme's
    // onSurface text. No visible border either state — the fill
    // contrast alone signals selection.
    final Color selectedFill =
        AppColors.isDark ? Colors.white : AppColors.onSurface;
    final Color selectedText =
        AppColors.isDark ? Colors.black : Colors.white;
    final Color unselectedText = AppColors.onSurface;
    final Color titleColor = selected ? selectedText : unselectedText;
    final Color descriptionColor = selected
        ? selectedText.withValues(alpha: 0.75)
        : unselectedText.withValues(alpha: 0.75);
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
          color: selected ? selectedFill : _OnboardingTokens.cardFill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: titleColor,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 6),
              Text(
                description!,
                style: TextStyle(
                  color: descriptionColor,
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
