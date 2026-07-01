import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tick counter that increments every time the user lands back on the
/// Home tab from a different shell branch.
///
/// The `StatefulNavigationShell` keeps `HomeScreen` alive when the user
/// switches tabs, so `initState` runs only on the very first build. UI
/// affordances that want to re-fire on every Home focus (e.g. the
/// animated Buy XP CTA's border sweep) watch this provider instead and
/// restart their animations when its value changes.
///
/// Owner of the tick: `_MainShellState`, which compares
/// `navigationShell.currentIndex` against its prior value on each build
/// and bumps this provider whenever the index transitions from a
/// non-Home branch to 0.
final homeTabFocusTickProvider = StateProvider<int>((_) => 0);

/// Sibling of [homeTabFocusTickProvider] for the Ranks tab (index 4
/// in the shell). Ticks every time the user lands back on Ranks from
/// a different branch, so the leaderboard hero's crown-sweep + rays
/// celebration can replay — mirrors the +XP CTA's re-fire pattern on
/// the Home tab.
final ranksTabFocusTickProvider = StateProvider<int>((_) => 0);
