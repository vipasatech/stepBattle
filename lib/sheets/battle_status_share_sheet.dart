import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';
import '../models/battle_model.dart';
import '../services/share_card_service.dart';
import '../widgets/share_cards/battle_share_element.dart';
import '../widgets/share_cards/battle_status_share_card.dart';
import '../widgets/share_cards/share_card_size.dart';

/// Share sheet for a completed battle. Mirrors the Track share sheet:
/// scaled preview at the top, four action tiles below (Save / IG /
/// Share to / Copy caption). The preview is INTERACTIVE — tap the
/// battle card or the STEPBATTLE wordmark to select it, then drag
/// anywhere in the preview to reposition. Same tap-to-select pattern
/// the user asked to match from track share.
///
/// Positions inherit from whatever the caller passed (typically the
/// live Battle Status page's arrangement) but any tweak in this
/// sheet only affects the rendered PNG — the changes do not write
/// back to the Battle Status page's Hive layout.
Future<void> showBattleStatusShareSheet(
  BuildContext context, {
  required BattleModel battle,
  required String uid,
  String? photoPath,
  bool useThemed = false,
  Offset cardPos = defaultBattleCardPos,
  Offset wordmarkPos = defaultBattleWordmarkPos,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BattleShareSheet(
      battle: battle,
      uid: uid,
      photoPath: photoPath,
      useThemed: useThemed,
      initialCardPos: cardPos,
      initialWordmarkPos: wordmarkPos,
    ),
  );
}

/// Default overlay positions. Chosen to match the "2nd/3rd row" and
/// "3rd/4th row" ask — the story canvas is treated as a 6-row grid
/// (rows 0..5 top to bottom):
///   • Wordmark  → row ~1.1 → fractional y = 0.18
///   • Card      → row ~3.6 → fractional y = 0.60
/// Both are horizontally centred.
const Offset defaultBattleWordmarkPos = Offset(0.5, 0.18);
const Offset defaultBattleCardPos = Offset(0.5, 0.60);

// `BattleShareElement` (public) is used for both the sheet's
// `_selected` state and the share card's preview outline. See
// `lib/widgets/share_cards/battle_share_element.dart`.

class _BattleShareSheet extends StatefulWidget {
  final BattleModel battle;
  final String uid;
  final String? photoPath;
  final bool useThemed;
  final Offset initialCardPos;
  final Offset initialWordmarkPos;
  const _BattleShareSheet({
    required this.battle,
    required this.uid,
    required this.photoPath,
    required this.useThemed,
    required this.initialCardPos,
    required this.initialWordmarkPos,
  });

  @override
  State<_BattleShareSheet> createState() => _BattleShareSheetState();
}

class _BattleShareSheetState extends State<_BattleShareSheet> {
  bool _busy = false;

  /// Current overlay positions, seeded from the caller and mutated on
  /// drag. Fractional canvas coordinates (0..1).
  late Offset _cardPos = widget.initialCardPos;
  late Offset _wordmarkPos = widget.initialWordmarkPos;

  /// Currently-selected element for the tap-to-select-then-drag flow.
  /// Null = nothing selected → next tap in the preview area hits.
  BattleShareElement? _selected;

  /// Hit-test target sizes in fractional coordinates. Card is wide +
  /// tall, wordmark is a small text label. Slightly generous so the
  /// user doesn't have to be pixel-perfect.
  static const Size _cardHit = Size(0.86, 0.32);
  static const Size _wordmarkHit = Size(0.5, 0.06);

  Widget _cardWidget() => BattleStatusShareCard(
        battle: widget.battle,
        uid: widget.uid,
        size: ShareCardSize.story,
        photoPath: widget.photoPath,
        useThemed: widget.useThemed,
        cardPos: _cardPos,
        wordmarkPos: _wordmarkPos,
        selected: _selected,
      );

  Future<Uint8List> _render() {
    // Snapshot the widget WITHOUT the selection outline — the outline
    // is a preview-only affordance.
    final w = BattleStatusShareCard(
      battle: widget.battle,
      uid: widget.uid,
      size: ShareCardSize.story,
      photoPath: widget.photoPath,
      useThemed: widget.useThemed,
      cardPos: _cardPos,
      wordmarkPos: _wordmarkPos,
      selected: null,
    );
    return ShareCardService.renderToPng(
      widget: w,
      logicalSize: ShareCardSize.story.logicalSize,
      pixelRatio: 1.0,
      settleDelay: const Duration(milliseconds: 300),
    );
  }

  String _filename(String ext) =>
      'stepbattle_battle_${widget.battle.battleId}.$ext';

  String _defaultCaption() {
    final opp = widget.battle.opponentFor(widget.uid);
    final iWon = widget.battle.winnerId == widget.uid;
    final opName = opp?.friendlyName ?? 'them';
    if (iWon) {
      return 'Beat $opName in a step battle on StepBattle 💪';
    }
    return 'Great battle against $opName on StepBattle — running it back.';
  }

  Future<void> _runAction(
    Future<void> Function() action,
    String label,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$label failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onSave() => _runAction(() async {
        final bytes = await _render();
        final ok = await ShareCardService.saveToGallery(
          bytes,
          name: _filename('png'),
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? 'Saved to Photos.' : 'Save failed.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }, 'Save');

  Future<void> _onIgStory() => _runAction(() async {
        final bytes = await _render();
        final path = await ShareCardService.savePngToCache(
          bytes,
          filename: _filename('png'),
        );
        final launched = await ShareCardService.tryOpenInstagramStories(path);
        if (!mounted) return;
        if (!launched) {
          await ShareCardService.shareFiles([path], text: _defaultCaption());
        }
      }, 'Instagram Story');

  Future<void> _onShareTo() => _runAction(() async {
        final bytes = await _render();
        final path = await ShareCardService.savePngToCache(
          bytes,
          filename: _filename('png'),
        );
        await ShareCardService.shareFiles([path], text: _defaultCaption());
      }, 'Share');

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

  // ---------------------------------------------------------------------------
  // Interactive preview: hit-test → tap select → drag to reposition
  // ---------------------------------------------------------------------------

  BattleShareElement? _hitTest(Offset localPosition, Size previewSize) {
    if (previewSize.width <= 0 || previewSize.height <= 0) return null;
    final fx = localPosition.dx / previewSize.width;
    final fy = localPosition.dy / previewSize.height;
    // Wordmark on top of card in the stack when they overlap — test it
    // first so a small tap doesn't preferentially hit the (larger)
    // card behind.
    if (_within(fx, fy, _wordmarkPos, _wordmarkHit)) return BattleShareElement.wordmark;
    if (_within(fx, fy, _cardPos, _cardHit)) return BattleShareElement.card;
    return null;
  }

  static bool _within(double fx, double fy, Offset anchor, Size hitSize) {
    return (fx - anchor.dx).abs() <= hitSize.width / 2 &&
        (fy - anchor.dy).abs() <= hitSize.height / 2;
  }

  void _handleTap(Offset localPosition, Size previewSize) {
    final hit = _hitTest(localPosition, previewSize);
    setState(() => _selected = hit);
  }

  void _handlePanStart(Offset localPosition, Size previewSize) {
    // If nothing's selected and the pan lands on an element, select
    // and start dragging in one motion — matches the track share UX.
    if (_selected == null) {
      final hit = _hitTest(localPosition, previewSize);
      if (hit == null) return;
      setState(() => _selected = hit);
    }
    _handlePanUpdate(localPosition, previewSize);
  }

  void _handlePanUpdate(Offset localPosition, Size previewSize) {
    if (previewSize.width <= 0 || previewSize.height <= 0) return;
    if (_selected == null) return;
    final fx = (localPosition.dx / previewSize.width).clamp(0.10, 0.90);
    final fy = (localPosition.dy / previewSize.height).clamp(0.08, 0.95);
    setState(() {
      switch (_selected!) {
        case BattleShareElement.card:
          _cardPos = Offset(fx, fy);
          break;
        case BattleShareElement.wordmark:
          _wordmarkPos = Offset(fx, fy);
          break;
      }
    });
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
          child: Column(
            children: [
              _TopBar(
                onClose: _busy ? null : () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final previewSize = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) =>
                                _handleTap(d.localPosition, previewSize),
                            onPanStart: (d) =>
                                _handlePanStart(d.localPosition, previewSize),
                            onPanUpdate: (d) =>
                                _handlePanUpdate(d.localPosition, previewSize),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: SizedBox(
                                  width: ShareCardSize.story.width,
                                  height: ShareCardSize.story.height,
                                  child: IgnorePointer(child: _cardWidget()),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              // Selection hint — only when nothing is selected the
              // user hasn't figured out the interaction yet.
              if (_selected == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Tap the card or STEPBATTLE title to drag',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              if (_selected != null)
                const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _ShareTarget(
                        icon: Icons.download_rounded,
                        label: 'Save',
                        color: AppColors.primary,
                        onTap: _busy ? null : _onSave,
                      ),
                    ),
                    Expanded(
                      child: _ShareTarget(
                        icon: Icons.auto_stories_outlined,
                        label: 'IG Story',
                        color: const Color(0xFFE1306C),
                        onTap: _busy ? null : _onIgStory,
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
              SizedBox(
                height: 12 + MediaQuery.of(context).viewPadding.bottom,
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
            'Share battle',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

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
