import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
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

/// CARTO basemap key, from `.env`. Empty when unset.
///
/// CARTO began requiring a key for RASTER basemaps around August 2026;
/// unauthenticated requests still return tiles, but every one is stamped
/// "API KEY REQUIRED · carto.com/basemaps/apikey" over a blank background.
/// That is what shipped to TestFlight in 1.1.7+44 — Android had not shown
/// it only because long-lived installs were serving tiles cached from
/// before the change.
///
/// The endpoint moved at the same time: `/dark_all/` became
/// `/rastertiles/dark_all/`, and the key goes on as `?key=`.
///
/// Free allowance is 5M tile requests/month for non-commercial use and
/// **1M/month for commercial** — which is us, since the app sells a Pro
/// subscription. Past that, CARTO want a Basemaps Commercial plan. Worth
/// re-checking if a map ever lands on a high-traffic screen.
String get _cartoKey => (dotenv.env['CARTO_API_KEY'] ?? '').trim();

TileLayer _tileLayerFor(Brightness brightness) {
  final key = _cartoKey;

  // Dark basemap, but only when we can authenticate. Without a key the
  // honest fallback is OSM's standard tiles: a light map inside a dark app
  // looks wrong, and a map plastered with watermarks looks broken. Wrong
  // beats broken, and it keeps a keyless dev build usable.
  if (brightness == Brightness.dark && key.isNotEmpty) {
    return TileLayer(
      urlTemplate:
          'https://basemaps.cartocdn.com/rastertiles/dark_all/{z}/{x}/{y}.png'
          '?key=$key',
      userAgentPackageName: _userAgent,
    );
  }
  return TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: _userAgent,
  );
}

/// Must be a real, identifying bundle id: OSM's tile usage policy blocks
/// clients that do not identify themselves, and this previously claimed
/// `com.stepbattle.stepbattle`, which is not an identifier this app has
/// ever shipped under.
const String _userAgent = 'com.vipasa.stepbattle';
