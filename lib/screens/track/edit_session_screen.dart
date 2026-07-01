import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/colors.dart';
import '../../models/run_session_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/run_session_provider.dart';
import '../../utils/app_logger.dart';

/// Edit an already-saved Track session.
///
/// Reached from the pencil icon on the session detail screen. Lets the
/// user update:
///   • Name.
///   • Description.
///   • Attached photos — existing photos can be removed by tapping ×
///     on their thumbnail; new photos can be added via the picker up
///     to the 5-photo cap.
///
/// Save uploads any newly-added photos to Storage, merges the resulting
/// URLs with the surviving originals, and PATCHes the row. Existing
/// photos removed from the list are dropped from `media_urls`; the
/// orphaned Storage files are left in place (a periodic cleanup job
/// is a future concern — the row no longer references them).
class EditSessionScreen extends ConsumerStatefulWidget {
  final String sessionId;
  const EditSessionScreen({super.key, required this.sessionId});

  @override
  ConsumerState<EditSessionScreen> createState() =>
      _EditSessionScreenState();
}

class _EditSessionScreenState extends ConsumerState<EditSessionScreen> {
  static const int _maxPhotos = 5;

  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _picker = ImagePicker();

  /// Photos already stored on the row — start as the session's URL
  /// list and are stripped by the user via the × affordance.
  final List<String> _existingUrls = [];

  /// New photos picked in this edit session, not yet uploaded.
  final List<XFile> _newPhotos = [];

  bool _seeded = false;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _seedFromSession(RunSession s) {
    if (_seeded) return;
    _seeded = true;
    _nameController.text = s.name?.trim().isNotEmpty == true
        ? s.name!
        : s.displayName;
    _descController.text = s.description ?? '';
    _existingUrls
      ..clear()
      ..addAll(s.mediaUrls);
  }

  int get _totalCount => _existingUrls.length + _newPhotos.length;
  bool get _atCap => _totalCount >= _maxPhotos;

  Future<void> _addPhotos() async {
    if (_atCap) return;
    final remaining = _maxPhotos - _totalCount;
    try {
      // Same downscale as save_activity: 1920 px max edge / JPEG 85
      // keeps upload payload small (~300-500 KB per photo) with no
      // visible loss at any display or share-export size.
      final picked = await _picker.pickMultiImage(
        limit: remaining,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked.isEmpty) return;
      setState(() => _newPhotos.addAll(picked.take(remaining)));
    } catch (e, s) {
      AppLogger.track.e('editSession:pickFailed', error: e, stack: s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the photo picker.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _removeExisting(int index) {
    setState(() => _existingUrls.removeAt(index));
  }

  void _removeNew(int index) {
    setState(() => _newPhotos.removeAt(index));
  }

  Future<void> _save() async {
    if (_saving) return;
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) return;
    setState(() => _saving = true);

    final svc = ref.read(runTrackingServiceProvider);
    try {
      // ---- 1. Upload new photos (with timeout + graceful fallback) ---
      List<String> newUrls = const [];
      if (_newPhotos.isNotEmpty) {
        final bytesList = <List<int>>[];
        for (final x in _newPhotos) {
          bytesList.add(await x.readAsBytes());
        }
        try {
          newUrls = await svc
              .uploadTrackMedia(userId: uid, photoBytes: bytesList)
              .timeout(const Duration(seconds: 25));
        } catch (uploadError, uploadStack) {
          AppLogger.track.e('editSession:mediaUploadFailed',
              error: uploadError, stack: uploadStack);
          if (!mounted) return;
          final skip = await _askSaveWithoutNewPhotos();
          if (skip != true) return;
          newUrls = const [];
        }
      }

      // ---- 2. Merge + patch --------------------------------------------
      final mergedUrls = [..._existingUrls, ...newUrls];
      final ok = await svc.updateSession(
        sessionId: widget.sessionId,
        name: _nameController.text,
        description: _descController.text,
        mediaUrls: mergedUrls,
      );

      if (!mounted) return;
      if (ok) {
        ref.invalidate(trackSessionByIdProvider(widget.sessionId));
        ref.invalidate(runSessionHistoryProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Changes saved.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
        context.pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Save failed. Try again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e, s) {
      AppLogger.track.e('editSession:saveFailed', error: e, stack: s);
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

  Future<bool?> _askSaveWithoutNewPhotos() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Photos need internet'),
        content: const Text(
          "Couldn't upload the new photos — the network looks "
          'unavailable. Save the other changes without them?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save without new photos'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionAsync =
        ref.watch(trackSessionByIdProvider(widget.sessionId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _saving ? null : () => context.pop(),
        ),
        title: Text('Edit Activity',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5),
                  )
                : const Text('Save',
                    style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: sessionAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load: $e'),
          ),
        ),
        data: (session) {
          if (session == null) {
            return Center(
              child: Text(
                'Session no longer exists.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
            );
          }
          _seedFromSession(session);

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              TextField(
                controller: _nameController,
                maxLength: 60,
                textInputAction: TextInputAction.next,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 16),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _descController,
                maxLength: 400,
                minLines: 3,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  labelText: "How'd it go? (optional)",
                  counterText: '',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 24),
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
                    '$_totalCount / $_maxPhotos',
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
                    if (!_atCap) _AddPhotoTile(onTap: _addPhotos),
                    for (var i = 0; i < _existingUrls.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _ExistingThumb(
                          url: _existingUrls[i],
                          onRemove: () => _removeExisting(i),
                        ),
                      ),
                    for (var i = 0; i < _newPhotos.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _LocalThumb(
                          file: _newPhotos[i],
                          onRemove: () => _removeNew(i),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// Photo tiles
// =============================================================================

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

class _ExistingThumb extends StatelessWidget {
  final String url;
  final VoidCallback onRemove;
  const _ExistingThumb({required this.url, required this.onRemove});

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
            child: Image.network(
              url,
              width: 88,
              height: 88,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return Container(
                  color: AppColors.surfaceContainerHigh,
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              },
              errorBuilder: (_, __, ___) => Container(
                color: AppColors.surfaceContainerHigh,
                alignment: Alignment.center,
                child: Icon(Icons.broken_image_outlined,
                    color: AppColors.onSurfaceVariant, size: 22),
              ),
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: _RemoveDot(onTap: onRemove),
          ),
        ],
      ),
    );
  }
}

class _LocalThumb extends StatelessWidget {
  final XFile file;
  final VoidCallback onRemove;
  const _LocalThumb({required this.file, required this.onRemove});

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
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 18,
                      height: 18,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
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
            child: _RemoveDot(onTap: onRemove),
          ),
        ],
      ),
    );
  }
}

class _RemoveDot extends StatelessWidget {
  final VoidCallback onTap;
  const _RemoveDot({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: AppColors.error,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.background, width: 1.5),
        ),
        child: const Icon(Icons.close, color: Colors.white, size: 14),
      ),
    );
  }
}
