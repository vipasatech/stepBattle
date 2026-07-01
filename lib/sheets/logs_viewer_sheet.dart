import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';
import '../utils/app_logger.dart';
import '../widgets/bottom_sheet_handle.dart';

/// In-app logs viewer.
///
/// Shows the most recent ~500 entries from [AppLogger]'s in-memory ring
/// buffer plus a live tail of newly-emitted lines. Useful for field
/// debugging on release builds where `flutter logs` isn't available —
/// e.g. "why did this saved run not sync?".
///
/// Filtered to [LogCategory.track] by default since that's the path the
/// user was investigating; a chip row lets them swap to any other
/// category or "All".
///
/// `showLogsViewerSheet(context, focus: LogCategory.track)` is the
/// canonical entry point.
Future<void> showLogsViewerSheet(
  BuildContext context, {
  LogCategory? focus = LogCategory.track,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LogsViewerSheet(initialFocus: focus),
  );
}

class _LogsViewerSheet extends StatefulWidget {
  final LogCategory? initialFocus;
  const _LogsViewerSheet({this.initialFocus});

  @override
  State<_LogsViewerSheet> createState() => _LogsViewerSheetState();
}

class _LogsViewerSheetState extends State<_LogsViewerSheet> {
  /// `null` = All categories.
  LogCategory? _filter;
  StreamSubscription<LogEntry>? _sub;

  /// We render from a local snapshot so list items don't shift around
  /// every keystroke as a new log lands. The stream subscription
  /// rebuilds via setState on each new entry.
  List<LogEntry> _entries = const [];

  /// Auto-scroll to bottom when new entries arrive AND the user hasn't
  /// scrolled away. Lets them stop the tail by scrolling up.
  final _scrollController = ScrollController();
  bool _autoFollow = true;

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFocus;
    _refresh();
    _sub = AppLogger.stream.listen((_) {
      if (!mounted) return;
      _refresh();
      if (_autoFollow) _scrollToBottom();
    });
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _entries = AppLogger.recent(category: _filter);
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // "Near bottom" within 80px = treat as tail-following.
    _autoFollow = pos.maxScrollExtent - pos.pixels < 80;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _copyAll() async {
    final text = _entries.map((e) => e.formatted()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_entries.length} log lines'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _clear() {
    AppLogger.clearBuffer();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, _) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),
            _Header(
              entryCount: _entries.length,
              onCopy: _copyAll,
              onClear: _clear,
            ),
            _FilterChips(
              current: _filter,
              onChange: (c) {
                _filter = c;
                _refresh();
                _scrollToBottom();
              },
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _entries.isEmpty
                  ? const _EmptyState()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      itemCount: _entries.length,
                      itemBuilder: (_, i) => _LogLine(entry: _entries[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final int entryCount;
  final VoidCallback onCopy;
  final VoidCallback onClear;
  const _Header({
    required this.entryCount,
    required this.onCopy,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Diagnostics',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800)),
                Text('$entryCount entries · in-memory only',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy all',
            onPressed: entryCount == 0 ? null : onCopy,
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Clear buffer',
            onPressed: entryCount == 0 ? null : onClear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  final LogCategory? current;
  final ValueChanged<LogCategory?> onChange;
  const _FilterChips({required this.current, required this.onChange});

  // Frequently-needed categories first; the rest stay accessible via
  // horizontal scrolling but don't crowd the default view.
  static const _featured = <LogCategory?>[
    null, // All
    LogCategory.track,
    LogCategory.battle,
    LogCategory.step,
    LogCategory.auth,
    LogCategory.session,
    LogCategory.permission,
    LogCategory.geo,
    LogCategory.xp,
    LogCategory.mission,
    LogCategory.clan,
    LogCategory.friend,
    LogCategory.health,
    LogCategory.leaderboard,
    LogCategory.notification,
    LogCategory.nav,
    LogCategory.payments,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _featured.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final c = _featured[i];
          final selected = c == current;
          return ChoiceChip(
            label: Text(c?.name ?? 'All'),
            selected: selected,
            onSelected: (_) => onChange(c),
            visualDensity: VisualDensity.compact,
            labelStyle: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: selected
                  ? AppColors.onPrimary
                  : AppColors.onSurfaceVariant,
            ),
            selectedColor: AppColors.primary,
            backgroundColor: AppColors.surfaceContainerHigh,
            side: BorderSide.none,
          );
        },
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final LogEntry entry;
  const _LogLine({required this.entry});

  @override
  Widget build(BuildContext context) {
    final colour = switch (entry.level) {
      LogLevel.error => AppColors.error,
      LogLevel.warn => AppColors.amber,
      LogLevel.info => AppColors.primary,
      LogLevel.debug => AppColors.onSurfaceVariant,
      LogLevel.trace => AppColors.onSurfaceVariant,
    };
    final hhmmss = _hhmmss(entry.ts.toLocal());

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: colour, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                hhmmss,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              _PillTag(text: entry.category.name, color: colour),
              const SizedBox(width: 6),
              _PillTag(
                text: entry.level.name.toUpperCase(),
                color: colour,
                outlined: true,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            entry.event,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (entry.fields != null && entry.fields!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              entry.fields.toString(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _hhmmss(DateTime t) {
    String pad2(int n) => n.toString().padLeft(2, '0');
    return '${pad2(t.hour)}:${pad2(t.minute)}:${pad2(t.second)}';
  }
}

class _PillTag extends StatelessWidget {
  final String text;
  final Color color;
  final bool outlined;
  const _PillTag({
    required this.text,
    required this.color,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: outlined ? null : color.withValues(alpha: 0.15),
        border: outlined ? Border.all(color: color, width: 1) : null,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.4,
          color: color,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bug_report_outlined,
                size: 48, color: AppColors.onSurfaceVariant),
            const SizedBox(height: 14),
            Text('No log entries yet',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Activity will appear here as you use the app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
