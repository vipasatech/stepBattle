import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../config/colors.dart';

/// Lets the user pick when a battle ends. Presets for common windows
/// plus a Custom option that opens a combined date + time picker.
///
/// The selected value is an absolute [DateTime] — the moment the battle
/// ends. When the battle activates (all invitees accept), the server
/// preserves the picked duration from the activation moment, so a delayed
/// acceptance doesn't shrink the window.
class BattleDurationPicker extends StatefulWidget {
  /// Fires whenever the selected end time changes.
  final ValueChanged<DateTime> onChanged;

  /// Initial selection. If null, defaults to now + 1 day.
  final DateTime? initial;

  const BattleDurationPicker({
    super.key,
    required this.onChanged,
    this.initial,
  });

  @override
  State<BattleDurationPicker> createState() => _BattleDurationPickerState();
}

enum _Preset { h12, d1, d3, w1, custom }

class _BattleDurationPickerState extends State<BattleDurationPicker> {
  late DateTime _endTime;
  _Preset _preset = _Preset.d1;

  static const _presetLabels = {
    _Preset.h12: '12 hours',
    _Preset.d1: '1 day',
    _Preset.d3: '3 days',
    _Preset.w1: '1 week',
    _Preset.custom: 'Custom',
  };

  static const _presetShort = {
    _Preset.h12: '12h',
    _Preset.d1: '1d',
    _Preset.d3: '3d',
    _Preset.w1: '1w',
    _Preset.custom: 'Custom',
  };

  @override
  void initState() {
    super.initState();
    _endTime =
        widget.initial ?? DateTime.now().add(const Duration(days: 1));
    // Fire once so the parent receives the initial value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onChanged(_endTime);
    });
  }

  Duration _durationForPreset(_Preset p) => switch (p) {
        _Preset.h12 => const Duration(hours: 12),
        _Preset.d1 => const Duration(days: 1),
        _Preset.d3 => const Duration(days: 3),
        _Preset.w1 => const Duration(days: 7),
        _Preset.custom => Duration.zero, // sentinel
      };

  void _pick(_Preset p) async {
    if (p == _Preset.custom) {
      final picked = await _showCustomPicker();
      if (picked == null) return;
      setState(() {
        _preset = _Preset.custom;
        _endTime = picked;
      });
      widget.onChanged(picked);
    } else {
      final next = DateTime.now().add(_durationForPreset(p));
      setState(() {
        _preset = p;
        _endTime = next;
      });
      widget.onChanged(next);
    }
  }

  Future<DateTime?> _showCustomPicker() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _preset == _Preset.custom
          ? _endTime
          : now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
      helpText: 'End date',
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
      initialTime: _preset == _Preset.custom
          ? TimeOfDay.fromDateTime(_endTime)
          : const TimeOfDay(hour: 18, minute: 0),
      helpText: 'End time',
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

    final combined = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    // Guard: custom picks must be at least 1 hour out.
    final earliest = DateTime.now().add(const Duration(hours: 1));
    if (combined.isBefore(earliest)) return earliest;
    return combined;
  }

  String get _summary {
    final diff = _endTime.difference(DateTime.now());
    if (diff.isNegative) return 'Invalid time';
    final d = diff.inDays;
    final h = diff.inHours % 24;
    final m = diff.inMinutes % 60;
    final parts = <String>[];
    if (d > 0) parts.add('${d}d');
    if (h > 0) parts.add('${h}h');
    if (d == 0 && m > 0) parts.add('${m}m');
    final rel = parts.join(' ');
    final abs =
        DateFormat('E, MMM d \u2022 h:mm a').format(_endTime.toLocal());
    return '$rel \u2022 ends $abs';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('BATTLE ENDS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              letterSpacing: 2,
            )),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _Preset.values
              .map((p) => _Chip(
                    label: _presetShort[p]!,
                    selected: _preset == p,
                    onTap: () => _pick(p),
                  ))
              .toList(),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              Icon(Icons.schedule,
                  size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_preset != _Preset.custom)
                TextButton(
                  onPressed: () => _pick(_Preset.custom),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 0),
                    minimumSize: const Size(0, 24),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Edit',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_preset != _Preset.custom) ...[
          const SizedBox(height: 4),
          Text(
            _presetLabels[_preset]!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ],
      ],
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
