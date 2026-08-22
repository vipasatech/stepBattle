import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/colors.dart';
import '../../config/motion.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../services/native_step_service.dart';
import '../../sheets/battle_status_share_sheet.dart';
import '../../widgets/battle_result_card.dart';
import '../../widgets/shimmer_loader.dart';
import '../../widgets/themed_battle_background.dart';

/// **Battle Status** — the post-battle result page for completed
/// battles.
///
/// Layout (fully rewritten from the earlier per-avatar draggable
/// build):
///   • **Background**: user-picked photo (falls back to the themed
///     violet-gradient + battleground silhouette). Swipe left / right
///     to toggle between the two.
///   • **Transparent battle card**: draggable, sits over the
///     background. Shows tag (`#1 LAST ONE STANDING` / `OUTFLANKED` /
///     `DEAD HEAT`), `{me} vs {opp}`, two-tone scores + bar, XP
///     footer. Same widget renders inside the share PNG.
///   • **STEPBATTLE wordmark**: draggable, italic-bold Manrope. Two
///     draggable overlays, both persisted per-battle in Hive.
///
/// The share action reuses whatever background + overlay positions
/// the user chose — the share PNG is a true snapshot of what they
/// see on screen.
class BattleStatusScreen extends ConsumerStatefulWidget {
  final String battleId;
  const BattleStatusScreen({super.key, required this.battleId});

  @override
  ConsumerState<BattleStatusScreen> createState() =>
      _BattleStatusScreenState();
}

class _BattleStatusScreenState extends ConsumerState<BattleStatusScreen> {
  /// Draggable overlay positions in FRACTIONAL canvas coordinates
  /// (0.0..1.0). Defaults match the share sheet: wordmark near the
  /// top (row ~2), card near the vertical middle-lower (row ~4).
  Offset _cardPos = defaultBattleCardPos;
  Offset _wordmarkPos = defaultBattleWordmarkPos;

  /// Background state:
  ///   • `_photoPath` set + `_useThemed = false` → user-picked photo
  ///     (either a file path from image_picker or a bundled asset).
  ///   • `_useThemed = true`  → themed violet/silhouette painter.
  ///   • Neither set → prompt for a photo the first time the user
  ///     tries to share, else render the themed background.
  String? _photoPath;
  bool _useThemed = false;

  static String _hiveKeyFor(String battleId) =>
      'battle_status_v2_$battleId';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  void _restore() {
    try {
      final box = Hive.box(NativeStepService.boxName);
      final raw = box.get(_hiveKeyFor(widget.battleId));
      if (raw is! Map) return;
      final card = raw['card'];
      if (card is Map && card['x'] is num && card['y'] is num) {
        _cardPos = Offset(
          (card['x'] as num).toDouble(),
          (card['y'] as num).toDouble(),
        );
      }
      final wm = raw['wordmark'];
      if (wm is Map && wm['x'] is num && wm['y'] is num) {
        _wordmarkPos = Offset(
          (wm['x'] as num).toDouble(),
          (wm['y'] as num).toDouble(),
        );
      }
      _photoPath = raw['photo'] as String?;
      _useThemed = raw['useThemed'] as bool? ?? false;
      setState(() {});
    } catch (_) {/* corrupted entry — start fresh */}
  }

  void _save() {
    try {
      final box = Hive.box(NativeStepService.boxName);
      box.put(_hiveKeyFor(widget.battleId), {
        'card': {'x': _cardPos.dx, 'y': _cardPos.dy},
        'wordmark': {'x': _wordmarkPos.dx, 'y': _wordmarkPos.dy},
        'photo': _photoPath,
        'useThemed': _useThemed,
      });
    } catch (_) {}
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2000,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      _photoPath = picked.path;
      _useThemed = false;
    });
    _save();
  }

  /// Called by the horizontal swipe detector. Positive velocity =
  /// swipe right (finger dragged left→right) — toggle away from the
  /// photo to the themed background. Negative = swipe left — toggle
  /// back to the photo when one is set.
  void _onHorizontalFling(double vx) {
    if (vx > 0) {
      setState(() => _useThemed = true);
    } else if (_photoPath != null) {
      setState(() => _useThemed = false);
    }
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final asyncBattle = ref.watch(battleDetailProvider(widget.battleId));
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          asyncBattle.when(
            data: (b) => (b != null && b.status == BattleStatus.completed)
                ? IconButton(
                    icon: const Icon(Icons.ios_share, color: Colors.white),
                    tooltip: 'Share',
                    onPressed: () => _onShare(b, uid),
                  )
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          IconButton(
            icon: const Icon(Icons.photo_camera_outlined,
                color: Colors.white),
            tooltip: 'Change background',
            onPressed: _pickPhoto,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: 'Reset layout',
            onPressed: () {
              setState(() {
                _cardPos = defaultBattleCardPos;
                _wordmarkPos = defaultBattleWordmarkPos;
              });
              _save();
            },
          ),
        ],
      ),
      body: asyncBattle.when(
        loading: () => ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: const [
            ShimmerLoader(height: 180, borderRadius: 20),
            SizedBox(height: 16),
            ShimmerCard(),
            SizedBox(height: 12),
            ShimmerCard(),
          ],
        ),
        error: (e, _) => Center(
          child: Text('Could not load battle: $e',
              style: const TextStyle(color: Colors.white)),
        ),
        data: (battle) {
          if (battle == null) {
            return const Center(
              child: Text('Battle not found',
                  style: TextStyle(color: Colors.white)),
            );
          }
          if (battle.status != BattleStatus.completed) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Battle Status opens once the battle has ended.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
            );
          }
          // Content-appear on first canvas paint: scale 0.96 → 1.0 +
          // fade, matches the scaleFade page transition timing so the
          // page transition and the canvas contents feel like one
          // coordinated arrival instead of a hard cut once the data
          // resolves. flutter_animate's default one-shot behaviour
          // means this only fires the first time the canvas paints
          // after the battle loads — no replay on drag/settle.
          return _Canvas(
            battle: battle,
            uid: uid,
            cardPos: _cardPos,
            wordmarkPos: _wordmarkPos,
            photoPath: _photoPath,
            useThemed: _useThemed,
            onCardMoved: (o) {
              setState(() => _cardPos = o);
            },
            onCardSettled: () => _save(),
            onWordmarkMoved: (o) {
              setState(() => _wordmarkPos = o);
            },
            onWordmarkSettled: () => _save(),
            onHorizontalFling: _onHorizontalFling,
          )
              .animate()
              .fadeIn(
                duration: Motion.d.slow,
                curve: Motion.curves.standard,
              )
              .scale(
                begin: const Offset(0.96, 0.96),
                end: const Offset(1.0, 1.0),
                duration: Motion.d.slow,
                curve: Motion.curves.emphasized,
              );
        },
      ),
    );
  }

  /// Share entry point. If the user hasn't picked a photo AND hasn't
  /// explicitly chosen the themed background, prompt for a photo now
  /// (per the "reuse Battle Status photo → prompt if none" spec).
  Future<void> _onShare(BattleModel battle, String uid) async {
    if (_photoPath == null && !_useThemed) {
      await _pickPhoto();
    }
    if (!mounted) return;
    await showBattleStatusShareSheet(
      context,
      battle: battle,
      uid: uid,
      photoPath: _photoPath,
      useThemed: _useThemed,
      cardPos: _cardPos,
      wordmarkPos: _wordmarkPos,
    );
  }
}

/// The interactive canvas — background + two draggable overlays +
/// horizontal swipe detector for switching background modes.
class _Canvas extends StatelessWidget {
  final BattleModel battle;
  final String uid;
  final Offset cardPos;
  final Offset wordmarkPos;
  final String? photoPath;
  final bool useThemed;
  final ValueChanged<Offset> onCardMoved;
  final VoidCallback onCardSettled;
  final ValueChanged<Offset> onWordmarkMoved;
  final VoidCallback onWordmarkSettled;
  final ValueChanged<double> onHorizontalFling;

  const _Canvas({
    required this.battle,
    required this.uid,
    required this.cardPos,
    required this.wordmarkPos,
    required this.photoPath,
    required this.useThemed,
    required this.onCardMoved,
    required this.onCardSettled,
    required this.onWordmarkMoved,
    required this.onWordmarkSettled,
    required this.onHorizontalFling,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final canvas = Size(c.maxWidth, c.maxHeight);
      return GestureDetector(
        // Horizontal fling on empty canvas toggles background mode.
        // Vertical drags fall through so the draggable overlays can
        // handle their own gestures unimpeded.
        onHorizontalDragEnd: (details) {
          final vx = details.primaryVelocity ?? 0;
          if (vx.abs() < 300) return; // too slow — ignore
          onHorizontalFling(vx);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background — one of three states.
            _BackgroundLayer(
              photoPath: photoPath,
              useThemed: useThemed,
              cardCenterFraction: cardPos.dy,
            ),
            // Draggable transparent battle card.
            _DraggableOverlay(
              position: cardPos,
              canvas: canvas,
              onMoved: onCardMoved,
              onSettled: onCardSettled,
              child: SizedBox(
                width: canvas.width * 0.86,
                child: BattleResultCard(battle: battle, uid: uid),
              ),
            ),
            // Draggable STEPBATTLE wordmark.
            _DraggableOverlay(
              position: wordmarkPos,
              canvas: canvas,
              onMoved: onWordmarkMoved,
              onSettled: onWordmarkSettled,
              child: const _Wordmark(),
            ),
          ],
        ),
      );
    });
  }
}

/// Renders the current background layer. Priority:
///   1. `useThemed == true`  → themed painter.
///   2. `photoPath != null`  → user-picked photo (file path from
///      image_picker; asset paths also work here transparently thanks
///      to `Image.file` vs `Image.asset` picking).
///   3. Otherwise fall back to the themed painter so the screen
///      never looks broken.
class _BackgroundLayer extends StatelessWidget {
  final String? photoPath;
  final bool useThemed;
  final double cardCenterFraction;
  const _BackgroundLayer({
    required this.photoPath,
    required this.useThemed,
    required this.cardCenterFraction,
  });

  @override
  Widget build(BuildContext context) {
    if (useThemed || photoPath == null) {
      return ThemedBattleBackground(cardCenterFraction: cardCenterFraction);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(File(photoPath!), fit: BoxFit.cover),
        // Subtle dark scrim so overlay text stays legible over busy
        // photos.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x55000000), Color(0x22000000)],
            ),
          ),
          child: SizedBox.expand(),
        ),
      ],
    );
  }
}

/// The italic-bold STEPBATTLE wordmark that lives as the second
/// draggable overlay. Matches the welcome-carousel + app-bar
/// treatment: uppercase, Manrope italic, wide letter-spacing.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'STEPBATTLE',
      style: TextStyle(
        color: Colors.white,
        fontFamily: 'Manrope',
        fontStyle: FontStyle.italic,
        fontWeight: FontWeight.w900,
        fontSize: 24,
        letterSpacing: 3,
        shadows: [
          Shadow(color: Color(0xCC000000), blurRadius: 10),
        ],
      ),
    );
  }
}

/// Generic pan-to-move overlay that centres its [child] on a fractional
/// [position] within [canvas]. Emits [onMoved] on every pan update and
/// [onSettled] when the pointer lifts (used to persist to Hive
/// exactly once per interaction).
///
/// Positions are clamped to the [0, 1] range so the user can't drag
/// an overlay past the visible area.
class _DraggableOverlay extends StatelessWidget {
  final Offset position;
  final Size canvas;
  final Widget child;
  final ValueChanged<Offset> onMoved;
  final VoidCallback onSettled;

  const _DraggableOverlay({
    required this.position,
    required this.canvas,
    required this.child,
    required this.onMoved,
    required this.onSettled,
  });

  @override
  Widget build(BuildContext context) {
    final absX = position.dx * canvas.width;
    final absY = position.dy * canvas.height;
    return Positioned(
      left: 0,
      top: 0,
      width: canvas.width,
      height: canvas.height,
      child: IgnorePointer(
        ignoring: false,
        child: Stack(
          children: [
            Positioned(
              left: absX,
              top: absY,
              child: FractionalTranslation(
                translation: const Offset(-0.5, -0.5),
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final newX =
                        ((absX + details.delta.dx) / canvas.width)
                            .clamp(0.05, 0.95);
                    final newY =
                        ((absY + details.delta.dy) / canvas.height)
                            .clamp(0.05, 0.95);
                    onMoved(Offset(newX, newY));
                  },
                  onPanEnd: (_) => onSettled(),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
