import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '_card_shared.dart';
import 'share_card_size.dart';

/// Share card for the user's current daily-step streak.
///
/// Layout at 1080×1920 (Story) / 1080×1080 (Square):
///
///   ┌───────────────────────────────────────────┐
///   │          STEPBATTLE wordmark              │
///   │                                            │
///   │                🔥                          │
///   │               42                           │
///   │            DAY STREAK                      │
///   │                                            │
///   │       Best so far · {N} days               │
///   │                                            │
///   │              {today's date}                │
///   └───────────────────────────────────────────┘
class StreakShareCard extends StatelessWidget {
  final int currentStreak;
  final int bestStreak;
  final ShareCardSize size;

  const StreakShareCard({
    super.key,
    required this.currentStreak,
    required this.bestStreak,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final scale = size.width / 1080;

    // Deep-orange base — matches the app's `_streakOrange` used on the
    // Home streak strip and the Profile streak pill, so the shared
    // card carries the same signal colour.
    const flameOrange = Color(0xFFD97706);
    const flameHighlight = Color(0xFFFFB74D);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: size.width,
        height: size.height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF7A3A00),
              Color(0xFF1A0F00),
            ],
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          60 * scale,
          140 * scale,
          60 * scale,
          140 * scale,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ShareCardPieces.wordmark(light: true, scale: scale),
            ),

            const Spacer(),

            // Big flame glyph.
            Center(
              child: Icon(
                Icons.local_fire_department,
                color: flameHighlight,
                size: 260 * scale,
                shadows: [
                  Shadow(
                    color: flameOrange.withValues(alpha: 0.85),
                    blurRadius: 40 * scale,
                  ),
                ],
              ),
            ),

            SizedBox(height: 24 * scale),

            // Massive streak number.
            Center(
              child: Text(
                '$currentStreak',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'Manrope',
                  fontSize: 280 * scale,
                  fontWeight: FontWeight.w900,
                  height: 0.95,
                  letterSpacing: -8,
                ),
              ),
            ),

            SizedBox(height: 12 * scale),

            Center(
              child: Text(
                'DAY STREAK',
                style: TextStyle(
                  color: flameHighlight,
                  fontFamily: 'Manrope',
                  fontSize: 44 * scale,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
            ),

            SizedBox(height: 40 * scale),

            // "Best so far" chip.
            Center(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 28 * scale,
                  vertical: 14 * scale,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 1.5 * scale,
                  ),
                ),
                child: Text(
                  'Best so far · $bestStreak days',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontFamily: 'Manrope',
                    fontSize: 32 * scale,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            const Spacer(),

            Center(
              child: Text(
                _footerLine(),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontFamily: 'Manrope',
                  fontSize: 26 * scale,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _footerLine() =>
      DateFormat('MMM d, yyyy').format(DateTime.now()).toUpperCase();
}
