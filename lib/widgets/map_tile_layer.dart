import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Theme-aware raster `TileLayer` for every `flutter_map` instance in
/// the app.
///
///   • **Light** — the default OpenStreetMap tile set (`tile.openstreetmap.org`).
///   • **Dark**  — CartoDB's "dark_all" basemap (`{s}.basemaps.cartocdn.com/dark_all`),
///     which is a dark-styled derivative of OpenStreetMap. Free for use
///     with attribution; the {s} subdomain rotates across
///     `a / b / c / d` so tile requests aren't hitting a single origin.
///
/// Attribution obligations:
///   • OSM path: `© OpenStreetMap contributors`
///   • Carto path: adds `© CARTO`
/// We don't render the attribution overlay on every map today; that's a
/// known deficit shared between light + dark and not new to this
/// switch. When we do add it, pointing at whichever tile source is
/// active can be done off `Theme.of(context).brightness`.
///
/// Usage:
/// ```dart
/// FlutterMap(
///   options: ...,
///   children: [
///     osmTileLayer(context),
///     PolylineLayer(...),
///   ],
/// );
/// ```
///
/// Prefer this over inlining the URL — three sites already needed
/// the light / dark toggle when the helper landed (track live map,
/// track session detail map, share-card map).
TileLayer osmTileLayer(BuildContext context) {
  return _tileLayerFor(Theme.of(context).brightness);
}

/// Like [osmTileLayer] but the caller supplies the brightness. Used by
/// off-screen renders (share cards) where a `BuildContext` may not
/// have a live `Theme` yet.
TileLayer osmTileLayerForBrightness(Brightness brightness) =>
    _tileLayerFor(brightness);

TileLayer _tileLayerFor(Brightness brightness) {
  if (brightness == Brightness.dark) {
    return TileLayer(
      urlTemplate:
          'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
      subdomains: const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'com.stepbattle.stepbattle',
    );
  }
  return TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: 'com.stepbattle.stepbattle',
  );
}
