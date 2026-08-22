import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../config/colors.dart';

/// Picks the battle's full time window: a start moment AND an end moment.
///
/// UX layers, top to bottom:
///   1. `SELECT BATTLE DURATION` header
///   2. Duration chips (12h, 1d, 3d, 1w, Custom) — quick presets that
///      recompute `endTime = startTime + duration`
///   3. Two pill rows: "Starts" and "Ends" — tap either to open a
///      date+time picker
///
/// Default: start = now, end = now + 1 day, preset = 1d.
///
/// The parent receives every committed change via [onChanged] as a
/// `BattleWindow` (immutable start/end pair). The chips drive a recomputed
/// end whenever the start moves so the preset duration stays correct.
class BattleWindow {
  final DateTime start;
  final DateTime end;

  /// True when the user picked the "Daily" preset (recurring series).
  /// The caller (1v1 / group setup sheets) branches on this and routes the
  /// create call to `BattleService.createDailySeries` instead of the
  /// regular `createBattle`. False for every other preset / custom window.
  final bool recurring;

  const BattleWindow(this.start, this.end, {this.recurring = false});

  Duration get duration => end.difference(start);
  bool get isValid => end.isAfter(start);
}

class BattleDurationPicker extends StatefulWidget {
  final ValueChanged<BattleWindow> onChanged;
  final BattleWindow? initial;

  /// Minimum allowed start moment. When non-null the picker:
  ///   • Snaps the current start forward to this value on the frame it
  ///     changes, if the current start is earlier.
  ///   • Uses this as `firstDate` on the start-time DateTime picker.
  ///   • Disables the `Daily` preset (its start = now, which violates
  ///     any minStart later than now).
  ///
  /// The 1v1 / group setup sheets pass `now + 1h` here when the Public
  /// battle toggle is on — public battles must give discoverers enough
  /// lead time.
  final DateTime? minStart;

  const BattleDurationPicker({
    super.key,
    required this.onChanged,
    this.initial,
    this.minStart,
  });

  @override
  State<BattleDurationPicker> createState() => _BattleDurationPickerState();
}

// `daily` is the "today's calendar day" preset: start = now, end = today
// 23:59:59 local (auto-rolls to tomorrow if opened within the last minute).
enum _Preset { daily, h12, d1, d3, w1, custom }

class _BattleDurationPickerState extends State<BattleDurationPicker> {
  late DateTime _start;
  late DateTime _end;
  _Preset _preset = _Preset.d1;

  static const _presetShort = {
    _Preset.daily: 'Daily',
    _Preset.h12: '12h',
    _Preset.d1: '1d',
    _Preset.d3: '3d',
    _Preset.w1: '1w',
    _Preset.custom: 'Custom',
  };

  static const _presetLabels = {
    _Preset.daily: 'Daily • Today',
    _Preset.h12: '12 hours',
    _Preset.d1: '1 day',
    _Preset.d3: '3 days',
    _Preset.w1: '1 week',
    _Preset.custom: 'Custom',
  };

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _start = initial.start;
      _end = initial.end;
    } else {
      _start = DateTime.now();
      _end = _start.add(const Duration(days: 1));
    }
    _applyMinStart();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _emitChange();
    });
  }

  @override
  void didUpdateWidget(covariant BattleDurationPicker old) {
    super.didUpdateWidget(old);
    // If the parent toggles the min-start floor (public toggle on),
    // snap our start forward if it's now too early.
    if (old.minStart != widget.minStart) {
      _applyMinStart();
      _emitChange();
    }
  }

  /// If [widget.minStart] is set and our current start is before it,
  /// clamp start forward, preserving the active preset's duration
  /// (so end moves too). Also flip off `Daily` since it means "start = now".
  ///
  /// The snap target is `floor + 5 minutes` — a small buffer above the
  /// hard floor so that if the user takes a few seconds to submit,
  /// the picked time is still comfortably above `now + hardFloor` at
  /// submit time (the parent re-checks the floor on submit for
  /// defense in depth). Without this buffer, snapping to exact
  /// `now + 1h` at 10:57 meant that submitting at 10:58 tripped the
  /// submit-side "public battles need to start ≥1h from now" guard.
  void _applyMinStart() {
    final floor = widget.minStart;
    if (floor == null) return;
    if (_preset == _Preset.daily) {
      _preset = _Preset.d1;
    }
    if (_start.isBefore(floor)) {
      final snapTarget = floor.add(const Duration(minutes: 5));
      final duration = _preset == _Preset.custom
          ? _end.difference(_start)
          : _durationForPreset(_preset);
      _start = snapTarget;
      _end = _start.add(
        duration <= Duration.zero ? const Duration(days: 1) : duration,
      );
    }
  }

  /// Emits the current window to the parent, tagging `recurring: true` when
  /// the user is on the Daily preset so the caller can route through the
  /// recurring-series creation path instead of the one-off battle path.
  void _emitChange() {
    widget.onChanged(BattleWindow(
      _start,
      _end,
      recurring: _preset == _Preset.daily,
    ));
  }

  Duration _durationForPreset(_Preset p) => switch (p) {
        _Preset.h12 => const Duration(hours: 12),
        _Preset.d1 => const Duration(days: 1),
        _Preset.d3 => const Duration(days: 3),
        _Preset.w1 => const Duration(days: 7),
        _Preset.daily => Duration.zero, // anchored end; computed in _pickPreset
        _Preset.custom => Duration.zero,
      };

  /// "Daily" anchors end at local midnight (23:59:59) of the current day, with
  /// start snapped to now. If we're already within the last minute of the day,
  /// roll to tomorrow's midnight so the battle has a usable window.
  DateTime _dailyEnd(DateTime now) {
    var end = DateTime(now.year, now.month, now.day, 23, 59, 59);
    if (end.difference(now).inMinutes < 1) {
      end = end.add(const Duration(days: 1));
    }
    return end;
  }

  void _pickPreset(_Preset p) {
    // Daily is disabled while a min-start floor is set (Public toggle
    // on) — daily implies start=now, which violates a floor of now+1h.
    if (p == _Preset.daily && widget.minStart != null) return;

    if (p == _Preset.custom) {
      // Custom means "you'll choose end manually" — open the end picker.
      _editEnd();
      return;
    }
    if (p == _Preset.daily) {
      // Anchor end to midnight, snap start to now. Counting still begins at
      // the moment the battle activates (per the lifetime-baseline rule); the
      // label "Daily • Today" just signals when the battle ends.
      final now = DateTime.now();
      setState(() {
        _preset = p;
        _start = now;
        _end = _dailyEnd(now);
      });
      _emitChange();
      return;
    }
    setState(() {
      _preset = p;
      _end = _start.add(_durationForPreset(p));
      // Re-apply the floor in case setting the preset would have
      // dragged start backward (e.g. reselecting 1d after custom).
      _applyMinStart();
    });
    _emitChange();
  }

  Future<void> _editStart() async {
    // Floor is `minStart` when the parent set one (Public toggle on),
    // otherwise the normal small back-skew tolerance from "now".
    final floor = widget.minStart ??
        DateTime.now().subtract(const Duration(minutes: 1));
    var picked = await _showDateTimePicker(
      initial: _start.isBefore(floor) ? floor : _start,
      firstDate: floor,
      helpDate: 'Start date',
      helpTime: 'Start time',
    );
    if (picked == null) return;
    // Flutter's showTimePicker doesn't respect the date picker's
    // firstDate — user can pick a TIME earlier than the floor even
    // though the DATE was floored. Clamp up. Applies to any picker
    // usage; matters most when Public is on and floor = now+1h.
    final clamped = picked.isBefore(floor) ? floor : picked;
    setState(() {
      _start = clamped;
      // "Daily" anchors end at midnight; once the user drags start off "now",
      // the preset no longer makes sense → fall back to Custom and keep the
      // midnight end the user already saw.
      if (_preset == _Preset.daily) {
        _preset = _Preset.custom;
        if (!_end.isAfter(_start)) {
          _end = _start.add(const Duration(hours: 1));
        }
      } else if (_preset != _Preset.custom) {
        // Preserve the active duration relative to the new start.
        _end = _start.add(_durationForPreset(_preset));
      } else if (!_end.isAfter(_start)) {
        // Avoid invalid window if user dragged start past the old end.
        _end = _start.add(const Duration(hours: 1));
      }
    });
    _emitChange();
  }

  Future<void> _editEnd() async {
    final picked = await _showDateTimePicker(
      initial: _end.isAfter(_start) ? _end : _start.add(const Duration(hours: 1)),
      firstDate: _start.add(const Duration(minutes: 1)),
      helpDate: 'End date',
      helpTime: 'End time',
    );
    if (picked == null) return;
    setState(() {
      _preset = _Preset.custom;
      _end = picked;
    });
    _emitChange();
  }

  Future<DateTime?> _showDateTimePicker({
    required DateTime initial,
    required DateTime firstDate,
    required String helpDate,
    required String helpTime,
  }) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(firstDate) ? firstDate : initial,
      firstDate: firstDate,
      lastDate: DateTime.now().add(const Duration(days: 30)),
      helpText: helpDate,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
                primary: AppColors.primary,
                onPrimary: AppColors.onPrimary,
              ),
        ),
        child: child!,
      ),
    );
    if (date == null || !mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: helpTime,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
                primary: AppColors.primary,
                onPrimary: AppColors.onPrimary,
              ),
        ),
        child: child!,
      ),
    );
    if (time == null) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  String _format(DateTime t) =>
      DateFormat('E, MMM d • h:mm a').format(t.toLocal());

  String get _durationSummary {
    final diff = _end.difference(_start);
    if (diff.isNegative || diff == Duration.zero) return 'Invalid window';
    final d = diff.inDays;
    final h = diff.inHours % 24;
    final m = diff.inMinutes % 60;
    final parts = <String>[];
    if (d > 0) parts.add('${d}d');
    if (h > 0) parts.add('${h}h');
    if (d == 0 && m > 0) parts.add('${m}m');
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SELECT BATTLE DURATION',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              letterSpacing: 2,
            )),
        const SizedBox(height: 10),

        // Preset chips
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _Preset.values
              .map((p) => _Chip(
                    label: _presetShort[p]!,
                    selected: _preset == p,
                    // Daily is disabled when the parent set a start-time
                    // floor (Public toggle → start ≥ now+1h). Grey it out
                    // so users see it's unavailable in this context.
                    disabled: p == _Preset.daily && widget.minStart != null,
                    onTap: () => _pickPreset(p),
                  ))
              .toList(),
        ),
        const SizedBox(height: 14),

        // Start + End pills
        _TimePill(
          icon: Icons.play_arrow_rounded,
          label: 'Starts',
          value: _format(_start),
          onTap: _editStart,
        ),
        const SizedBox(height: 8),
        _TimePill(
          icon: Icons.flag_rounded,
          label: 'Ends',
          value: _format(_end),
          onTap: _editEnd,
        ),

        const SizedBox(height: 6),
        Text(
          _preset == _Preset.custom
              ? 'Custom • $_durationSummary'
              : '${_presetLabels[_preset]} • $_durationSummary',
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _TimePill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  const _TimePill({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Text(label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.edit, size: 14, color: AppColors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.35 : 1.0,
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.18)
                : AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? AppColors.primary
                  : AppColors.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Manrope',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.primary : AppColors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
