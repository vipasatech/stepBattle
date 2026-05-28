import 'dart:async';
import 'package:flutter/material.dart';

/// Live "Hh Mm" countdown to the next reset boundary, in the user's local
/// timezone. Used by the Missions screen so the reset label is honest
/// instead of a hardcoded string.
///
/// Two helpers compute the canonical reset points:
///   • [nextLocalMidnight]  — daily-mission reset
///   • [nextLocalMonday]    — weekly-mission reset (Monday 00:00 local)
///
/// The widget ticks once a minute (cheap) and recomputes on every build.
/// When the boundary is crossed mid-display, the label silently flips to
/// the next period's countdown — no parent rebuild needed.
class ResetCountdown extends StatefulWidget {
  /// When the next reset happens (in local time).
  final DateTime nextResetAt;

  /// Prefix label, e.g. "Daily missions reset in".
  final String prefix;

  /// Text style for the rendered countdown.
  final TextStyle? style;

  const ResetCountdown({
    super.key,
    required this.nextResetAt,
    required this.prefix,
    this.style,
  });

  /// 00:00 tomorrow in device local time.
  static DateTime nextLocalMidnight([DateTime? from]) {
    final now = from ?? DateTime.now();
    return DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
  }

  /// 00:00 on the next Monday in device local time. If today IS Monday and
  /// it's before 00:00 (impossible) or exactly 00:00, we still roll to the
  /// next Monday — i.e., resets happen at the boundary, not retroactively.
  static DateTime nextLocalMonday([DateTime? from]) {
    final now = from ?? DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    // DateTime.weekday: Monday = 1, Sunday = 7.
    final daysUntilMonday = (8 - now.weekday) % 7;
    final addDays = daysUntilMonday == 0 ? 7 : daysUntilMonday;
    return midnight.add(Duration(days: addDays));
  }

  @override
  State<ResetCountdown> createState() => _ResetCountdownState();
}

class _ResetCountdownState extends State<ResetCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Tick once a minute — minute resolution is enough for "Xh Ym" UI and
    // avoids burning a frame every second.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.nextResetAt.difference(DateTime.now());
    final label = _formatRemaining(remaining);
    return Text(
      '${widget.prefix} $label',
      style: widget.style ?? Theme.of(context).textTheme.bodySmall,
    );
  }

  static String _formatRemaining(Duration r) {
    if (r.isNegative) return 'now';
    final h = r.inHours;
    final m = r.inMinutes % 60;
    if (h >= 24) {
      final d = r.inDays;
      final hh = r.inHours % 24;
      return hh > 0 ? '${d}d ${hh}h' : '${d}d';
    }
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m';
    return '<1m';
  }
}
