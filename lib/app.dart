import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/colors.dart';
import 'config/theme.dart';
import 'config/routes.dart';
import 'providers/theme_mode_provider.dart';

class StepBattleApp extends ConsumerWidget {
  const StepBattleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final mode = ref.watch(themeModePrefProvider);

    // Resolve effective brightness BEFORE MaterialApp.router builds, so the
    // first frame of every descendant reads the right value from
    // AppColors.X getters. Doing this from MaterialApp.builder was too
    // late — the builder wraps the navigator output, by which point
    // children have already built with the stale (dark-default) value.
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final effective = switch (mode) {
      ThemeMode.system => platformBrightness,
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
    AppColors.updateBrightness(effective);

    return MaterialApp.router(
      title: 'StepBattle',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      routerConfig: router,
      // Clamp the OS-level text scaling so very aggressive accessibility
      // settings (e.g. Android "Largest" / iOS 200% Dynamic Type) don't
      // blow out our fixed-height pills, app-bars, and battle cards.
      // We still respect the user's preference up to 1.2× — past that
      // we hold the line. Users who need bigger text can still use
      // pinch-zoom on screens that support it (Profile, leaderboards).
      builder: (context, child) {
        // Defensive double-update — Theme.of inside the builder reflects
        // the FINAL resolved brightness (incl. any platform overrides
        // applied between StepBattleApp.build and here). Cheap no-op
        // when the parent already set the right value.
        AppColors.updateBrightness(Theme.of(context).brightness);

        final mq = MediaQuery.of(context);
        final clampedScale =
            mq.textScaler.scale(1.0).clamp(0.85, 1.20);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(clampedScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
