import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/colors.dart';
import '../../models/avatar.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../services/native_step_service.dart';
import '../profile/public_profile_screen.dart';

/// "Battle Status" page — a richer post-battle results view for
/// COMPLETED battles only.
///
/// Each accepted participant is rendered as a freely-DRAGGABLE card
/// (avatar + stats). The user can rearrange the cards anywhere on the
/// canvas — positions are persisted per battle in Hive under
/// `battle_layout_<battleId>` so the arrangement survives navigation.
///
/// The winner's card sits slightly larger and has a continuous star-
/// particle animation overlaid behind it.
///
/// Background: defaults to a tasteful dark plate. The user can tap the
/// camera FAB and pick a photo from their gallery (or the curated
/// preset list) to replace it. Per-battle in Hive too.
class BattleStatusScreen extends ConsumerStatefulWidget {
  final String battleId;
  const BattleStatusScreen({super.key, required this.battleId});

  @override
  ConsumerState<BattleStatusScreen> createState() =>
      _BattleStatusScreenState();
}

class _BattleStatusScreenState
    extends ConsumerState<BattleStatusScreen>
    with SingleTickerProviderStateMixin {
  /// One Ticker drives the star particle animation. Reading `_t` in
  /// build() inside Positioned descendants triggers per-frame rebuilds
  /// only of the painter — Stack itself is unaffected.
  late final Ticker _ticker;
  double _t = 0;

  /// Last drag positions, per participant userId. Offsets are stored in
  /// LOGICAL (display-independent) coordinates — fraction of the canvas
  /// width/height — so the layout survives orientation/resize.
  final Map<String, Offset> _positions = {};

  /// Either a local file path (image_picker) or one of the curated
  /// preset asset paths. Persisted in Hive.
  String? _backgroundPath;
  bool _backgroundIsAsset = false;

  static String _hiveKeyFor(String battleId) =>
      'battle_layout_$battleId';

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      setState(() => _t = d.inMicroseconds / 1e6);
    })..start();
    _restoreFromHive();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _restoreFromHive() {
    try {
      final box = Hive.box(NativeStepService.boxName);
      final raw = box.get(_hiveKeyFor(widget.battleId));
      if (raw is! Map) return;
      final positions = raw['positions'];
      if (positions is Map) {
        for (final entry in positions.entries) {
          final v = entry.value;
          if (v is Map && v['x'] is num && v['y'] is num) {
            _positions[entry.key.toString()] = Offset(
              (v['x'] as num).toDouble(),
              (v['y'] as num).toDouble(),
            );
          }
        }
      }
      _backgroundPath = raw['bg'] as String?;
      _backgroundIsAsset = raw['bgIsAsset'] as bool? ?? false;
      setState(() {});
    } catch (_) {/* ignore corrupted entries */}
  }

  void _saveToHive() {
    try {
      final box = Hive.box(NativeStepService.boxName);
      box.put(_hiveKeyFor(widget.battleId), {
        'positions': _positions.map(
          (k, v) => MapEntry(k, {'x': v.dx, 'y': v.dy}),
        ),
        'bg': _backgroundPath,
        'bgIsAsset': _backgroundIsAsset,
      });
    } catch (_) {}
  }

  Future<void> _pickBackground() async {
    final choice = await showModalBottomSheet<_BgChoice>(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      builder: (_) => const _BackgroundPickerSheet(),
    );
    if (choice == null) return;
    if (choice.assetPath != null) {
      setState(() {
        _backgroundPath = choice.assetPath;
        _backgroundIsAsset = true;
      });
      _saveToHive();
      return;
    }
    // From gallery — image_picker returns a local file path.
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2000,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      _backgroundPath = picked.path;
      _backgroundIsAsset = false;
    });
    _saveToHive();
  }

  @override
  Widget build(BuildContext context) {
    final asyncBattle = ref.watch(battleDetailProvider(widget.battleId));
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Battle Status'),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: 'Change background',
            onPressed: _pickBackground,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset layout',
            onPressed: () {
              setState(() => _positions.clear());
              _saveToHive();
            },
          ),
        ],
      ),
      body: asyncBattle.when(
        loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.primary),
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
                padding: EdgeInsets.all(24),
                child: Text(
                  'Battle Status opens once the battle has ended.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
            );
          }
          return LayoutBuilder(builder: (ctx, c) {
            final accepted = battle.participants
                .where((p) =>
                    p.inviteStatus == ParticipantInviteStatus.accepted)
                .toList();

            // Seed default positions for participants without a saved
            // location. Winner sits centred slightly high, others fan
            // out around them.
            final winnerId = battle.winnerId;
            for (var i = 0; i < accepted.length; i++) {
              final p = accepted[i];
              if (_positions.containsKey(p.userId)) continue;
              _positions[p.userId] = _defaultSeedPosition(
                index: i,
                total: accepted.length,
                isWinner: p.userId == winnerId,
              );
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                // Background — preset asset or user-picked photo.
                _Background(
                  path: _backgroundPath,
                  isAsset: _backgroundIsAsset,
                ),
                // Subtle dark gradient overlay so cards stay legible
                // against busy backgrounds.
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x66000000), Color(0x33000000)],
                      ),
                    ),
                    child: SizedBox.expand(),
                  ),
                ),

                // Cards — one per accepted participant.
                for (final p in accepted)
                  _DraggableParticipantCard(
                    key: ValueKey(p.userId),
                    participant: p,
                    isWinner: p.userId == winnerId,
                    isMe: p.userId == uid,
                    canvasSize: Size(c.maxWidth, c.maxHeight),
                    position: _positions[p.userId]!,
                    time: _t,
                    onPositionChanged: (offset) {
                      _positions[p.userId] = offset;
                    },
                    onPositionFinalized: (offset) {
                      _positions[p.userId] = offset;
                      _saveToHive();
                    },
                    onTap: p.userId == uid
                        ? null
                        : () => showArenaProfilePeek(context, p.userId),
                  ),
              ],
            );
          });
        },
      ),
    );
  }

  Offset _defaultSeedPosition({
    required int index,
    required int total,
    required bool isWinner,
  }) {
    // Position values are normalized to canvas size (0..1) so they
    // survive orientation changes. Winner anchored at the top-centre,
    // others distributed below.
    if (isWinner) return const Offset(0.5, 0.28);
    final ringSlot = total <= 1 ? 0 : index % math.max(1, total - 1);
    final spread = total <= 1 ? 0 : ringSlot / math.max(1, total - 1);
    return Offset(
      0.20 + spread * 0.60,
      0.55 + (index.isOdd ? 0.10 : 0.0),
    );
  }
}

// =============================================================================
// Background renderer
// =============================================================================

class _Background extends StatelessWidget {
  final String? path;
  final bool isAsset;
  const _Background({required this.path, required this.isAsset});

  @override
  Widget build(BuildContext context) {
    if (path == null) {
      // Default gradient backdrop.
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1A0F2A),
              Color(0xFF0E0A1A),
            ],
          ),
        ),
        child: SizedBox.expand(),
      );
    }
    if (isAsset) {
      return Image.asset(path!, fit: BoxFit.cover);
    }
    // Local file from image_picker.
    return Image.file(File(path!), fit: BoxFit.cover);
  }
}

// =============================================================================
// Draggable participant card with optional star-particle overlay
// =============================================================================

class _DraggableParticipantCard extends StatefulWidget {
  final BattleParticipant participant;
  final bool isWinner;
  final bool isMe;
  final Size canvasSize;
  final Offset position; // normalized 0..1
  final double time;
  final ValueChanged<Offset> onPositionChanged;
  final ValueChanged<Offset> onPositionFinalized;
  final VoidCallback? onTap;

  const _DraggableParticipantCard({
    super.key,
    required this.participant,
    required this.isWinner,
    required this.isMe,
    required this.canvasSize,
    required this.position,
    required this.time,
    required this.onPositionChanged,
    required this.onPositionFinalized,
    this.onTap,
  });

  @override
  State<_DraggableParticipantCard> createState() =>
      _DraggableParticipantCardState();
}

class _DraggableParticipantCardState
    extends State<_DraggableParticipantCard> {
  late Offset _pos;

  @override
  void initState() {
    super.initState();
    _pos = widget.position;
  }

  @override
  void didUpdateWidget(_DraggableParticipantCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt external position changes (e.g., from layout reset) only if
    // the user isn't currently dragging.
    if (oldWidget.position != widget.position) {
      _pos = widget.position;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Card sizing: winners get a 1.2x boost so they're visually
    // dominant. Locked dimensions so the user can predict where the
    // card lands when dragged.
    final scale = widget.isWinner ? 1.2 : 1.0;
    final cardWidth = 150.0 * scale;
    final cardHeight = 180.0 * scale;

    // Convert normalized position → pixel offset on the canvas.
    final pixelLeft = _pos.dx * widget.canvasSize.width - cardWidth / 2;
    final pixelTop = _pos.dy * widget.canvasSize.height - cardHeight / 2;

    return Positioned(
      left: pixelLeft,
      top: pixelTop,
      width: cardWidth,
      height: cardHeight,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanUpdate: (details) {
          // Convert pixel delta → normalized delta.
          final dx = details.delta.dx / widget.canvasSize.width;
          final dy = details.delta.dy / widget.canvasSize.height;
          final next = Offset(
            (_pos.dx + dx).clamp(0.05, 0.95),
            (_pos.dy + dy).clamp(0.05, 0.95),
          );
          setState(() => _pos = next);
          widget.onPositionChanged(next);
        },
        onPanEnd: (_) {
          widget.onPositionFinalized(_pos);
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Stars overlay (winner only) — drawn first so card sits on top.
            if (widget.isWinner)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _StarsPainter(
                      time: widget.time,
                      seed: widget.participant.userId.hashCode,
                    ),
                  ),
                ),
              ),
            // Card body.
            _ParticipantCardBody(
              participant: widget.participant,
              isWinner: widget.isWinner,
              isMe: widget.isMe,
              cardWidth: cardWidth,
              cardHeight: cardHeight,
            ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantCardBody extends StatelessWidget {
  final BattleParticipant participant;
  final bool isWinner;
  final bool isMe;
  final double cardWidth;
  final double cardHeight;

  const _ParticipantCardBody({
    required this.participant,
    required this.isWinner,
    required this.isMe,
    required this.cardWidth,
    required this.cardHeight,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = isWinner ? AppColors.tertiary : AppColors.primary;
    final avatarId =
        participant.battleAvatarId ?? Avatar.defaultAvatar.id;
    return Container(
      width: cardWidth,
      height: cardHeight,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.6), width: 2),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.35),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isWinner)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.tertiary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'WINNER',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                    color: Colors.black,
                  ),
                ),
              )
            else if (isMe)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  'YOU',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                    color: AppColors.primary,
                  ),
                ),
              )
            else
              const SizedBox(height: 16),
            const SizedBox(height: 6),
            Expanded(
              child: Image.asset(
                Avatar.byId(avatarId).assetPath,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              participant.displayName.isEmpty
                  ? '—'
                  : participant.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${participant.currentSteps} steps',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Star-particle painter for the winner overlay
// =============================================================================

class _StarsPainter extends CustomPainter {
  final double time;
  final int seed;
  _StarsPainter({required this.time, required this.seed});

  static const int _starCount = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final rand = math.Random(seed);
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < _starCount; i++) {
      final baseX = rand.nextDouble();
      final baseY = rand.nextDouble();
      final speed = 0.6 + rand.nextDouble() * 0.8;
      // Twinkle phase — pulse alpha + size on a sine wave.
      final phase = (time * speed + i * 0.5) % 1.0;
      final twinkle = (math.sin(phase * math.pi * 2) + 1) / 2; // 0..1
      final alpha = (0.4 + twinkle * 0.6).clamp(0.0, 1.0);
      final radius = 1.5 + twinkle * 2.5;
      paint.color = Color.fromRGBO(
        255,
        220,
        130,
        alpha,
      );
      canvas.drawCircle(
        Offset(baseX * size.width, baseY * size.height),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StarsPainter oldDelegate) =>
      oldDelegate.time != time;
}

// =============================================================================
// Background picker sheet
// =============================================================================

class _BgChoice {
  final String? assetPath; // null = gallery pick
  const _BgChoice.gallery() : assetPath = null;
  const _BgChoice.asset(this.assetPath);
}

class _BackgroundPickerSheet extends StatelessWidget {
  const _BackgroundPickerSheet();

  /// Curated preset backgrounds. Reuses the battleground tile art we
  /// already ship so we don't need new assets just for this picker.
  static const _presets = <_PresetBg>[
    _PresetBg(
      label: 'Forest (Morning)',
      assetPath: 'assets/images/battleground/morningVersion.png',
    ),
    _PresetBg(
      label: 'Forest (Evening)',
      assetPath: 'assets/images/battleground/eveningVersion.png',
    ),
    _PresetBg(
      label: 'Forest (Night)',
      assetPath: 'assets/images/battleground/nightVersion.png',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Background',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            // Gallery pick row.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.photo_library_outlined,
                  color: AppColors.primary),
              title: const Text('Pick from gallery'),
              onTap: () =>
                  Navigator.of(context).pop(const _BgChoice.gallery()),
            ),
            const Divider(),
            // Presets grid.
            Text('OR PICK A PRESET',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w800,
                )),
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _presets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  final p = _presets[i];
                  return GestureDetector(
                    onTap: () => Navigator.of(context)
                        .pop(_BgChoice.asset(p.assetPath)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 80,
                        height: 100,
                        child: Image.asset(p.assetPath, fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetBg {
  final String label;
  final String assetPath;
  const _PresetBg({required this.label, required this.assetPath});
}
