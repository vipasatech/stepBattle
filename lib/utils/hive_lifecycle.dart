import 'package:hive/hive.dart';

import '../services/native_step_service.dart';

/// Shared helpers for the Hive box-lifecycle race between the main
/// isolate and the WorkManager background isolate.
///
/// Problem in short: `background_sync.dart` opens the same physical
/// `.hive` file (`step_tracker`) that the main isolate is already
/// holding. `Hive.isBoxOpen(name)` is isolate-local — it can't see
/// the other isolate's registry — so the background isolate calls
/// `openBox` unconditionally when it fires. Two isolates holding
/// the same box file end in one of them getting a stale file handle,
/// and subsequent writes throw `FileSystemException: File closed`.
///
/// We can't easily fix the isolate architecture without a broader
/// refactor (that's the "Level B" follow-up). Meanwhile:
///
///   • [safeSharedBox] returns the box handle only if it's actually
///     open in this isolate. Callers skip writes when it isn't (the
///     next successful open re-populates from the source of truth).
///
///   • [isBenignBoxClosed] classifies caught errors so callers can
///     swallow the "expected race loser" case without spamming
///     Diagnostics. Anything else still logs normally.
///
///   • [reopenSharedBoxIfClosed] is called from the main shell's
///     lifecycle handler on `resumed` — the background isolate can
///     close the file underneath us while the app is backgrounded,
///     so we proactively reopen on foreground.

/// The one Hive box shared by every repository in the main isolate.
/// Named after the earliest consumer (NativeStepService) for
/// historical reasons; effectively the app's shared key-value store.
String get sharedBoxName => NativeStepService.boxName;

/// Return the shared box if it is currently open IN THIS ISOLATE.
/// Callers should treat null as "silently skip the write / read"
/// rather than as an error — the box will be reopened on the next
/// foreground resume.
Box<dynamic>? safeSharedBox() {
  if (!Hive.isBoxOpen(sharedBoxName)) return null;
  return Hive.box(sharedBoxName);
}

/// True when the error is a Hive box-file-close race that should be
/// silently swallowed instead of logged as a defect. Anything else
/// (schema mismatch, disk-full, permission denied) still gets logged.
///
/// Recognises the three shapes Hive can raise:
///   1. `FileSystemException: File closed` — the underlying dart:io
///      file handle went stale after the other isolate closed it.
///   2. `HiveError: Box has already been closed.` — we tried to
///      operate on a box whose in-memory state was torn down.
///   3. `HiveError: The box "..." is already open` — different race
///      (the other isolate opened first), safe to skip this write.
bool isBenignBoxClosed(Object e) {
  final s = e.toString();
  if (s.contains('File closed')) return true;
  if (s.contains('Box has already been closed')) return true;
  if (s.contains('is already open')) return true;
  return false;
}

/// Called from the main shell's `AppLifecycleState.resumed` handler.
/// If the shared box got closed while we were backgrounded (usually
/// because the WorkManager background isolate fired and took over
/// the file handle), reopen it here so the very first write after
/// resume doesn't fail.
///
/// Idempotent: no-op if the box is already open.
Future<void> reopenSharedBoxIfClosed() async {
  if (Hive.isBoxOpen(sharedBoxName)) return;
  try {
    await Hive.openBox(sharedBoxName);
  } catch (_) {
    // Reopen can itself race with the background isolate — swallow;
    // the next attempt will succeed once the other isolate releases.
  }
}
