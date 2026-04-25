import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/battle_model.dart';
import '../../../widgets/avatar_circle.dart';

/// Compact ranking strip docked at the bottom of the battle ground.
/// Participants sorted by step count descending. Tap to expand the full list.
class LeaderboardPill extends StatefulWidget {
  final List<BattleParticipant> participants;
  final String currentUserId;

  const LeaderboardPill({
    super.key,
    required this.participants,
    required this.currentUserId,
  });

  @override
  State<LeaderboardPill> createState() => _LeaderboardPillState();
}

class _LeaderboardPillState extends State<LeaderboardPill> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = [...widget.participants]
      ..sort((a, b) => b.currentSteps.compareTo(a.currentSteps));
    final leaderSteps =
        sorted.isNotEmpty ? sorted.first.currentSteps : 0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.leaderboard,
                      size: 16, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Text(
                    'LEADERBOARD',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (!_expanded)
                _Collapsed(sorted: sorted, currentUserId: widget.currentUserId)
              else
                _Expanded(
                  sorted: sorted,
                  leaderSteps: leaderSteps,
                  currentUserId: widget.currentUserId,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Collapsed extends StatelessWidget {
  final List<BattleParticipant> sorted;
  final String currentUserId;
  const _Collapsed({required this.sorted, required this.currentUserId});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < sorted.length && i < 4; i++) ...[
          _MiniRow(
            rank: i + 1,
            p: sorted[i],
            isMe: sorted[i].userId == currentUserId,
          ),
          if (i < sorted.length - 1 && i < 3)
            Container(
              width: 1,
              height: 22,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: Colors.white.withValues(alpha: 0.08),
            ),
        ],
        if (sorted.length > 4) ...[
          const SizedBox(width: 6),
          Text('+${sorted.length - 4}',
              style: const TextStyle(
                fontFamily: 'Manrope',
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              )),
        ],
      ],
    );
  }
}

class _MiniRow extends StatelessWidget {
  final int rank;
  final BattleParticipant p;
  final bool isMe;
  const _MiniRow({required this.rank, required this.p, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final medal = switch (rank) {
      1 => AppColors.gold,
      2 => AppColors.silver,
      3 => AppColors.bronze,
      _ => AppColors.onSurfaceVariant,
    };
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: medal.withValues(alpha: 0.18),
            shape: BoxShape.circle,
            border: Border.all(color: medal.withValues(alpha: 0.7)),
          ),
          child: Text(
            '$rank',
            style: TextStyle(
              fontFamily: 'Manrope',
              color: medal,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isMe ? 'You' : _short(p.displayName),
              style: TextStyle(
                fontFamily: 'Manrope',
                color: isMe ? AppColors.primary : Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
            Text(
              _fmt(p.currentSteps),
              style: const TextStyle(
                fontFamily: 'Manrope',
                color: Colors.white70,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _short(String s) => s.length > 6 ? '${s.substring(0, 6)}…' : s;

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

class _Expanded extends StatelessWidget {
  final List<BattleParticipant> sorted;
  final int leaderSteps;
  final String currentUserId;
  const _Expanded({
    required this.sorted,
    required this.leaderSteps,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < sorted.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: _FullRow(
              rank: i + 1,
              p: sorted[i],
              leaderSteps: leaderSteps,
              isMe: sorted[i].userId == currentUserId,
            ),
          ),
      ],
    );
  }
}

class _FullRow extends StatelessWidget {
  final int rank;
  final BattleParticipant p;
  final int leaderSteps;
  final bool isMe;
  const _FullRow({
    required this.rank,
    required this.p,
    required this.leaderSteps,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final medal = switch (rank) {
      1 => AppColors.gold,
      2 => AppColors.silver,
      3 => AppColors.bronze,
      _ => AppColors.onSurfaceVariant,
    };
    final gap = rank == 1 ? 0 : leaderSteps - p.currentSteps;

    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: medal.withValues(alpha: 0.18),
            shape: BoxShape.circle,
            border: Border.all(color: medal.withValues(alpha: 0.7)),
          ),
          child: Text(
            '$rank',
            style: TextStyle(
              fontFamily: 'Manrope',
              color: medal,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 10),
        AvatarCircle(
          radius: 14,
          imageUrl: p.avatarURL,
          initials: p.displayName.isNotEmpty
              ? p.displayName[0].toUpperCase()
              : '?',
          borderColor: isMe ? AppColors.primary : AppColors.outlineVariant,
          borderWidth: 1.5,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            isMe ? 'You' : p.displayName,
            style: theme.textTheme.labelMedium?.copyWith(
              color: isMe ? AppColors.primary : Colors.white,
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _fmt(p.currentSteps),
              style: const TextStyle(
                fontFamily: 'Manrope',
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (rank > 1)
              Text(
                '-${_fmt(gap)}',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 10,
                ),
              ),
          ],
        ),
      ],
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
