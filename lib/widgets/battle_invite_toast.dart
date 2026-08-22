import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../config/colors.dart';

/// Non-blocking banner shown when the current user receives a 1v1 or
/// daily-series battle invite while they're in the app. Slides down
/// from the top, exposes tick (accept) / cross (decline), and auto-
/// collapses after [autoDismissAfter].
///
/// Owned by [BattleInviteToastHost] (see `battle_invite_toast_host.dart`),
/// placed above the navigation shell so the toast renders on top of
/// every tab. Visually mirrors [TeamLobbyInviteToast] on purpose — the
/// three invite surfaces (friend / team / battle) share the same
/// "someone wants you to join" motion so the mental model is tight.
///
/// Uses a battle-swords leading icon rather than an avatar because the
/// notifications payload doesn't include the creator's avatar URL. The
/// icon + notification title/body are enough context for the invitee
/// to decide (Accept vs Decline).
class BattleInviteToast extends StatefulWidget {
  /// From the `notifications` row's `title` column — e.g. "Daily Battle
  /// Invite" or "Battle Invite". Rendered as the toast headline.
  final String title;

  /// From the `notifications` row's `body` — e.g. "Prasanna challenged
  /// you to a 1v1 battle". Rendered as the subtitle.
  final String body;

  /// True if this is a daily-series invite (data.recurring == 'daily'),
  /// swaps the leading icon to a calendar-style glyph to differentiate
  /// from one-off 1v1 invites at a glance.
  final bool isDaily;

  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Called when the auto-dismiss timer fires without the user acting.
  /// Semantically DIFFERENT from [onDecline] — the host should NOT
  /// reject the invite on timeout, only clear the toast state so the
  /// next queued toast can appear. The invite stays unread in the
  /// notification bell for later action.
  ///
  /// Bug fixed in 1.1.6+27: prior versions collapsed timeout into
  /// [onDecline], which made the host call `rejectInvite` after 5s of
  /// inactivity — silently killing invites the user simply didn't get
  /// to in time. Reported 2026-08-17.
  final VoidCallback onTimeout;

  final Duration autoDismissAfter;

  const BattleInviteToast({
    super.key,
    required this.title,
    required this.body,
    required this.isDaily,
    required this.onAccept,
    required this.onDecline,
    required this.onTimeout,
    // 5 seconds — matches [TeamLobbyInviteToast] / [FriendRequestToast].
    this.autoDismissAfter = const Duration(seconds: 5),
  });

  @override
  State<BattleInviteToast> createState() => _BattleInviteToastState();
}

class _BattleInviteToastState extends State<BattleInviteToast>
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
    // explicit tick/cross so we don't fire dismiss after the user
    // already decided. Timeout is NOT the same as decline — the host
    // decides what to do with the notification row on timeout (we
    // leave it unread so it stays in the bell for later action).
    _autoDismiss = Timer(widget.autoDismissAfter, _dismissByTimeout);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _slide.dispose();
    super.dispose();
  }

  Future<void> _dismissByTimeout() async {
    _autoDismiss?.cancel();
    if (!mounted) return;
    await _slide.reverse();
    if (!mounted) return;
    // Timeout is NOT decline. Call the dedicated onTimeout callback
    // — the host clears its state but does NOT call rejectInvite. The
    // invite stays unread in the bell so the user can still act on it
    // later. Prior to 1.1.6+27 this collapsed to onDecline → auto-
    // rejected the invite after 5 seconds of inactivity.
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
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.primary,
                      width: 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.isDaily
                        ? MdiIcons.calendarBlank
                        : MdiIcons.swordCross,
                    size: 20,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.body,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Cross first, tick second — reads left-to-right as
                // "reject | accept", matching OS-level system dialogs.
                IconButton(
                  icon: Icon(Icons.close,
                      size: 22, color: AppColors.onSurfaceVariant),
                  tooltip: 'Decline',
                  onPressed: _decline,
                ),
                IconButton(
                  icon: Icon(Icons.check,
                      size: 22, color: AppColors.success),
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
