import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/colors.dart';
import '../models/leaderboard_entry_model.dart';
import '../providers/friend_provider.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Public profile card — shown when tapping a leaderboard row.
class PublicProfileSheet extends ConsumerStatefulWidget {
  final LeaderboardEntry entry;

  const PublicProfileSheet({super.key, required this.entry});

  @override
  ConsumerState<PublicProfileSheet> createState() =>
      _PublicProfileSheetState();
}

class _PublicProfileSheetState extends ConsumerState<PublicProfileSheet> {
  bool _addingFriend = false;
  bool _isFriend = false;

  @override
  void initState() {
    super.initState();
    _checkFriend();
  }

  void _checkFriend() {
    final friends = ref.read(friendsListProvider).valueOrNull ?? [];
    _isFriend = friends.any((f) => f.userId == widget.entry.userId);
  }

  Future<void> _addFriend() async {
    setState(() => _addingFriend = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await ref.read(friendServiceProvider).sendRequest(
            fromUserId: uid,
            toUserId: widget.entry.userId,
          );
      setState(() => _isFriend = true);
    } catch (_) {}
    setState(() => _addingFriend = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.entry;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BottomSheetHandle(),

          // Avatar + name + badges
          AvatarCircle(
            radius: 40,
            imageUrl: e.avatarURL,
            initials:
                e.displayName.isNotEmpty ? e.displayName[0] : '?',
            borderColor: AppColors.primary,
            borderWidth: 3,
          ),
          const SizedBox(height: 14),
          Text(e.displayName,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),

          // Badge row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Badge(
                  label: 'Rank #${e.rank}', color: AppColors.primary),
              const SizedBox(width: 8),
              _Badge(
                  label: '${_fmt(e.totalXP)} XP',
                  color: AppColors.tertiary),
            ],
          ),
          const SizedBox(height: 28),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: _isFriend
                      ? OutlinedButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('Friends'),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                                color: AppColors.success
                                    .withValues(alpha: 0.4)),
                            foregroundColor: AppColors.success,
                          ),
                        )
                      : FilledButton.icon(
                          onPressed: _addingFriend ? null : _addFriend,
                          icon: _addingFriend
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white))
                              : const Icon(Icons.person_add, size: 18),
                          label: const Text('Add Friend'),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      context.go('/battles');
                    },
                    icon: const Icon(Icons.bolt, size: 18),
                    label: const Text('Challenge'),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.4)),
                      foregroundColor: AppColors.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;

  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(label,
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
          )),
    );
  }
}
