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
  const BattleWindow(this.start, this.end);
  Duration get duration => end.difference(start);
  bool get isValid => end.isAfter(start);
}

class BattleDurationPicker extends StatefulWidget {
  final ValueChanged<BattleWindow> onChanged;
  final BattleWindow? initial;

  const BattleDurationPicker({
    super.key,
    required this.onChanged,
    this.initial,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onChanged(BattleWindow(_start, _end));
    });
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
      widget.onChanged(BattleWindow(_start, _end));
      return;
    }
    setState(() {
      _preset = p;
      _end = _start.add(_durationForPreset(p));
    });
    widget.onChanged(BattleWindow(_start, _end));
  }

  Future<void> _editStart() async {
    final picked = await _showDateTimePicker(
      initial: _start,
      // Clamp to >= now (or a small back-skew tolerance handled in service).
      firstDate: DateTime.now().subtract(const Duration(minutes: 1)),
      helpDate: 'Start date',
      helpTime: 'Start time',
    );
    if (picked == null) return;
    setState(() {
      _start = picked;
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
    widget.onChanged(BattleWindow(_start, _end));
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
    widget.onChanged(BattleWindow(_start, _end));
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
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
    );
  }
}
