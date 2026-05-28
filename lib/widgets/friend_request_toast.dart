import 'dart:async';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import 'avatar_circle.dart';

/// Non-blocking banner shown when an incoming friend request lands while the
/// user is in the app. Slides down from the top, exposes Accept / Dismiss,
/// and auto-collapses after [autoDismissAfter].
///
/// Owned by `FriendRequestToastHost`, which is placed above the navigation
/// shell so the toast renders on top of every tab.
class FriendRequestToast extends StatefulWidget {
  final String displayName;
  final String? avatarUrl;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;
  final Duration autoDismissAfter;

  const FriendRequestToast({
    super.key,
    required this.displayName,
    required this.avatarUrl,
    required this.onAccept,
    required this.onDismiss,
    this.autoDismissAfter = const Duration(seconds: 6),
  });

  @override
  State<FriendRequestToast> createState() => _FriendRequestToastState();
}

class _FriendRequestToastState extends State<FriendRequestToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..forward();
    _autoDismiss = Timer(widget.autoDismissAfter, _dismiss);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _slide.dispose();
    super.dispose();
  }

  void _dismiss() async {
    _autoDismiss?.cancel();
    if (!mounted) return;
    await _slide.reverse();
    if (!mounted) return;
    widget.onDismiss();
  }

  void _accept() async {
    _autoDismiss?.cancel();
    widget.onAccept();
    if (!mounted) return;
    await _slide.reverse();
  }

  String get _initials {
    final name = widget.displayName.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final mediaTop = MediaQuery.of(context).padding.top;
    final theme = Theme.of(context);

    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, -1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _slide, curve: Curves.easeOutCubic)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, mediaTop + 8, 12, 0),
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.35),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryBrand.withValues(alpha: 0.25),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                AvatarCircle(
                  radius: 20,
                  imageUrl: widget.avatarUrl,
                  initials: _initials,
                  borderColor: AppColors.primary,
                  borderWidth: 1,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.displayName,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'sent you a friend request',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _accept,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(72, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
                  ),
                  child: const Text('Accept'),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: AppColors.onSurfaceVariant,
                  onPressed: _dismiss,
                  tooltip: 'Dismiss',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
