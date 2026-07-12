import 'dart:io';

import 'package:flutter/material.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../battle_result_card.dart';
import '../themed_battle_background.dart';
import 'battle_share_element.dart';
import 'share_card_size.dart';

/// Story-sized (1080×1920) share card for a completed battle. Renders
/// a snapshot of the arrangement the user built on the Battle Status
/// page (background + card + wordmark, at fractional positions).
///
/// The [selected] hint is a **preview-only affordance** — when this
/// widget renders inside the share sheet's preview with a selected
/// element, a subtle brand-primary dashed outline surrounds the
/// element so the user knows what a subsequent drag will move. The
/// outline is skipped on the final render.
class BattleStatusShareCard extends StatelessWidget {
  final BattleModel battle;
  final String uid;
  final ShareCardSize size;

  /// User-picked background photo (file path from image_picker). Null
  /// when `useThemed` is true or the user never picked one.
  final String? photoPath;

  /// Force the themed violet-gradient painter regardless of
  /// [photoPath]. When true the photo is ignored.
  final bool useThemed;

  /// Fractional canvas position for the battle card.
  final Offset cardPos;

  /// Fractional canvas position for the STEPBATTLE wordmark.
  final Offset wordmarkPos;

  /// Which overlay to draw a selection outline around. Null → no
  /// outline (used for the final PNG capture).
  final BattleShareElement? selected;

  const BattleStatusShareCard({
    super.key,
    required this.battle,
    required this.uid,
    required this.size,
    this.photoPath,
    this.useThemed = false,
    this.cardPos = const Offset(0.5, 0.60),
    this.wordmarkPos = const Offset(0.5, 0.18),
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    // Text scale multiplier — the story canvas is 1080-wide vs a
    // ~360-wide on-screen card.
    final scale = size.width / 360.0;
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background — same priority order as the live screen.
            if (useThemed || photoPath == null)
              ThemedBattleBackground(cardCenterFraction: cardPos.dy)
            else ...[
              Image.file(File(photoPath!), fit: BoxFit.cover),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Color(0x33000000)],
                  ),
                ),
                child: SizedBox.expand(),
              ),
            ],

            // Battle card overlay.
            _PositionedOverlay(
              position: cardPos,
              size: size.logicalSize,
              isSelected: selected == BattleShareElement.card,
              scale: scale,
              child: SizedBox(
                width: size.width * 0.86,
                child: BattleResultCard(
                  battle: battle,
                  uid: uid,
                  scale: scale,
                ),
              ),
            ),

            // STEPBATTLE wordmark overlay.
            _PositionedOverlay(
              position: wordmarkPos,
              size: size.logicalSize,
              isSelected: selected == BattleShareElement.wordmark,
              scale: scale,
              child: Text(
                'STEPBATTLE',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'Manrope',
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w900,
                  fontSize: 24 * scale,
                  letterSpacing: 3 * scale,
                  shadows: const [
                    Shadow(color: Color(0xCC000000), blurRadius: 10),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PositionedOverlay extends StatelessWidget {
  final Offset position;
  final Size size;
  final Widget child;

  /// When true, draw a dashed brand-primary outline around the child
  /// so users know it's the current drag target. Scaled to match the
  /// canvas so the outline reads the same on-screen and in preview.
  final bool isSelected;
  final double scale;

  const _PositionedOverlay({
    required this.position,
    required this.size,
    required this.child,
    required this.isSelected,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    Widget body = child;
    if (isSelected) {
      body = Container(
        padding: EdgeInsets.all(8 * scale),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16 * scale),
          border: Border.all(
            color: AppColors.primary,
            width: 2 * scale,
          ),
        ),
        child: child,
      );
    }
    return Positioned(
      left: position.dx * size.width,
      top: position.dy * size.height,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: body,
      ),
    );
  }
}
