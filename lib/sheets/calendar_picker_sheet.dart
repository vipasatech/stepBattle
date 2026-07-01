import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/colors.dart';

/// Show the modal bottom sheet that lets a user pick 3–7 days from the
/// last 28-day rolling window (see the Profile → "This Week" trendline
/// spec).
///
/// Resolves with the applied selection (oldest → newest, midnight-local
/// `DateTime`s) when the user taps **Apply**, or `null` when they
/// dismiss without applying.
Future<List<DateTime>?> showCalendarPickerSheet(
  BuildContext context, {
  required List<DateTime> initialSelection,
}) {
  return showModalBottomSheet<List<DateTime>>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        CalendarPickerSheet(initialSelection: initialSelection),
  );
}

/// Bottom-sheet body — see [showCalendarPickerSheet] for the return
/// contract.
class CalendarPickerSheet extends StatefulWidget {
  final List<DateTime> initialSelection;

  const CalendarPickerSheet({super.key, required this.initialSelection});

  @override
  State<CalendarPickerSheet> createState() => _CalendarPickerSheetState();
}

class _CalendarPickerSheetState extends State<CalendarPickerSheet> {
  static const int minSelect = 3;
  static const int maxSelect = 7;

  /// Midnight-local today.
  late final DateTime _today;

  /// Midnight-local 27 days before today (inclusive lower bound of the
  /// selectable window — 28 days total counting today).
  late final DateTime _windowStart;

  /// Currently-drafted selection. Applied only when the user taps
  /// Apply — until then it's local state.
  late final Set<DateTime> _selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _windowStart = _today.subtract(const Duration(days: 27));
    _selected =
        widget.initialSelection.map(_normalize).toSet();
  }

  static DateTime _normalize(DateTime d) =>
      DateTime(d.year, d.month, d.day);

  bool _isInWindow(DateTime d) =>
      !d.isBefore(_windowStart) && !d.isAfter(_today);

  void _toggle(DateTime d) {
    if (!_isInWindow(d)) return;
    setState(() {
      if (_selected.contains(d)) {
        _selected.remove(d);
      } else if (_selected.length < maxSelect) {
        _selected.add(d);
      }
      // Silently ignore an 8th tap — the tile would already be
      // greyed via `maxReached`, so this is a defensive no-op.
    });
  }

  /// Reset to the default last-7-days selection.
  void _reset() {
    setState(() {
      _selected
        ..clear()
        ..addAll(List.generate(
          7,
          (i) => _today.subtract(Duration(days: 6 - i)),
        ));
    });
  }

  void _apply() {
    final list = _selected.toList()..sort((a, b) => a.compareTo(b));
    Navigator.of(context).pop(list);
  }

  /// Ordered list of month-first-day anchors covering every day inside
  /// [_windowStart] ↔ [_today] (either one or two months).
  List<DateTime> _monthsInWindow() {
    final start = DateTime(_windowStart.year, _windowStart.month);
    final end = DateTime(_today.year, _today.month);
    final months = <DateTime>[];
    var m = start;
    while (!m.isAfter(end)) {
      months.add(m);
      m = DateTime(m.year, m.month + 1);
    }
    return months;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final months = _monthsInWindow();
    final maxReached = _selected.length >= maxSelect;
    final canApply = _selected.length >= minSelect;

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(24),
            ),
          ),
          child: Column(
            children: [
              // Drag handle.
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Title + selection-count chip.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Select 3 – 7 days',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    _SelectionChip(
                      count: _selected.length,
                      max: maxSelect,
                    ),
                  ],
                ),
              ),
              // Month grids, scrollable but bounded to the window.
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  itemCount: months.length,
                  itemBuilder: (_, i) => _MonthGrid(
                    month: months[i],
                    isInWindow: _isInWindow,
                    isSelected: _selected.contains,
                    isToday: (d) => d == _today,
                    maxReached: maxReached,
                    onTap: _toggle,
                  ),
                ),
              ),
              // Reset / Apply bar.
              _BottomBar(
                onReset: _reset,
                onApply: canApply ? _apply : null,
              ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// One month's grid: title + weekday labels + 7-column date grid
// =============================================================================

class _MonthGrid extends StatelessWidget {
  final DateTime month;
  final bool Function(DateTime) isInWindow;
  final bool Function(DateTime) isSelected;
  final bool Function(DateTime) isToday;
  final bool maxReached;
  final void Function(DateTime) onTap;

  const _MonthGrid({
    required this.month,
    required this.isInWindow,
    required this.isSelected,
    required this.isToday,
    required this.maxReached,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final firstDay = DateTime(month.year, month.month, 1);
    final daysInMonth =
        DateTime(month.year, month.month + 1, 0).day;
    // Sunday-first calendar: DateTime.weekday returns 1=Mon..7=Sun; the
    // `% 7` maps Sun → 0 so it lands in the leftmost column, matching
    // the reference design.
    final leadingBlanks = firstDay.weekday % 7;

    final tiles = <Widget>[];
    for (int i = 0; i < leadingBlanks; i++) {
      tiles.add(const SizedBox.shrink());
    }
    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(month.year, month.month, day);
      final inWindow = isInWindow(date);
      final selected = isSelected(date);
      tiles.add(_DateTile(
        date: date,
        inWindow: inWindow,
        selected: selected,
        isToday: isToday(date),
        // A tile is tappable when it's inside the 28-day window AND
        // either already selected (so the user can un-select) or the
        // cap hasn't been reached yet.
        disabled: !inWindow || (maxReached && !selected),
        onTap: () => onTap(date),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(
            DateFormat('MMMM yyyy').format(month),
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        // Weekday labels — Sun..Sat.
        Row(
          children: const [
            _WeekdayLabel('Sun'),
            _WeekdayLabel('Mon'),
            _WeekdayLabel('Tue'),
            _WeekdayLabel('Wed'),
            _WeekdayLabel('Thu'),
            _WeekdayLabel('Fri'),
            _WeekdayLabel('Sat'),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
          children: tiles,
        ),
        Divider(
          height: 24,
          color: scheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ],
    );
  }
}

class _WeekdayLabel extends StatelessWidget {
  final String label;
  const _WeekdayLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
    );
  }
}

// =============================================================================
// One date tile — circle with selection state
// =============================================================================

class _DateTile extends StatelessWidget {
  final DateTime date;
  final bool inWindow;
  final bool selected;
  final bool isToday;
  final bool disabled;
  final VoidCallback onTap;

  const _DateTile({
    required this.date,
    required this.inWindow,
    required this.selected,
    required this.isToday,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Text colour cascade: selected wins, then disabled, then today
    // (brand-tinted), then default. Kept explicit rather than nested
    // ternaries so the intent reads cleanly.
    Color textColor;
    if (selected) {
      textColor = Colors.white;
    } else if (disabled) {
      textColor = scheme.onSurface.withValues(alpha: 0.25);
    } else if (isToday) {
      textColor = AppColors.primary;
    } else {
      textColor = scheme.onSurface;
    }

    return GestureDetector(
      onTap: disabled ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? AppColors.primary : Colors.transparent,
          border: !selected && isToday
              ? Border.all(color: AppColors.primary, width: 1.5)
              : null,
        ),
        child: Center(
          child: Text(
            '${date.day}',
            style: TextStyle(
              color: textColor,
              fontFamily: 'Manrope',
              fontWeight:
                  selected || isToday ? FontWeight.w800 : FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Compact "3 / 7" chip in the title row
// =============================================================================

class _SelectionChip extends StatelessWidget {
  final int count;
  final int max;
  const _SelectionChip({required this.count, required this.max});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count / $max',
        style: TextStyle(
          color: AppColors.primary,
          fontFamily: 'Manrope',
          fontWeight: FontWeight.w800,
          fontSize: 12,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

// =============================================================================
// Reset + Apply bar pinned at the bottom
// =============================================================================

class _BottomBar extends StatelessWidget {
  final VoidCallback onReset;

  /// Null means "min not yet met" — button renders disabled.
  final VoidCallback? onApply;

  const _BottomBar({
    required this.onReset,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        12 + MediaQuery.of(context).viewPadding.bottom,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: onReset,
            child: const Text('Reset'),
          ),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 12,
              ),
            ),
            onPressed: onApply,
            child: const Text(
              'Apply',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}
