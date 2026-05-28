import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../utils/app_logger.dart';

/// Where the loader fetches GeoJSON from. Three modes:
///   • [GeoBoundaryConfig.publicCdn] — hardcoded GitHub URLs (default).
///   • [GeoBoundaryConfig.firebaseStorage] — your own Firebase Storage
///     bucket. Fill [firebaseBucket] + optional [pathPrefix].
///   • Pure-asset (no network) — for the India bundle, see asset paths
///     embedded in [GeoBoundaryLoader].
class GeoBoundaryConfig {
  /// Source flavor.
  final GeoBoundarySource source;

  /// Firebase Storage bucket name, e.g., "stepbattle-cce26.appspot.com".
  /// Only used when [source] == [GeoBoundarySource.firebaseStorage].
  final String? firebaseBucket;

  /// Path prefix inside the bucket (no leading/trailing slash). Defaults to
  /// "geo" — files live at `gs://[bucket]/geo/world.geojson` etc.
  final String pathPrefix;

  const GeoBoundaryConfig({
    this.source = GeoBoundarySource.publicCdn,
    this.firebaseBucket,
    this.pathPrefix = 'geo',
  });

  /// Default config used by the app. Switch to Firebase Storage by
  /// editing this constant once you've uploaded files to your bucket.
  static const GeoBoundaryConfig active = GeoBoundaryConfig(
    source: GeoBoundarySource.publicCdn,
    // To self-host, change `source` to `firebaseStorage` and set:
    // firebaseBucket: 'stepbattle-cce26.appspot.com',
    // pathPrefix: 'geo',
  );
}

enum GeoBoundarySource { publicCdn, firebaseStorage }

/// A parsed administrative-level region — country, state, or district.
class GeoRegion {
  /// Stable identifier within its parent (e.g., ISO code for countries,
  /// state name for states). Used as key when looking up leaderboards.
  final String id;

  /// Display label for the region.
  final String name;

  /// Parsed polygon rings (outer ring at index 0; inner rings = holes).
  /// MultiPolygons are represented as multiple `polygons` entries.
  final List<List<LatLng>> polygons;

  /// Approximate centroid of the region — used to position labels +
  /// camera-fit the region on zoom.
  final LatLng center;

  /// Bounding box (sw, ne) for camera fitBounds.
  final LatLng boundsSouthWest;
  final LatLng boundsNorthEast;

  const GeoRegion({
    required this.id,
    required this.name,
    required this.polygons,
    required this.center,
    required this.boundsSouthWest,
    required this.boundsNorthEast,
  });
}

/// Lazy-downloads + caches GeoJSON boundary data for the cinematic map.
///
/// Three tiers:
///   • World     — `world.geojson` (~250KB) — fetched once per device
///   • Country   — `level1/{ISO}.geojson`  — fetched when user zooms into a country
///   • State     — districts only available for select countries (India bundled
///                 as an asset, others lazy-fetched if hosted)
///
/// Source resolution order for each path:
///   1. Bundled asset (`assets/geo/...`)        — instant, offline
///   2. Hive cache (already-downloaded bytes)  — instant after first fetch
///   3. Network fetch (CDN or Firebase Storage) — first-time only
///
/// Cache strategy: write the raw GeoJSON bytes to Hive's `geo_cache` box,
/// keyed by URL. Parsed [GeoRegion]s are kept in an in-memory map for the
/// lifetime of the app process.
class GeoBoundaryLoader {
  static const String _hiveBox = 'geo_cache';

  /// File names — same regardless of where they're hosted.
  static const String _worldFile = 'world.geojson';
  static String _level1File(String iso2) =>
      'level1/${iso2.toLowerCase()}.geojson';

  /// Asset paths for any boundaries we ship in-app. India districts are
  /// bundled here; other countries fall back to network.
  static const String _indiaDistrictsAsset =
      'assets/geo/IN-districts.geojson';

  // ── URL builders ──────────────────────────────────────────────────────────

  String _worldUrl() => _urlFor(_worldFile);
  String _level1Url(String iso2) => _urlFor(_level1File(iso2));

  String _urlFor(String relativePath) {
    final cfg = GeoBoundaryConfig.active;
    switch (cfg.source) {
      case GeoBoundarySource.publicCdn:
        // Public Natural Earth CDN. World countries + per-country level-1.
        if (relativePath == _worldFile) {
          return 'https://raw.githubusercontent.com/datasets/geo-countries/master/data/countries.geojson';
        }
        if (relativePath.startsWith('level1/')) {
          final iso = relativePath.substring(7).replaceAll('.geojson', '');
          return 'https://raw.githubusercontent.com/glynnbird/countriesgeojson/master/$iso.geojson';
        }
        return relativePath; // unknown path — caller will fail gracefully
      case GeoBoundarySource.firebaseStorage:
        // Firebase Storage public URL pattern (token-less, requires
        // public read rules on the bucket). Encodes path with `%2F`.
        final bucket = cfg.firebaseBucket ?? '';
        final prefix = cfg.pathPrefix;
        final path = Uri.encodeComponent('$prefix/$relativePath');
        return 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$path?alt=media';
    }
  }

  // Lazy-init Hive box.
  Future<Box> _box() async {
    if (Hive.isBoxOpen(_hiveBox)) return Hive.box(_hiveBox);
    return Hive.openBox(_hiveBox);
  }

  // In-memory parsed regions cache. Keyed by stable identifier (URL or asset
  // path) so subsequent calls in the same process avoid the parse cost.
  final Map<String, List<GeoRegion>> _memo = {};

  /// World countries — list of one [GeoRegion] per country.
  Future<List<GeoRegion>> loadWorldCountries() {
    return _loadAndParse(_worldUrl(), assetFallback: null);
  }

  /// State/province boundaries for one country (ISO-2 code).
  Future<List<GeoRegion>> loadStatesForCountry(String iso2) {
    return _loadAndParse(_level1Url(iso2), assetFallback: null);
  }

  /// District-level boundaries within a state. Currently only India ships
  /// bundled district data (`assets/geo/IN-districts.geojson`); other
  /// countries return an empty list and the map renders just the home pin.
  ///
  /// The bundled India file contains ALL India districts in one feature
  /// collection. We filter by state name client-side (~640 features total).
  Future<List<GeoRegion>> loadDistrictsForState({
    required String countryCode,
    required String stateName,
  }) async {
    if (countryCode.toUpperCase() != 'IN') return const [];

    final all = await _loadAndParse(
      _indiaDistrictsAsset,
      assetFallback: _indiaDistrictsAsset,
    );

    // The India districts file is loaded once and filtered per-state.
    final stateLower = stateName.toLowerCase();
    return all.where((r) {
      // We tag each region's `id` with `<state>|<district>` during parse
      // for India — see the parser below.
      final parts = r.id.split('|');
      if (parts.length != 2) return false;
      return parts[0].toLowerCase() == stateLower;
    }).toList();
  }

  /// Read bytes from any of: in-memory memo → bundled asset → Hive cache
  /// → network. [assetFallback] is consulted if the [primaryKey] starts
  /// with `assets/`, in which case no network is attempted.
  Future<List<GeoRegion>> _loadAndParse(
    String primaryKey, {
    required String? assetFallback,
  }) async {
    if (_memo.containsKey(primaryKey)) {
      AppLogger.geo.t('geoBoundary:memo', fields: {'key': primaryKey});
      return _memo[primaryKey]!;
    }

    final bytes = await _readBytes(primaryKey, assetFallback: assetFallback);
    if (bytes == null) {
      AppLogger.geo.w('geoBoundary:bytesMissing', fields: {'key': primaryKey});
      return const [];
    }

    final isIndiaDistricts = primaryKey == _indiaDistrictsAsset;
    final parsed = parseGeoJsonFeatures(
      utf8.decode(bytes),
      tagWithStateForIndia: isIndiaDistricts,
    );
    _memo[primaryKey] = parsed;
    AppLogger.geo.i('geoBoundary:loaded',
        fields: {'key': primaryKey, 'regions': parsed.length});
    return parsed;
  }

  Future<List<int>?> _readBytes(
    String primaryKey, {
    required String? assetFallback,
  }) async {
    // 1. Asset path? Read from rootBundle.
    if (primaryKey.startsWith('assets/')) {
      try {
        final bd = await rootBundle.load(primaryKey);
        return bd.buffer.asUint8List();
      } catch (_) {
        return null;
      }
    }

    // 2. Hive-cached previously?
    final box = await _box();
    final cached = box.get(primaryKey) as List<dynamic>?;
    if (cached != null) return cached.cast<int>();

    // 3. Asset fallback (declared)?
    if (assetFallback != null) {
      try {
        final bd = await rootBundle.load(assetFallback);
        return bd.buffer.asUint8List();
      } catch (_) {/* fall through to network */}
    }

    // 4. Network.
    try {
      final res = await http
          .get(Uri.parse(primaryKey))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return null;
      await box.put(primaryKey, res.bodyBytes);
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Minimal GeoJSON parser — extracts Polygon / MultiPolygon outlines.
  // ---------------------------------------------------------------------------

  /// Parses a GeoJSON FeatureCollection into [GeoRegion]s.
  ///
  /// Exposed publicly for unit testing — production callers go through
  /// [_loadAndParse] which adds caching. The parser handles `Polygon` and
  /// `MultiPolygon` geometries; inner rings (holes) are dropped at the
  /// scale we render.
  ///
  /// When [tagWithStateForIndia] is true, each region's `id` is set to
  /// `<state>|<district>` so callers can filter by state without having
  /// to re-parse the bundle.
  @visibleForTesting
  List<GeoRegion> parseGeoJsonFeatures(
    String src, {
    bool tagWithStateForIndia = false,
  }) {
    final root = jsonDecode(src) as Map<String, dynamic>;
    final features = (root['features'] as List?) ?? const [];
    final out = <GeoRegion>[];

    for (final f in features) {
      final feature = f as Map<String, dynamic>;
      final geom = feature['geometry'] as Map<String, dynamic>?;
      final props = feature['properties'] as Map<String, dynamic>? ?? {};
      if (geom == null) continue;

      final polygons = _extractPolygons(geom);
      if (polygons.isEmpty) continue;

      final allPoints = polygons.expand((p) => p).toList();
      final bounds = _bounds(allPoints);
      final center = _centroidOf(allPoints);

      // Try common name fields across Natural Earth / data-packaged /
      // GADM variants.
      final name = (props['name'] ??
              props['NAME'] ??
              props['name_en'] ??
              props['ADMIN'] ??
              props['NAME_EN'] ??
              props['DISTRICT'] ??
              props['District'] ??
              props['district'] ??
              props['NAME_2'] ??
              '?')
          .toString();

      String id;
      if (tagWithStateForIndia) {
        // India district file: tag each region as "<state>|<district>" so
        // we can filter by state at query time without re-parsing.
        final stateName = (props['STATE'] ??
                props['State'] ??
                props['state'] ??
                props['NAME_1'] ??
                '')
            .toString();
        id = '$stateName|$name';
      } else {
        id = (props['ISO_A2'] ??
                props['iso_a2'] ??
                props['ISO_A2_EH'] ??
                props['iso_a2_eh'] ??
                props['adm0_a3'] ??
                props['ADM1_CODE'] ??
                name)
            .toString();
      }

      out.add(GeoRegion(
        id: id,
        name: name,
        polygons: polygons,
        center: center,
        boundsSouthWest: bounds.$1,
        boundsNorthEast: bounds.$2,
      ));
    }
    return out;
  }

  /// Extract polygon outer rings from a Polygon or MultiPolygon geometry.
  /// Drops inner holes (we don't render them — minor visual inaccuracy at
  /// the scale we care about).
  List<List<LatLng>> _extractPolygons(Map<String, dynamic> geom) {
    final type = geom['type'] as String?;
    final coords = geom['coordinates'];
    if (coords == null) return const [];

    if (type == 'Polygon') {
      // coords: [outer ring, hole1, hole2, ...]
      final rings = coords as List<dynamic>;
      if (rings.isEmpty) return const [];
      return [_parseRing(rings.first as List<dynamic>)];
    }
    if (type == 'MultiPolygon') {
      // coords: [polygon1, polygon2, ...] each with [outer, hole...]
      final polys = coords as List<dynamic>;
      return [
        for (final p in polys)
          if ((p as List).isNotEmpty)
            _parseRing((p).first as List<dynamic>),
      ];
    }
    return const [];
  }

  List<LatLng> _parseRing(List<dynamic> ring) {
    final pts = <LatLng>[];
    for (final coord in ring) {
      final c = coord as List<dynamic>;
      // GeoJSON is [lng, lat]
      final lng = (c[0] as num).toDouble();
      final lat = (c[1] as num).toDouble();
      pts.add(LatLng(lat, lng));
    }
    return pts;
  }

  (LatLng, LatLng) _bounds(List<LatLng> pts) {
    if (pts.isEmpty) {
      return (const LatLng(0, 0), const LatLng(0, 0));
    }
    var minLat = pts.first.latitude;
    var maxLat = pts.first.latitude;
    var minLng = pts.first.longitude;
    var maxLng = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return (LatLng(minLat, minLng), LatLng(maxLat, maxLng));
  }

  LatLng _centroidOf(List<LatLng> pts) {
    if (pts.isEmpty) return const LatLng(0, 0);
    var lat = 0.0, lng = 0.0;
    for (final p in pts) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / pts.length, lng / pts.length);
  }
}
