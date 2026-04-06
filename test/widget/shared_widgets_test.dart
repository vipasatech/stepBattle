import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/widgets/glass_card.dart';
import 'package:stepbattle/widgets/progress_bar.dart';
import 'package:stepbattle/widgets/dual_fill_bar.dart';
import 'package:stepbattle/widgets/status_pill.dart';
import 'package:stepbattle/widgets/bottom_sheet_handle.dart';
import 'package:stepbattle/widgets/empty_state.dart';
import 'package:stepbattle/widgets/avatar_circle.dart';
import '../helpers/test_helpers.dart';

void main() {
  group('GlassCard', () {
    testWidgets('renders child content', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const GlassCard(child: Text('Hello Glass')),
      ));
      expect(find.text('Hello Glass'), findsOneWidget);
    });

    testWidgets('applies custom padding', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const GlassCard(
          padding: EdgeInsets.all(40),
          child: Text('Padded'),
        ),
      ));
      expect(find.text('Padded'), findsOneWidget);
    });
  });

  group('StepProgressBar', () {
    testWidgets('renders at 0% progress', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StepProgressBar(progress: 0.0, height: 12),
      ));
      // Should still render the track
      expect(find.byType(StepProgressBar), findsOneWidget);
    });

    testWidgets('renders at 100% progress', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StepProgressBar(progress: 1.0, height: 12),
      ));
      expect(find.byType(StepProgressBar), findsOneWidget);
    });

    testWidgets('renders at 50% progress', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StepProgressBar(progress: 0.5, height: 10),
      ));
      expect(find.byType(StepProgressBar), findsOneWidget);
    });

    testWidgets('clamps progress above 1.0', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StepProgressBar(progress: 1.5, height: 8),
      ));
      // Should not crash, renders normally
      expect(find.byType(StepProgressBar), findsOneWidget);
    });
  });

  group('DualFillBar', () {
    testWidgets('renders with equal steps', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const DualFillBar(yourSteps: 5000, opponentSteps: 5000),
      ));
      expect(find.byType(DualFillBar), findsOneWidget);
    });

    testWidgets('renders with zero steps', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const DualFillBar(yourSteps: 0, opponentSteps: 0),
      ));
      expect(find.byType(DualFillBar), findsOneWidget);
    });

    testWidgets('renders when leading', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const DualFillBar(yourSteps: 8000, opponentSteps: 3000),
      ));
      expect(find.byType(DualFillBar), findsOneWidget);
    });
  });

  group('StatusPill', () {
    testWidgets('displays Live text', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StatusPill(type: StatusType.live),
      ));
      expect(find.text('Live'), findsOneWidget);
    });

    testWidgets('displays Won text', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StatusPill(type: StatusType.won),
      ));
      expect(find.text('Won'), findsOneWidget);
    });

    testWidgets('displays Lost text', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StatusPill(type: StatusType.lost),
      ));
      expect(find.text('Lost'), findsOneWidget);
    });

    testWidgets('displays Pending text', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const StatusPill(type: StatusType.pending),
      ));
      expect(find.text('Pending'), findsOneWidget);
    });

    testWidgets('displays all status types without error', (tester) async {
      for (final type in StatusType.values) {
        await tester.pumpWidget(createTestScaffold(
          StatusPill(type: type),
        ));
        expect(find.byType(StatusPill), findsOneWidget);
      }
    });
  });

  group('BottomSheetHandle', () {
    testWidgets('renders handle pill', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const BottomSheetHandle(),
      ));
      expect(find.byType(BottomSheetHandle), findsOneWidget);
    });
  });

  group('EmptyState', () {
    testWidgets('displays title and subtitle', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const EmptyState(
          icon: Icons.bolt,
          title: 'No data',
          subtitle: 'Start walking!',
        ),
      ));
      expect(find.text('No data'), findsOneWidget);
      expect(find.text('Start walking!'), findsOneWidget);
    });

    testWidgets('shows CTA button when provided', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        EmptyState(
          icon: Icons.bolt,
          title: 'Empty',
          subtitle: 'Nothing here',
          ctaLabel: 'Get Started',
          onCtaTap: () {},
        ),
      ));
      expect(find.text('Get Started'), findsOneWidget);
    });

    testWidgets('hides CTA button when not provided', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const EmptyState(
          icon: Icons.bolt,
          title: 'Empty',
          subtitle: 'Nothing here',
        ),
      ));
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('AvatarCircle', () {
    testWidgets('shows initials when no image', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const AvatarCircle(initials: 'AB', radius: 20),
      ));
      expect(find.text('AB'), findsOneWidget);
    });

    testWidgets('renders with badge', (tester) async {
      await tester.pumpWidget(createTestScaffold(
        const AvatarCircle(
          initials: 'X',
          radius: 20,
          badge: Icon(Icons.star, size: 12),
        ),
      ));
      expect(find.byIcon(Icons.star), findsOneWidget);
    });
  });
}
