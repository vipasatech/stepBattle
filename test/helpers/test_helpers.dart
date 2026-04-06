import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stepbattle/config/theme.dart';

/// Wraps a widget in MaterialApp with StepBattle theme for widget testing.
Widget createTestApp(Widget child, {List<Override>? overrides}) {
  return ProviderScope(
    overrides: overrides ?? [],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: child,
    ),
  );
}

/// Wraps a widget in a Scaffold for isolated widget tests.
Widget createTestScaffold(Widget child, {List<Override>? overrides}) {
  return createTestApp(Scaffold(body: child), overrides: overrides);
}
