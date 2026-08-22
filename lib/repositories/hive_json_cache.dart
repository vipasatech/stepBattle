import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';

import '../utils/app_logger.dart';
import '../utils/hive_lifecycle.dart';

/// Small typed helper over a shared Hive box for JSON-encoded rows.
///
/// The rest of the app reuses the same Hive box (`NativeStepService.boxName`)
/// that's already opened at startup — so repositories don't pay a
/// second `openBox` roundtrip. Each repository picks a stable [prefix]
/// and this class handles namespace/serialization/decode-failure fallback.
///
/// The box is a `Box<dynamic>`, so values must be primitives or Strings.
/// We JSON-encode everything to avoid Hive-adapter registration churn
/// as models evolve; the overhead is a few hundred µs per read/write
/// which is dwarfed by the network savings on the network path.
///
/// **Isolate-close race:** the box handle can go stale if the
/// WorkManager background isolate takes over the file. Every method
/// re-fetches the live box via [safeSharedBox] instead of using a
/// captured reference, and swallows the [isBenignBoxClosed] error
/// family so the Diagnostics log doesn't flood. See [hive_lifecycle.dart].
class HiveJsonCache<T> {
  HiveJsonCache({
    required this.prefix,
    required this.encode,
    required this.decode,
    required this.logCategory,
    Box<dynamic>? box,
  }) : _injectedBox = box;

  /// Key prefix. Must be stable across app versions AND include a version
  /// suffix (e.g. `battles_v1:`) so schema changes never accidentally
  /// deserialize an old shape as a new one — bump the suffix on breaking
  /// changes and the old rows fall out cleanly.
  final String prefix;

  final Map<String, dynamic> Function(T value) encode;
  final T Function(Map<String, dynamic> raw) decode;

  /// Which log category to attribute cache decode/write failures to.
  /// Follows the same routing rules as [SupabaseApiClient].
  final LogCategory logCategory;

  /// Test-only injection point. Real callers should NOT pass this —
  /// the shared box is fetched live via [_liveBox] so a background-
  /// isolate close doesn't leave us holding a stale reference.
  final Box<dynamic>? _injectedBox;

  Box<dynamic>? get _liveBox => _injectedBox ?? safeSharedBox();

  String _keyFor(String id) => '$prefix$id';

  /// Read the cached value for [id]. Returns null on cache miss OR on
  /// malformed data (the malformed row is deleted so a later write
  /// starts clean).
  T? read(String id) {
    final box = _liveBox;
    if (box == null) return null;
    try {
      final raw = box.get(_keyFor(id));
      if (raw is! String || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return decode(map);
    } catch (e) {
      if (isBenignBoxClosed(e)) return null;
      AppLogger.forCategory(logCategory).w('$prefix:decodeFailed',
          fields: {'id': id, 'err': e.toString()});
      unawaited(box.delete(_keyFor(id)).catchError((_) {}));
      return null;
    }
  }

  /// Read a cached list. Same failure semantics as [read].
  List<T>? readList(String id) {
    final box = _liveBox;
    if (box == null) return null;
    try {
      final raw = box.get(_keyFor(id));
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .cast<Map<String, dynamic>>()
          .map(decode)
          .toList(growable: false);
    } catch (e) {
      if (isBenignBoxClosed(e)) return null;
      AppLogger.forCategory(logCategory).w('$prefix:decodeListFailed',
          fields: {'id': id, 'err': e.toString()});
      unawaited(box.delete(_keyFor(id)).catchError((_) {}));
      return null;
    }
  }

  Future<void> write(String id, T value) async {
    final box = _liveBox;
    if (box == null) return;
    try {
      await box.put(_keyFor(id), jsonEncode(encode(value)));
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      AppLogger.forCategory(logCategory).w('$prefix:writeFailed',
          fields: {'id': id, 'err': e.toString()});
    }
  }

  Future<void> writeList(String id, List<T> values) async {
    final box = _liveBox;
    if (box == null) return;
    try {
      await box.put(_keyFor(id), jsonEncode(values.map(encode).toList()));
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      AppLogger.forCategory(logCategory).w('$prefix:writeListFailed',
          fields: {'id': id, 'err': e.toString()});
    }
  }

  Future<void> writeRaw(String id, Map<String, dynamic> raw) async {
    final box = _liveBox;
    if (box == null) return;
    try {
      await box.put(_keyFor(id), jsonEncode(raw));
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      AppLogger.forCategory(logCategory).w('$prefix:writeRawFailed',
          fields: {'id': id, 'err': e.toString()});
    }
  }

  Future<void> writeRawList(
      String id, List<Map<String, dynamic>> raws) async {
    final box = _liveBox;
    if (box == null) return;
    try {
      await box.put(_keyFor(id), jsonEncode(raws));
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      AppLogger.forCategory(logCategory).w('$prefix:writeRawListFailed',
          fields: {'id': id, 'err': e.toString()});
    }
  }

  Future<void> delete(String id) async {
    final box = _liveBox;
    if (box == null) return;
    try {
      await box.delete(_keyFor(id));
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      rethrow;
    }
  }

  /// Wipe every entry with this repository's prefix. Called from
  /// sign-out flows so a device shared across accounts doesn't paint
  /// the previous user's data.
  Future<void> clearAll() async {
    final box = _liveBox;
    if (box == null) return;
    try {
      final keys = box.keys
          .whereType<String>()
          .where((k) => k.startsWith(prefix))
          .toList(growable: false);
      if (keys.isEmpty) return;
      await box.deleteAll(keys);
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      rethrow;
    }
  }

  /// Delete every row whose key starts with [prefix] from the shared
  /// Hive box, without constructing a full HiveJsonCache (avoids the
  /// throwaway-encoder dance every repo's `clearAllCached` static was
  /// doing) and without throwing when the box hasn't been opened
  /// (sign-out from partial-init paths / tests).
  ///
  /// This is the ONE cleanup primitive repositories should call from
  /// their static `clearAllCached()` — every future repo added to the
  /// sign-out fan-out just names its prefix here.
  static Future<void> clearAllWithPrefix(String prefix) async {
    final box = safeSharedBox();
    if (box == null) return;
    try {
      final keys = box.keys
          .whereType<String>()
          .where((k) => k.startsWith(prefix))
          .toList(growable: false);
      if (keys.isEmpty) return;
      await box.deleteAll(keys);
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      rethrow;
    }
  }
}
