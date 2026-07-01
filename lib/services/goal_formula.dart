import '../models/user_model.dart';

/// Computed step-goal recommendation for a user.
class StepGoalRecommendation {
  /// The recommended target (always within `[min, max]`).
  final int target;

  /// Lower bound the user is allowed to set their goal to.
  final int min;

  /// Upper bound the user is allowed to set their goal to.
  final int max;

  const StepGoalRecommendation({
    required this.target,
    required this.min,
    required this.max,
  });

  /// Clamps an arbitrary user-chosen goal into the allowed range. Used by
  /// the goal-edit UI to reject out-of-range values.
  int clamp(int candidate) {
    if (candidate < min) return min;
    if (candidate > max) return max;
    return candidate;
  }

  /// True when [candidate] sits inside `[min, max]`.
  bool contains(int candidate) => candidate >= min && candidate <= max;

  @override
  String toString() =>
      'StepGoalRecommendation(target: $target, min: $min, max: $max)';
}

/// Personalized step-goal recommendation engine.
///
/// One source of truth for the step-goal target + range. Inputs are the
/// three onboarding-survey fields (age derived from DOB, gender, fitness
/// level). Used by:
///
///   • The onboarding "pick your goal" step (target = initial value).
///   • The SetGoalSheet (target = the "recommended" chip, [min]/[max] clamp
///     the ±500 stepper).
///   • The Profile screen when fitness level changes (`recompute` →
///     "your recommended target is now X — tap to adopt").
///
/// Formula was signed off in conversation:
///
///   base = 7,500
///
///   age_factor     = ≤30: 1.00 · 31–50: 0.90 · 51–65: 0.75 · 66+: 0.60
///   gender_factor  = man: 1.05 · all others: 1.00
///   fitness_factor = beginner: 0.65 · intermediate: 1.00
///                    advanced: 1.25 · pro: 1.50
///
///   target = round(base × age × gender × fitness, nearest 500)
///   min    = max(target × 0.50, 2,500), rounded to nearest 500
///   max    = round(target × 1.30, nearest 500)
///
/// Examples:
///   25 advanced man        → target 10,000  range 5,000 – 13,000
///   35 intermediate man    → target  7,000  range 3,500 –  9,000
///   55 beginner woman      → target  3,500  range 2,500 –  4,500
///   18 pro man             → target 12,000  range 6,000 – 15,500
class GoalFormula {
  GoalFormula._();

  /// Absolute floor for the minimum allowable goal. Below ~3,000 steps/day
  /// research shows minimal cardiovascular benefit; we don't want the UI
  /// to suggest a target that would mislead a user about their health.
  static const int _minAbsoluteFloor = 2500;

  /// Base step target (WHO general-adult recommendation, softened from
  /// the popular 10,000 to a more achievable 7,500).
  static const int _base = 7500;

  /// Compute the recommendation for a fully-onboarded user. Returns null
  /// if any of the three required fields is missing — the caller should
  /// either funnel the user through the "Complete your profile" sheet or
  /// fall back to a sensible default (8,000 with a generous range).
  static StepGoalRecommendation? forUser(UserModel u) {
    final age = u.age;
    final gender = u.gender;
    final fitness = u.fitnessLevel;
    if (age == null || gender == null || fitness == null) return null;
    return compute(age: age, gender: gender, fitnessLevel: fitness);
  }

  /// Pure computation — no UserModel dependency, so it's testable in
  /// isolation and reusable from the onboarding screen before the profile
  /// row has been persisted.
  static StepGoalRecommendation compute({
    required int age,
    required Gender gender,
    required FitnessLevel fitnessLevel,
  }) {
    final ageFactor = _ageFactor(age);
    final genderFactor = _genderFactor(gender);
    final fitnessFactor = _fitnessFactor(fitnessLevel);

    final rawTarget = _base * ageFactor * genderFactor * fitnessFactor;
    final target = _round500(rawTarget);

    final rawMin = target * 0.50;
    final min = _round500(
      rawMin < _minAbsoluteFloor ? _minAbsoluteFloor.toDouble() : rawMin,
    );

    final max = _round500(target * 1.30);

    return StepGoalRecommendation(
      target: target,
      // Defensive: if min ever rounds above target (e.g., tiny target),
      // pin it equal to target so we never give an inverted range.
      min: min > target ? target : min,
      max: max,
    );
  }

  /// Default recommendation when the user hasn't completed the survey
  /// yet — used by the goal-edit UI as a safety net. Mirrors the legacy
  /// 8,000-step default with a wide 4,000 – 11,000 range so the user can
  /// still customize before we have the formula inputs.
  static const StepGoalRecommendation fallback = StepGoalRecommendation(
    target: 8000,
    min: 4000,
    max: 11000,
  );

  /// Stride length in metres — used to derive a "× km" sub-label on the
  /// daily target card. Generic average; we don't ask for height in the
  /// onboarding survey so a single constant is good enough. Exposed here
  /// so any UI that needs the conversion uses the same value.
  static const double averageStrideMetres = 0.75;

  /// Cheap, deterministic steps → km conversion for the Home daily target
  /// card and any other "today" stat surface. Uses [averageStrideMetres].
  /// For actual measured distance (Track sessions), use the GPS path
  /// length, not this.
  static double stepsToKm(int steps) =>
      (steps * averageStrideMetres) / 1000.0;

  // ─── Factor tables ─────────────────────────────────────────────────────

  static double _ageFactor(int age) {
    if (age <= 30) return 1.00;
    if (age <= 50) return 0.90;
    if (age <= 65) return 0.75;
    return 0.60;
  }

  static double _genderFactor(Gender g) =>
      g == Gender.man ? 1.05 : 1.00;

  static double _fitnessFactor(FitnessLevel f) => switch (f) {
        FitnessLevel.beginner => 0.65,
        FitnessLevel.intermediate => 1.00,
        FitnessLevel.advanced => 1.25,
        FitnessLevel.pro => 1.50,
      };

  /// Round to nearest multiple of 500 (and never below 500 — guards
  /// against a malformed input pushing the target into 0/negatives).
  static int _round500(double v) {
    if (v < 500) return 500;
    return ((v / 500).round()) * 500;
  }
}
