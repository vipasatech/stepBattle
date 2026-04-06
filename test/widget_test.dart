import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/config/theme.dart';
import 'package:stepbattle/config/colors.dart';

void main() {
  testWidgets('AppTheme.dark applies correctly to Scaffold', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: Text(
                  'StepBattle',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('StepBattle'), findsOneWidget);
  });

  test('Design tokens match DESIGN.md spec values', () {
    expect(AppColors.background, const Color(0xFF0E0E10));
    expect(AppColors.primary, const Color(0xFF84ADFF));
    expect(AppColors.primaryBrand, const Color(0xFF1A73E8));
    expect(AppColors.onSurface, const Color(0xFFFEFBFE));
    expect(AppColors.surfaceContainerHighest, const Color(0xFF252528));
    expect(AppColors.gold, const Color(0xFFFFD700));
    expect(AppColors.success, const Color(0xFF34A853));
    expect(AppColors.error, const Color(0xFFFF716C));
  });
}
