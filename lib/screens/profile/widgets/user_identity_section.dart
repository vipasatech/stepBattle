import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../models/user_model.dart';
import '../../../providers/local_profile_photo_provider.dart';
import '../../../widgets/app_network_image.dart';
import '../../../widgets/avatar_circle.dart';
import '../../../widgets/pro_badge.dart';

/// Profile top row — avatar (left) + [name+badge, location, userCode
/// chip] (right). Strava-style; identity only. Stats and action
/// buttons live in their own sibling widgets below this one on the
/// Profile scroll.
class UserIdentitySection extends ConsumerWidget {
  final UserModel user;

  const UserIdentitySection({super.key, required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final locationLine = _locationLine(user);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _AvatarWithEdit(user: user),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Name + verified pro badge (badge auto-hides on Free).
              // Name — matches Strava's profile-header weight/size.
              Row(
                children: [
                  Flexible(
                    child: Text(
                      user.friendlyName,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        height: 1.1,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const ProBadge(size: 18),
                ],
              ),
              // Location — Strava keeps this at ~14 sp gray. Omitted
              // entirely when the user hasn't set a home yet.
              if (locationLine != null) ...[
                const SizedBox(height: 3),
                Text(
                  locationLine,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              // User code chip removed — the "Share my QR Code"
              // button below the stats strip is the primary discovery
              // path for the code now. Kept the widget class around
              // as a private helper in case a caller re-adds it.
            ],
          ),
        ),
      ],
    );
  }

  String? _locationLine(UserModel u) {
    if (!u.hasHome) return null;
    final parts = <String>[
      if ((u.districtName ?? '').isNotEmpty) u.districtName!,
      if ((u.stateName ?? '').isNotEmpty) u.stateName!,
      if ((u.countryName ?? '').isNotEmpty) u.countryName!,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }
}

/// Plain circular avatar — tapping opens a photo-picker sheet
/// (Camera / Gallery / Remove).
///
/// Priority for the circle image: user-picked local photo (device-only,
/// never uploaded) → server-side `avatarURL` → initials.
class _AvatarWithEdit extends ConsumerWidget {
  final UserModel user;
  const _AvatarWithEdit({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localPhotoPath = ref.watch(localProfilePhotoProvider);
    final hasAnyPhoto =
        localPhotoPath != null || (user.avatarURL?.isNotEmpty ?? false);
    // True while a locally-saved photo hasn't been mirrored to
    // Supabase yet. Drives the "Syncing…" chip on the avatar so the
    // user knows why home + leaderboard haven't picked up the new
    // photo yet (they read the server URL, not the local file).
    final pendingUpload = ref
            .watch(pendingProfilePhotoUploadProvider)
            .valueOrNull ??
        false;
    return GestureDetector(
      onTap: () => _showPhotoPickerSheet(
        context,
        ref,
        localPath: localPhotoPath,
        remoteUrl: user.avatarURL,
        hasAnyPhoto: hasAnyPhoto,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AvatarCircle(
            radius: 42,
            localImagePath: localPhotoPath,
            imageUrl: user.avatarURL,
            initials: user.friendlyName.isNotEmpty
                ? user.friendlyName[0].toUpperCase()
                : '?',
          ),
          if (pendingUpload)
            const Positioned(
              right: -2,
              bottom: -2,
              child: _SyncingChip(),
            ),
        ],
      ),
    );
  }

  Future<void> _showPhotoPickerSheet(
    BuildContext context,
    WidgetRef ref, {
    required String? localPath,
    required String? remoteUrl,
    required bool hasAnyPhoto,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      builder: (_) => _PhotoPickerSheet(
        localPath: localPath,
        remoteUrl: remoteUrl,
        hasAnyPhoto: hasAnyPhoto,
      ),
    );
  }
}

/// Bottom-sheet action list for the profile avatar tap.
class _PhotoPickerSheet extends ConsumerWidget {
  final String? localPath;
  final String? remoteUrl;
  final bool hasAnyPhoto;

  const _PhotoPickerSheet({
    required this.localPath,
    required this.remoteUrl,
    required this.hasAnyPhoto,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF14141A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0x807C3AED), width: 1.5)),
        ),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (hasAnyPhoto)
              _sheetTile(
                context,
                theme,
                icon: Icons.visibility_outlined,
                label: 'View photo',
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      fullscreenDialog: true,
                      builder: (_) => _PhotoViewerPage(
                        localPath: localPath,
                        remoteUrl: remoteUrl,
                      ),
                    ),
                  );
                },
              ),
            _sheetTile(
              context,
              theme,
              icon: Icons.photo_camera_outlined,
              label: 'Take a photo',
              onTap: () async {
                Navigator.of(context).pop();
                await ref.read(localProfilePhotoProvider.notifier).pickFromCamera();
              },
            ),
            _sheetTile(
              context,
              theme,
              icon: Icons.photo_library_outlined,
              label: 'Choose from gallery',
              onTap: () async {
                Navigator.of(context).pop();
                await ref.read(localProfilePhotoProvider.notifier).pickFromGallery();
              },
            ),
            if (localPath != null)
              _sheetTile(
                context,
                theme,
                icon: Icons.delete_outline,
                label: 'Remove photo',
                destructive: true,
                onTap: () async {
                  Navigator.of(context).pop();
                  await ref.read(localProfilePhotoProvider.notifier).clear();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _sheetTile(
    BuildContext context,
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.redAccent : Colors.white;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 16),
            Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen profile-photo viewer. Prefers the local cached file
/// (higher fidelity, no network hop); falls back to the Supabase
/// avatar URL when no local copy exists. InteractiveViewer wraps the
/// image so the user can pinch/zoom to inspect.
class _PhotoViewerPage extends StatelessWidget {
  final String? localPath;
  final String? remoteUrl;

  const _PhotoViewerPage({
    required this.localPath,
    required this.remoteUrl,
  });

  @override
  Widget build(BuildContext context) {
    final imageWidget = _resolveImage();
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Center(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: imageWidget,
          ),
        ),
      ),
    );
  }

  Widget _resolveImage() {
    if (localPath != null) {
      return Image.file(
        File(localPath!),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _remoteImageOrPlaceholder(),
      );
    }
    return _remoteImageOrPlaceholder();
  }

  Widget _remoteImageOrPlaceholder() {
    if (remoteUrl != null && remoteUrl!.isNotEmpty) {
      return AppNetworkImage(
        url: remoteUrl!,
        fit: BoxFit.contain,
      );
    }
    return const Icon(Icons.image_not_supported_outlined,
        color: Colors.white54, size: 64);
  }
}

/// Small pill that overlays the avatar's bottom-right corner while a
/// photo is queued for upload (network was down at pick time). The
/// pill disappears the moment [pendingProfilePhotoUploadProvider]
/// flips false, which happens as soon as
/// [LocalProfilePhotoService.retryPendingUpload] succeeds — usually
/// within a second of the device reconnecting to a network.
class _SyncingChip extends StatelessWidget {
  const _SyncingChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 6),
          Text(
            'Syncing',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}


