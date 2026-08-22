import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stepbattle/widgets/app_network_image.dart';

/// [AppNetworkImage] wraps `CachedNetworkImage` behind a stable API so
/// every remote image in the app can switch caching policy in one place.
/// These tests pin the surface contract:
///
///   1. Renders without crashing given a URL.
///   2. Shows the placeholder immediately (spinner or plain box).
///   3. `borderRadius` wraps the image in a ClipRRect.
///   4. `showSpinner: false` drops the spinner from the placeholder.
void main() {
  group('AppNetworkImage', () {
    testWidgets('renders and shows a placeholder before load', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 100,
              height: 100,
              child: AppNetworkImage(
                url: 'https://example.invalid/never-loads.jpg',
                width: 100,
                height: 100,
              ),
            ),
          ),
        ),
      );
      // Frame 1: the placeholder container is up before any network work
      // could plausibly complete.
      expect(find.byType(AppNetworkImage), findsOneWidget);
      // Placeholder spinner is present unless explicitly disabled.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('borderRadius wraps output in a ClipRRect', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 100,
              height: 100,
              child: AppNetworkImage(
                url: 'https://example.invalid/x.jpg',
                width: 100,
                height: 100,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      );
      // A ClipRRect wraps the CachedNetworkImage widget subtree.
      expect(find.byType(ClipRRect), findsWidgets);
    });

    testWidgets('showSpinner:false removes the placeholder spinner',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 20,
              height: 20,
              child: AppNetworkImage(
                url: 'https://example.invalid/x.jpg',
                width: 20,
                height: 20,
                showSpinner: false,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
