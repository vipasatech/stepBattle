import 'dart:async';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import 'avatar_circle.dart';

/// Non-blocking banner shown when the current user gets pulled into a
/// team-battle lobby while they're in the app. Slides down from the
/// top, exposes tick (accept) / cross (decline), and auto-collapses
/// after [autoDismissAfter].
///
/// Owned by [TeamLobbyInviteToastHost], placed above the navigation
/// shell so the toast renders on top of every tab. Mirrors the shape
/// of [FriendRequestToast] on purpose — a fitness app that surfaces
/// two conceptually-similar "someone wants you to join" moments in
/// visually-similar widgets keeps the mental model tight.
class TeamLobbyInviteToast extends StatefulWidget {
  /// Name of the battle creator (the person who invited you).
  final String creatorName;
  final String? creatorAvatarUrl;
  /// Human-readable format label (`"2 teams · 4 players"`). Rendered
  /// as the toast subtitle so the invitee sees battle shape at a glance.
  final String subtitle;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Called when the auto-dismiss timer fires without the user acting.
  /// Semantically DIFFERENT from [onDecline] — the host should NOT
  /// reject the invite on timeout, only clear the toast state so the
  /// next queued toast can appear. The invite stays valid so the user
  /// can still respond via the Battles tab / notification centre.
  ///
  /// Bug fixed 1.1.6+27: prior versions collapsed timeout into
  /// [onDecline], which made the host call `rejectInvite` after 5s of
  /// inactivity — silently killing invites the user simply didn't get
  /// to in time.
  final VoidCallback onTimeout;

  final Duration autoDismissAfter;

  const TeamLobbyInviteToast({
    super.key,
    required this.creatorName,
    required this.creatorAvatarUrl,
    required this.subtitle,
    required this.onAccept,
    required this.onDecline,
    required this.onTimeout,
    // 5 seconds per product spec (Batch 4c).
    this.autoDismissAfter = const Duration(seconds: 5),
  });

  @override
  State<TeamLobbyInviteToast> createState() => _TeamLobbyInviteToastState();
}

class _TeamLobbyInviteToastState extends State<TeamLobbyInviteToast>
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
    // Auto-hide after N seconds if the user doesn't act. Cancelled on
    // explicit tick/cross so we don't fire a dismiss after the user
    // already decided.
    _autoDismiss = Timer(widget.autoDismissAfter, _dismissByTimeout);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _slide.dispose();
    super.dispose();
  }

  Future<void> _dismissByTimeout() async {
    // Timeout = neither accept nor decline. Toast slides away, the
    // invite stays live so the user can still respond from the
    // Battles tab / notification centre. The dedicated onTimeout
    // callback signals "user didn't act" without triggering reject.
    // Prior to 1.1.6+27 this fell through to onDecline which caused
    // the host to auto-reject the invite silently.
    _autoDismiss?.cancel();
    if (!mounted) return;
    await _slide.reverse();
    if (!mounted) return;
    widget.onTimeout.call();
  }

  Future<void> _accept() async {
    _autoDismiss?.cancel();
    widget.onAccept();
    if (!mounted) return;
    await _slide.reverse();
  }

  Future<void> _decline() async {
    _autoDismiss?.cancel();
    widget.onDecline();
    if (!mounted) return;
    await _slide.reverse();
  }

  String get _initials {
    final name = widget.creatorName.trim();
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
      ).animate(
        CurvedAnimation(parent: _slide, curve: Curves.easeOutCubic),
      ),
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
                  imageUrl: widget.creatorAvatarUrl,
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
                        '${widget.creatorName} · Team battle',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Cross first, tick second — this reads left-to-right as
                // "reject | accept" which matches the OS-level system
                // dialogs (Decline on left, Accept on right).
                IconButton(
                  icon: Icon(Icons.close,
                      size: 22, color: AppColors.onSurfaceVariant),
                  tooltip: 'Decline',
                  onPressed: _decline,
                ),
                IconButton(
                  icon: Icon(Icons.check, size: 22, color: AppColors.success),
                  tooltip: 'Accept',
                  onPressed: _accept,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
