import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';
import '../services/share_card_service.dart';
import '../widgets/share_cards/share_card_size.dart';
import '../widgets/share_cards/streak_share_card.dart';

/// Share sheet for the user's current daily-step streak.
///
/// Same layout family as `showBattleStatusShareSheet` and the Track
/// share sheet — preview at top, four action tiles below, no
/// carousel (only one card variant).
Future<void> showStreakShareSheet(
  BuildContext context, {
  required int currentStreak,
  required int bestStreak,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _StreakShareSheet(
      currentStreak: currentStreak,
      bestStreak: bestStreak,
    ),
  );
}

class _StreakShareSheet extends StatefulWidget {
  final int currentStreak;
  final int bestStreak;
  const _StreakShareSheet({
    required this.currentStreak,
    required this.bestStreak,
  });

  @override
  State<_StreakShareSheet> createState() => _StreakShareSheetState();
}

class _StreakShareSheetState extends State<_StreakShareSheet> {
  bool _busy = false;

  Widget _cardWidget() => StreakShareCard(
        currentStreak: widget.currentStreak,
        bestStreak: widget.bestStreak,
        size: ShareCardSize.story,
      );

  Future<Uint8List> _render() => ShareCardService.renderToPng(
        widget: _cardWidget(),
        logicalSize: ShareCardSize.story.logicalSize,
        pixelRatio: 1.0,
        settleDelay: const Duration(milliseconds: 300),
      );

  String _filename(String ext) =>
      'stepbattle_streak_${widget.currentStreak}.$ext';

  String _defaultCaption() {
    final n = widget.currentStreak;
    if (n == 0) return 'Chasing a fresh streak on StepBattle 🔥';
    if (n == 1) return 'Day 1 of a new streak on StepBattle 🔥';
    return '$n-day streak on StepBattle 🔥';
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
        final launched =
            await ShareCardService.tryOpenInstagramStories(path);
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
                    ),
                  ),
                ),
              ),
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
            'Share streak',
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
