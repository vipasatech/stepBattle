import 'package:intl/intl.dart';

/// Compact "when did this happen" formatter for list-item timestamps
/// (completed battle cards, track session tiles, day summaries).
///
/// Rules:
///   • within the current calendar year → `MMM d · h:mm a` (Jul 21 · 6:14 PM)
///   • older than that                  → `MMM d, yyyy · h:mm a`
///
/// The year is dropped for the common case so it doesn't visually
/// dominate the row; older items promote to the four-digit form so the
/// context is unambiguous.
///
/// Uses [DateTime.toLocal] before formatting so the caller doesn't have
/// to remember — everywhere we surface user-facing timestamps we want
/// the device's local wall-clock, not UTC.
String friendlyDateTime(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  final sameYear = local.year == now.year;
  final pattern = sameYear ? 'MMM d · h:mm a' : 'MMM d, yyyy · h:mm a';
  return DateFormat(pattern).format(local);
}
