import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';
import '../models/run_session_model.dart';
import '../services/share_card_service.dart';
import '../widgets/share_cards/_card_shared.dart';
import '../widgets/share_cards/map_share_card.dart';
import '../widgets/share_cards/photo_share_card.dart';
import '../widgets/share_cards/share_card_size.dart';
import '../widgets/share_cards/transparent_share_card.dart';


/// Full-height "Share Activity" sheet — replaces the earlier tabs-with-
/// preview layout with a Strava-style horizontal carousel of variants
/// stacked over a "Share to" action grid.
///
/// Slides in the carousel:
///   • **Map**          — always available (route on a stylised backdrop).
///   • **Photo (× N)**  — one slide per attached photo, in save order.
///   • **Transparent**  — always available (sticker for Story overlays).
///
/// Share-to grid (below the carousel):
///   • **Save**            → writes the current slide's PNG to the
///                          device Photos / Gallery via `gal`.
///   • **Instagram Story** → attempts the `instagram-stories://` URL
///                          scheme; falls back to the system share
///                          sheet if Instagram isn't installed.
///   • **Share to…**       → opens the OS share sheet (WhatsApp,
///                          Messages, Email, etc.).
///   • **Copy caption**    → copies the pre-filled caption text.
Future<void> showTrackShareSheet(
  BuildContext context, {
  required RunSession session,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _TrackShareSheet(session: session),
  );
}

class _TrackShareSheet extends StatefulWidget {
  final RunSession session;
  const _TrackShareSheet({required this.session});

  @override
  State<_TrackShareSheet> createState() => _TrackShareSheetState();
}

class _TrackShareSheetState extends State<_TrackShareSheet> {
  late final PageController _pageController;
  int _page = 0;
  bool _busy = false;

  late final List<_Slide> _slides;

  /// Per-slide overlay-anchor positions for the three draggable
  /// elements. Applies to BOTH Map and Photo slides (the Transparent
  /// slide is not repositionable). Keys are slide indices; values are
  /// fractional anchors (0..1) on the 1080×1920 card.
  final Map<int, Offset> _titleOffsets = {};
  final Map<int, Offset> _statsOffsets = {};
  final Map<int, Offset> _wordmarkOffsets = {};

  /// Which element is currently selected on the CURRENT interactive
  /// slide (Map or Photo). Tap on an element → selects it; tap on empty
  /// preview area → clears. Only the selected element receives drags.
  ShareCardElement? _selected;

  @override
  void initState() {
    super.initState();
    _slides = _buildSlides(widget.session);
    // Seed default overlay offsets for every interactive slide (Map +
    // Photo variants). Transparent has no repositionable elements.
    for (var i = 0; i < _slides.length; i++) {
      final s = _slides[i];
      if (s.kind == _Kind.photo) {
        _titleOffsets[i] = PhotoShareCard.defaultTitleOffset;
        _statsOffsets[i] = PhotoShareCard.defaultStatsOffset;
        _wordmarkOffsets[i] = PhotoShareCard.defaultWordmarkOffset;
      } else if (s.kind == _Kind.map) {
        _titleOffsets[i] = MapShareCard.defaultTitleOffset;
        _statsOffsets[i] = MapShareCard.defaultStatsOffset;
        _wordmarkOffsets[i] = MapShareCard.defaultWordmarkOffset;
      }
    }
    // Default to the first Photo slide when the session has photos —
    // it's the most visually compelling starting point.
    final firstPhoto = _slides.indexWhere((s) => s.kind == _Kind.photo);
    _page = firstPhoto == -1 ? 0 : firstPhoto;
    _pageController = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Every session gets Map + Transparent slides. Each attached photo
  /// contributes ONE Photo slide (centred layout — wordmark top,
  /// overlays low-centre; all draggable).
  static List<_Slide> _buildSlides(RunSession s) {
    final list = <_Slide>[const _Slide.map()];
    for (final url in s.mediaUrls) {
      list.add(_Slide.photo(url));
    }
    list.add(const _Slide.transparent());
    return list;
  }

  String _defaultCaption() {
    final km = (widget.session.distanceMeters / 1000).toStringAsFixed(2);
    final time = _fmtDur(widget.session.durationSeconds);
    return 'Just clocked $km km · $time on StepBattle 🔥';
  }

  static String _fmtDur(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  Widget _cardForSlide(
    _Slide s,
    ShareCardSize size, {
    int? slideIndex,
    bool showSelection = false,
    bool preview = false,
  }) {
    switch (s.kind) {
      case _Kind.map:
        return MapShareCard(
          session: widget.session,
          size: size,
          titleOffset: (slideIndex == null
                  ? null
                  : _titleOffsets[slideIndex]) ??
              MapShareCard.defaultTitleOffset,
          statsOffset: (slideIndex == null
                  ? null
                  : _statsOffsets[slideIndex]) ??
              MapShareCard.defaultStatsOffset,
          wordmarkOffset: (slideIndex == null
                  ? null
                  : _wordmarkOffsets[slideIndex]) ??
              MapShareCard.defaultWordmarkOffset,
          // Selection border is preview-only — export passes null.
          selectedElement: showSelection ? _selected : null,
        );
      case _Kind.photo:
        final titleOff = (slideIndex == null
                ? null
                : _titleOffsets[slideIndex]) ??
            PhotoShareCard.defaultTitleOffset;
        final statsOff = (slideIndex == null
                ? null
                : _statsOffsets[slideIndex]) ??
            PhotoShareCard.defaultStatsOffset;
        final wordOff = (slideIndex == null
                ? null
                : _wordmarkOffsets[slideIndex]) ??
            PhotoShareCard.defaultWordmarkOffset;
        return PhotoShareCard(
          session: widget.session,
          photoUrl: s.photoUrl!,
          size: size,
          titleOffset: titleOff,
          statsOffset: statsOff,
          wordmarkOffset: wordOff,
          // Only render the dashed selection border in the PREVIEW —
          // the exported PNG passes `showSelection: false` so the
          // shared image is clean.
          selectedElement: showSelection ? _selected : null,
        );
      case _Kind.transparent:
        return TransparentShareCard(
          session: widget.session,
          size: size,
          // Preview shows the TRANSPARENT tag as a reminder to the
          // user; export strips it so the shared sticker is clean.
          showLabel: preview,
        );
    }
  }

  /// Render the currently-selected slide to a PNG for sharing/saving.
  ///
  /// Map slides get a longer settle delay because the OSM tile layer
  /// paints images fetched over the network — the base 350 ms in the
  /// service isn't enough for a cold-cache render. If the user has
  /// already swiped to the Map slide once in the preview, tiles are
  /// warm in `ImageCache` and the delay is mostly wasted; that's
  /// acceptable UX cost for the cold case.
  Future<Uint8List> _renderCurrent() async {
    final slide = _slides[_page];
    // Never bake preview-only affordances (selection border, checker
    // background, TRANSPARENT label) into the exported PNG.
    final card = _cardForSlide(
      slide,
      ShareCardSize.story,
      slideIndex: _page,
      showSelection: false,
      preview: false,
    );
    // Map card needs extra time so its OSM tiles finish loading in the
    // headless render tree. When the user has already viewed the Map
    // slide in the preview, tiles are warm in `ImageCache` and this
    // delay is mostly slack — that's acceptable for the cold case.
    final settleDelay = slide.kind == _Kind.map
        ? const Duration(milliseconds: 1200)
        : const Duration(milliseconds: 350);
    return ShareCardService.renderToPng(
      widget: card,
      logicalSize: ShareCardSize.story.logicalSize,
      pixelRatio: 1.0,
      settleDelay: settleDelay,
    );
  }

  String _filenameForCurrent(String ext) {
    final slide = _slides[_page];
    return 'stepbattle_${widget.session.id}_${slide.kind.name}.$ext';
  }

  Future<void> _runAction(
    Future<void> Function() action,
    String progressLabel,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$progressLabel failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onSaveToDevice() => _runAction(() async {
        final bytes = await _renderCurrent();
        final ok = await ShareCardService.saveToGallery(
          bytes,
          name: _filenameForCurrent('png'),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? 'Saved to Photos.' : 'Save failed.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }, 'Save');

  Future<void> _onInstagramStory() => _runAction(() async {
        final bytes = await _renderCurrent();
        final path = await ShareCardService.savePngToCache(
          bytes,
          filename: _filenameForCurrent('png'),
        );
        final launched =
            await ShareCardService.tryOpenInstagramStories(path);
        if (!mounted) return;
        if (!launched) {
          // Fall back to the standard share sheet — Instagram Story
          // still shows up there when the app is installed.
          await ShareCardService.shareFiles(
            [path],
            text: _defaultCaption(),
          );
        }
      }, 'Instagram Story');

  Future<void> _onShareTo() => _runAction(() async {
        final bytes = await _renderCurrent();
        final path = await ShareCardService.savePngToCache(
          bytes,
          filename: _filenameForCurrent('png'),
        );
        await ShareCardService.shareFiles(
          [path],
          text: _defaultCaption(),
        );
      }, 'Share');

  /// Return the hit-fraction for [element] on the given slide variant.
  /// Map and Photo cards each ship their own hit-box constants because
  /// their layouts differ (map title includes the shoe icon).
  Size _hitFractionFor(_Slide slide, ShareCardElement element) {
    if (slide.kind == _Kind.map) {
      switch (element) {
        case ShareCardElement.title:
          return MapShareCard.titleHitFraction;
        case ShareCardElement.stats:
          return MapShareCard.statsHitFraction;
        case ShareCardElement.wordmark:
          return MapShareCard.wordmarkHitFraction;
      }
    }
    switch (element) {
      case ShareCardElement.title:
        return PhotoShareCard.titleHitFraction;
      case ShareCardElement.stats:
        return PhotoShareCard.statsHitFraction;
      case ShareCardElement.wordmark:
        return PhotoShareCard.wordmarkHitFraction;
    }
  }

  /// Hit-test a tap in preview-space against the three overlay boxes on
  /// the current interactive slide. Returns which element was hit, or
  /// `null` if the tap landed in empty preview space.
  ShareCardElement? _hitTest(Offset localPosition, Size previewSize) {
    final slide = _slides[_page];
    if (slide.kind == _Kind.transparent) return null;
    if (previewSize.width <= 0 || previewSize.height <= 0) return null;

    final fx = localPosition.dx / previewSize.width;
    final fy = localPosition.dy / previewSize.height;

    // Test in top-to-bottom-of-Stack order — wordmark is on top of
    // title in the Photo variant when they overlap, so give it
    // priority for the tap.
    final wordOff = _wordmarkOffsets[_page];
    if (wordOff != null &&
        _hits(fx, fy, wordOff,
            _hitFractionFor(slide, ShareCardElement.wordmark))) {
      return ShareCardElement.wordmark;
    }
    final titleOff = _titleOffsets[_page];
    if (titleOff != null &&
        _hits(fx, fy, titleOff,
            _hitFractionFor(slide, ShareCardElement.title))) {
      return ShareCardElement.title;
    }
    final statsOff = _statsOffsets[_page];
    if (statsOff != null &&
        _hits(fx, fy, statsOff,
            _hitFractionFor(slide, ShareCardElement.stats))) {
      return ShareCardElement.stats;
    }
    return null;
  }

  /// Tap handler — hit-test and update selection. Wired to `onTapDown`
  /// so selection fires the instant a finger lands (rather than on tap
  /// release), which also plays nicely with the gesture arena when the
  /// user immediately starts dragging.
  void _handleTap(Offset localPosition, Size previewSize) {
    final hit = _hitTest(localPosition, previewSize);
    setState(() => _selected = hit);
  }

  static bool _hits(double fx, double fy, Offset anchor, Size hitSize) {
    return (fx - anchor.dx).abs() <= hitSize.width / 2 &&
        (fy - anchor.dy).abs() <= hitSize.height / 2;
  }

  /// Called at the start of a pan. If no element is currently selected
  /// but the pan starts on an element, select it and start dragging in
  /// one motion — avoids the "tap, release, then tap again to drag"
  /// double-motion.
  void _handlePanStart(Offset localPosition, Size previewSize) {
    if (_selected == null) {
      final hit = _hitTest(localPosition, previewSize);
      if (hit == null) return;
      setState(() => _selected = hit);
    }
    _handleOverlayDrag(localPosition, previewSize);
  }

  /// Move the currently-selected element so its centre snaps to the
  /// current finger position (in preview-space). Following the finger
  /// directly (rather than accumulating deltas) matches the user's
  /// request that the "selected text box should move where the touch
  /// is happening" — no drift when the tap lands off-centre.
  void _handleOverlayDrag(Offset localPosition, Size previewSize) {
    if (previewSize.width <= 0 || previewSize.height <= 0) return;
    if (_selected == null) return;
    final fx = (localPosition.dx / previewSize.width).clamp(0.10, 0.90);
    final fy = (localPosition.dy / previewSize.height).clamp(0.10, 0.95);
    final Map<int, Offset> targetMap;
    switch (_selected!) {
      case ShareCardElement.title:
        targetMap = _titleOffsets;
        break;
      case ShareCardElement.stats:
        targetMap = _statsOffsets;
        break;
      case ShareCardElement.wordmark:
        targetMap = _wordmarkOffsets;
        break;
    }
    setState(() {
      targetMap[_page] = Offset(fx, fy);
    });
  }

  Future<void> _onCopyCaption() async {
    final text = _defaultCaption();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Caption copied'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.6,
      maxChildSize: 0.94,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          // Compact layout — Strava-style: preview fills available
          // vertical space, dots + share grid pin below. Nothing
          // scrolls, so all actions are one tap away without swiping
          // the sheet up.
          child: Column(
            children: [
              _TopBar(
                onClose: _busy ? null : () => Navigator.of(context).pop(),
              ),
              // Expanded preview — Center + AspectRatio keep the 9/16
              // card shape and letterbox horizontally when the sheet is
              // taller than it is wide.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: PageView.builder(
                        controller: _pageController,
                        itemCount: _slides.length,
                        physics: _selected != null
                            ? const NeverScrollableScrollPhysics()
                            : const BouncingScrollPhysics(),
                        onPageChanged: (i) => setState(() {
                          _page = i;
                          _selected = null;
                        }),
                        itemBuilder: (_, i) {
                          final slide = _slides[i];
                          final canInteract = slide.kind == _Kind.map ||
                              slide.kind == _Kind.photo;
                          final showChecker =
                              slide.kind == _Kind.transparent;
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6),
                            child: _PreviewCard(
                              interactive: canInteract,
                              checkerBackground: showChecker,
                              onTap: canInteract
                                  ? (pos, previewSize) =>
                                      _handleTap(pos, previewSize)
                                  : null,
                              onPanStart: canInteract
                                  ? (localPos, previewSize) =>
                                      _handlePanStart(
                                          localPos, previewSize)
                                  : null,
                              onPanUpdate: canInteract
                                  ? (localPos, previewSize) =>
                                      _handleOverlayDrag(
                                          localPos, previewSize)
                                  : null,
                              child: _cardForSlide(
                                slide,
                                ShareCardSize.story,
                                slideIndex: i,
                                showSelection: canInteract,
                                preview: true,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _PageDots(count: _slides.length, active: _page),
              const SizedBox(height: 14),
              // Compact share row — 4 tap targets, no "Share to" label
              // above and no caption editor. The caption is generated
              // per action so users can tweak it in the target app.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _ShareTarget(
                        icon: Icons.download_rounded,
                        label: 'Save',
                        color: AppColors.primary,
                        onTap: _busy ? null : _onSaveToDevice,
                      ),
                    ),
                    Expanded(
                      child: _ShareTarget(
                        icon: Icons.auto_stories_outlined,
                        label: 'IG Story',
                        color: const Color(0xFFE1306C),
                        onTap: _busy ? null : _onInstagramStory,
                      ),
                    ),
                    Expanded(
                      child: _ShareTarget(
                        icon: Icons.ios_share,
                        label: 'Share to…',
                        color: AppColors.onSurface,
                        onTap: _busy ? null : _onShareTo,
                      ),
                    ),
                    Expanded(
                      child: _ShareTarget(
                        icon: Icons.copy_outlined,
                        label: 'Copy caption',
                        color: AppColors.onSurfaceVariant,
                        onTap: _busy ? null : _onCopyCaption,
                      ),
                    ),
                  ],
                ),
              ),
              // Bottom padding respects the system nav bar / gesture
              // area so targets never sit right on the swipe strip.
              SizedBox(
                height: 12 +
                    MediaQuery.of(context).viewPadding.bottom,
              ),
              if (_busy)
                LinearProgressIndicator(
                  minHeight: 2,
                  color: AppColors.primary,
                  backgroundColor: Colors.transparent,
                ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// Types
// =============================================================================

enum _Kind { map, photo, transparent }

class _Slide {
  final _Kind kind;
  final String? photoUrl;

  const _Slide.map()
      : kind = _Kind.map,
        photoUrl = null;
  const _Slide.transparent()
      : kind = _Kind.transparent,
        photoUrl = null;
  const _Slide.photo(this.photoUrl) : kind = _Kind.photo;

  String get variantLabel {
    switch (kind) {
      case _Kind.map:
        return 'Map';
      case _Kind.transparent:
        return 'Sticker';
      case _Kind.photo:
        return 'Photo';
    }
  }
}

// =============================================================================
// Top bar
// =============================================================================

class _TopBar extends StatelessWidget {
  final VoidCallback? onClose;
  const _TopBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
          Text(
            'Share Activity',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Preview card wrapper — clips + scales the 1080×1920 card widget to fit
// =============================================================================

class _PreviewCard extends StatelessWidget {
  final Widget child;
  final bool interactive;
  final bool checkerBackground;
  final void Function(Offset localPosition, Size previewSize)? onTap;
  final void Function(Offset localPosition, Size previewSize)? onPanStart;
  final void Function(Offset localPosition, Size previewSize)? onPanUpdate;

  const _PreviewCard({
    required this.child,
    this.interactive = false,
    this.checkerBackground = false,
    this.onTap,
    this.onPanStart,
    this.onPanUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final preview = ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Transparency indicator (only for the sticker variant).
              // The exported PNG stays truly alpha-0; this checker is
              // preview-only so the user sees "this will be transparent".
              if (checkerBackground)
                const Positioned.fill(
                  child: CustomPaint(painter: _CheckerPainter()),
                ),
              // The card itself, scaled to fit. Wrapped in
              // IgnorePointer because ALL preview interaction runs
              // through the outer GestureDetector via hit-testing —
              // otherwise the FlutterMap widget inside the Map card
              // eats tap-down events and the sheet never sees the
              // "tap outside" that should deselect an overlay.
              FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: ShareCardSize.story.width,
                  height: ShareCardSize.story.height,
                  child: IgnorePointer(child: child),
                ),
              ),
            ],
          ),
        );
        if (!interactive) return preview;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // `onTapDown` (not `onTapUp`) so selection fires the instant
          // the finger lands — this way the gesture arena has already
          // committed by the time a drag begins.
          onTapDown: (details) =>
              onTap?.call(details.localPosition, size),
          // `onPanStart` also hit-tests + selects (in the sheet) so a
          // single motion (touch + drag without a prior tap) works.
          onPanStart: (details) =>
              onPanStart?.call(details.localPosition, size),
          onPanUpdate: (details) =>
              onPanUpdate?.call(details.localPosition, size),
          child: preview,
        );
      },
    );
  }
}

/// Paints a light-grey checker pattern so the user can see where the
/// exported PNG will be transparent. Purely a preview affordance —
/// never baked into the shared image.
class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 24.0;
    final light = Paint()..color = const Color(0xFF3A3A3E);
    final dark = Paint()..color = const Color(0xFF2A2A2E);
    canvas.drawRect(Offset.zero & size, dark);
    for (double y = 0; y < size.height; y += cell) {
      for (double x = 0; x < size.width; x += cell) {
        final isLight =
            (((x / cell).floor() + (y / cell).floor()) & 1) == 0;
        if (isLight) {
          canvas.drawRect(
            Rect.fromLTWH(x, y, cell, cell),
            light,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => false;
}

// =============================================================================
// Page dots
// =============================================================================

class _PageDots extends StatelessWidget {
  final int count;
  final int active;
  const _PageDots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: i == active ? 16 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: i == active
                    ? AppColors.primary
                    : AppColors.outlineVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// Share-to grid target — icon + label, disabled state
// =============================================================================

class _ShareTarget extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ShareTarget({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = onTap == null;
    final effectiveColor =
        disabled ? color.withValues(alpha: 0.4) : color;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: effectiveColor.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: effectiveColor, size: 22),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: disabled
                    ? AppColors.onSurfaceVariant.withValues(alpha: 0.4)
                    : AppColors.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
