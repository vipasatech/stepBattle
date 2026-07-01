import 'dart:ui';

/// Standard share-card sizes the user can pick between in the share
/// sheet. Values are LOGICAL pixels — actual PNG output is multiplied
/// by `pixelRatio` at capture time (default 3.0 → 3240×5760 for Story,
/// 3240×3240 for Square).
enum ShareCardSize {
  /// Instagram / TikTok / Snap story canvas. 9 : 16 portrait.
  story(width: 1080, height: 1920, label: 'Story'),

  /// Instagram / X feed-friendly square. 1 : 1.
  square(width: 1080, height: 1080, label: 'Square');

  final double width;
  final double height;
  final String label;

  const ShareCardSize({
    required this.width,
    required this.height,
    required this.label,
  });

  Size get logicalSize => Size(width, height);
}
