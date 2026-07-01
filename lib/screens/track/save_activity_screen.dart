import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/run_session_provider.dart';
import '../../utils/app_logger.dart';

/// "Save Activity" page — opens when the user taps **End run** on the
/// live track screen. Replaces the old confirm-dialog with a richer
/// flow that lets the runner caption the session and attach up to 5
/// photos before the row hits Supabase.
///
/// Layout (top → bottom):
///
///   • AppBar: `Resume` text button on the left (pops back to the live
///     screen — the session keeps running), `Save Activity` title in
///     the centre.
///   • Name field — pre-filled with whatever the runner typed on the
///     hub OR the auto-default `Run · Jun 28, 8:06 PM`.
///   • Description field — optional, multi-line "How'd it go?".
///   • Stats card — Distance / Pace / Time / Steps / Calories for the
///     session in flight (read from `activeRunSessionProvider`).
///   • Media row — `Add Photos` chip + selected thumbnails (up to 5,
///     `_maxPhotos`).
///   • Bottom CTA — violet "Save Activity" pill. On tap:
///       1. Reads bytes for every selected photo.
///       2. Uploads them to the `track-media` bucket.
///       3. Calls `RunTrackingService.end(...)` with the description
///          and resulting public URLs.
///       4. Navigates to `/track`.
///
/// If the user backs out via the system back button or the `Resume`
/// button, NO state mutation happens — the session is still alive on
/// the next live screen entry.
class SaveActivityScreen extends ConsumerStatefulWidget {
  const SaveActivityScreen({super.key});

  @override
  ConsumerState<SaveActivityScreen> createState() => _SaveActivityScreenState();
}

class _SaveActivityScreenState extends ConsumerState<SaveActivityScreen> {
  /// Cap on the number of attached photos. Photo-only for v1; video
  /// can come back in a later cycle (codec / thumbnail / size limits
  /// add complexity we don't need yet).
  static const int _maxPhotos = 5;

  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _picker = ImagePicker();

  /// User-selected photos, in display order. Held as `XFile` until the
  /// user hits Save — we only read bytes / upload at that point so
  /// dropping the activity doesn't waste bandwidth.
  final List<XFile> _photos = [];

  bool _saving = false;
  bool _nameSeeded = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _addPhotos() async {
    if (_photos.length >= _maxPhotos) return;
    final remaining = _maxPhotos - _photos.length;
    try {
      // Downscale + re-encode at the OS level before the bytes ever
      // reach us — a raw 4000×3000 camera photo is 4-8 MB, which is
      // slow to upload and pointless for a 1080-wide share-card
      // export. 1920 px on the long edge at JPEG quality 85 gives
      // ~300-500 KB with no visible loss at any share/display size.
      final picked = await _picker.pickMultiImage(
        limit: remaining,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked.isEmpty) return;
      setState(() {
        _photos.addAll(picked.take(remaining));
      });
    } catch (e, s) {
      AppLogger.track.w('saveActivity:pickFailed',
          fields: {'error': e.toString()});
      AppLogger.track.e('saveActivity:pickStack', error: e, stack: s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not open the photo picker.'),
            behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _removePhoto(int index) {
    setState(() => _photos.removeAt(index));
  }

  Future<void> _save() async {
    if (_saving) return;
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) return;
    setState(() => _saving = true);

    final svc = ref.read(runTrackingServiceProvider);
    // Persist the name the user typed on this page back onto the
    // service — `end()` uses whatever name is currently set as the row
    // payload's `name` column. Description goes directly to `end()`.
    final name = _nameController.text.trim();
    if (name.isNotEmpty) svc.setName(name);

    try {
      // ---- 1. Upload media (if any) -------------------------------
      // Photos require network — a DNS-lookup failure or a slow
      // connection would previously leave the button spinning
      // indefinitely. Wrap in a per-upload timeout and, on failure,
      // ask the user whether to save the run without photos so
      // they aren't stuck on this page when offline.
      List<String> urls = const [];
      if (_photos.isNotEmpty) {
        final bytesList = <List<int>>[];
        for (final x in _photos) {
          bytesList.add(await x.readAsBytes());
        }
        try {
          urls = await svc
              .uploadTrackMedia(userId: uid, photoBytes: bytesList)
              .timeout(const Duration(seconds: 25));
        } catch (uploadError, uploadStack) {
          AppLogger.track.w(
            'saveActivity:mediaUploadFailed',
            fields: {'error': uploadError.toString()},
          );
          AppLogger.track.e('saveActivity:mediaUploadStack',
              error: uploadError, stack: uploadStack);
          if (!mounted) return;
          final saveWithoutPhotos = await _askSaveWithoutPhotos();
          if (saveWithoutPhotos != true) return;
          urls = const [];
        }
      }

      // ---- 2. End the run with description + media URLs ------------
      final result = await svc.end(
        description: _descController.text,
        mediaUrls: urls,
      );

      if (!mounted) return;
      ref.invalidate(runSessionHistoryProvider);

      if (result != null) {
        final s = result.session;
        final km = (s.distanceMeters / 1000).toStringAsFixed(2);
        final msg = result.synced
            ? 'Saved · $km km · ${s.steps} steps'
            : 'Stored locally · $km km · ${s.steps} steps. Will sync when you\'re back online.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: Duration(seconds: result.synced ? 3 : 6),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      context.go('/track');
    } catch (e, s) {
      AppLogger.track.e('saveActivity:saveFailed', error: e, stack: s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Ask the user whether to save the session without the photos when
  /// the upload timed out or errored. Returning `null` counts as a
  /// cancel — the caller stays on the Save Activity page.
  Future<bool?> _askSaveWithoutPhotos() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Photos need internet'),
        content: const Text(
          "Couldn't upload the attached photos — the network looks "
          "unavailable. You can save the run without them for now; "
          "the run itself is stored locally and will sync when "
          "you're back online.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save without photos'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionAsync = ref.watch(activeRunSessionProvider);
    final session = sessionAsync.valueOrNull;

    // Seed the name field once from whatever the runner typed on the
    // hub. Pre-populating later would clobber edits.
    if (!_nameSeeded && session != null) {
      _nameSeeded = true;
      final initial = session.name ?? session.displayName;
      _nameController.text = initial;
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leadingWidth: 96,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: TextButton(
            // "Resume" pops back to the live screen — the session is
            // still alive (we never called `end()`).
            onPressed: _saving ? null : () => context.pop(),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onSurface,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            child: const Text('Resume'),
          ),
        ),
        centerTitle: true,
        title: Text(
          'Save Activity',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.fromLTRB(20, 16, 20, 100),
                children: [
                  _NameField(controller: _nameController),
                  const SizedBox(height: 12),
                  _DescriptionField(controller: _descController),
                  const SizedBox(height: 20),
                  _StatsCard(
                    distanceMeters: session?.distanceMeters ?? 0,
                    paceSecPerKm: session?.avgPaceSecPerKm,
                    durationSeconds: session?.durationSeconds ?? 0,
                    steps: session?.steps ?? 0,
                    calories: session?.calories ?? 0,
                  ),
                  const SizedBox(height: 24),
                  _MediaSection(
                    photos: _photos,
                    maxPhotos: _maxPhotos,
                    onAdd: _addPhotos,
                    onRemove: _removePhoto,
                  ),
                ],
              ),
            ),
            _SaveBar(saving: _saving, onSave: _save),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Name field
// =============================================================================

class _NameField extends StatelessWidget {
  final TextEditingController controller;
  const _NameField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: 60,
      textInputAction: TextInputAction.next,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      decoration: const InputDecoration(
        hintText: 'Name this activity',
        counterText: '',
      ),
    );
  }
}

// =============================================================================
// Description field
// =============================================================================

class _DescriptionField extends StatelessWidget {
  final TextEditingController controller;
  const _DescriptionField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: 400,
      maxLines: 4,
      minLines: 3,
      textInputAction: TextInputAction.newline,
      decoration: const InputDecoration(
        hintText: "How'd it go? (optional)",
        counterText: '',
        alignLabelWithHint: true,
      ),
    );
  }
}

// =============================================================================
// Stats card
// =============================================================================

class _StatsCard extends StatelessWidget {
  final double distanceMeters;
  final double? paceSecPerKm;
  final int durationSeconds;
  final int steps;
  final int calories;

  const _StatsCard({
    required this.distanceMeters,
    required this.paceSecPerKm,
    required this.durationSeconds,
    required this.steps,
    required this.calories,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final km = distanceMeters / 1000.0;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SESSION STATS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              letterSpacing: 2,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'Distance',
                  value: km.toStringAsFixed(2),
                  unit: 'km',
                ),
              ),
              Expanded(
                child: _Stat(
                  label: 'Pace',
                  value: _fmtPace(paceSecPerKm),
                  unit: '/km',
                ),
              ),
              Expanded(
                child: _Stat(
                  label: 'Time',
                  value: _fmtDuration(durationSeconds),
                  unit: '',
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'Steps',
                  value: '$steps',
                  unit: '',
                ),
              ),
              Expanded(
                child: _Stat(
                  label: 'Burnt',
                  value: '$calories',
                  unit: 'kcal',
                ),
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtPace(double? secPerKm) {
    if (secPerKm == null || secPerKm.isNaN || !secPerKm.isFinite) {
      return '--';
    }
    final mins = secPerKm ~/ 60;
    final secs = (secPerKm % 60).round();
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  static String _fmtDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  const _Stat(
      {required this.label, required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(
                unit,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// Media section
// =============================================================================

class _MediaSection extends StatelessWidget {
  final List<XFile> photos;
  final int maxPhotos;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  const _MediaSection({
    required this.photos,
    required this.maxPhotos,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final atCap = photos.length >= maxPhotos;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'PHOTOS',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${photos.length} / $maxPhotos',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 88,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              if (!atCap)
                _AddPhotoTile(onTap: onAdd),
              for (var i = 0; i < photos.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _PhotoThumb(
                    file: photos[i],
                    onRemove: () => onRemove(i),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddPhotoTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.35),
            width: 1.2,
            style: BorderStyle.solid,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined,
                color: AppColors.primary, size: 22),
            const SizedBox(height: 4),
            Text(
              'Add',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final XFile file;
  final VoidCallback onRemove;
  const _PhotoThumb({required this.file, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 88,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: FutureBuilder<List<int>>(
              future: file.readAsBytes(),
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done ||
                    snap.data == null) {
                  return Container(
                    color: AppColors.surfaceContainerHigh,
                    child: const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                return Image.memory(
                  Uint8List.fromList(snap.data!),
                  width: 88,
                  height: 88,
                  fit: BoxFit.cover,
                );
              },
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: AppColors.error,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColors.background, width: 1.5),
                ),
                child: const Icon(Icons.close,
                    color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Bottom Save bar — pinned, with the primary action
// =============================================================================

class _SaveBar extends StatelessWidget {
  final bool saving;
  final VoidCallback onSave;
  const _SaveBar({required this.saving, required this.onSave});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          top: BorderSide(
              color: AppColors.outlineVariant.withValues(alpha: 0.3)),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 54,
        child: FilledButton(
          onPressed: saving ? null : onSave,
          child: saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white),
                )
              : const Text('Save Activity',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  )),
        ),
      ),
    );
  }
}
