enum MissionType { daily, weekly }

enum MissionCategory { steps, battle, streak, calories }

class MissionModel {
  final String missionId;
  final MissionType type;
  final String title;
  final String description;
  final MissionCategory category;
  final int targetValue;
  final int xpReward;
  final String difficulty; // "easy" | "medium" | "hard"

  /// When true, admin has asked us to feature this mission on the
  /// Home tab as a big card (alongside the active-battle card).
  /// Otherwise the mission lives only in the Missions tab.
  final bool shouldShowInHome;

  /// Optional admin-uploaded poster (PNG/JPG in the `mission-posters`
  /// Supabase Storage bucket). When set, the client shows a full-
  /// screen popup on next app open / foreground until the user
  /// dismisses it via the [X]. Dismissal is device-local and
  /// permanent per mission id.
  final String? posterUrl;

  /// Tiebreaker when multiple missions compete for the same slot
  /// (highest wins). Applies to both featured Home cards (ordering)
  /// and poster popups (only one poster per app open, highest wins).
  final int displayOrder;

  const MissionModel({
    required this.missionId,
    required this.type,
    required this.title,
    required this.description,
    required this.category,
    required this.targetValue,
    required this.xpReward,
    required this.difficulty,
    this.shouldShowInHome = false,
    this.posterUrl,
    this.displayOrder = 100,
  });

  /// Build a MissionModel from a Supabase `public.missions` row. Note that
  /// the catalog table uses the missionId as the primary key (`id` column),
  /// not a generated uuid — matches the Firestore docId convention.
  factory MissionModel.fromSupabaseRow(Map<String, dynamic> d) {
    return MissionModel(
      missionId: d['id'] as String? ?? '',
      type: d['type'] == 'weekly' ? MissionType.weekly : MissionType.daily,
      title: d['title'] as String? ?? '',
      description: d['description'] as String? ?? '',
      category: _parseCategory(d['category'] as String? ?? 'steps'),
      targetValue: (d['target_value'] as num?)?.toInt() ?? 0,
      xpReward: (d['xp_reward'] as num?)?.toInt() ?? 0,
      difficulty: d['difficulty'] as String? ?? 'easy',
      shouldShowInHome: d['should_show_in_home'] as bool? ?? false,
      posterUrl: (d['poster_url'] as String?)?.trim().isEmpty ?? true
          ? null
          : d['poster_url'] as String?,
      displayOrder: (d['display_order'] as num?)?.toInt() ?? 100,
    );
  }
  static MissionCategory _parseCategory(String s) => switch (s) {
        'battle' => MissionCategory.battle,
        'streak' => MissionCategory.streak,
        'calories' => MissionCategory.calories,
        _ => MissionCategory.steps,
      };

  /// Client-side seed missions used when the admin-managed `missions`
  /// table hasn't yet supplied a catalog (fresh install, offline, or
  /// pre-launch). In v2 the entire catalog is admin-driven from the
  /// website — the ONE mission we keep on the client is
  /// `daily_streak`, which is baked into the app's XP model as a
  /// system reward and shouldn't be removable via the admin panel.
  /// Everything else (step goals, battle wins, weekly challenges) is
  /// now the admin's responsibility to publish.
  static const List<MissionModel> defaultDaily = [
    MissionModel(
      missionId: 'daily_streak',
      type: MissionType.daily,
      title: 'Keep Streak Alive',
      description: 'Log steps for another consecutive day',
      category: MissionCategory.streak,
      targetValue: 1,
      xpReward: 50,
      difficulty: 'easy',
    ),
  ];

  /// No default weekly challenges ship on the client — the admin
  /// publishes them via the website. If none exist yet, the missions
  /// tab renders an empty state for the "Weekly" section.
  static const List<MissionModel> defaultWeekly = <MissionModel>[];
}
