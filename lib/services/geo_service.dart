import 'dart:convert';
import 'package:geocoding/geocoding.dart' as gc;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/app_logger.dart';

/// Resolved home address for a user — country / state / district level.
/// Free-form local names returned by the platform geocoder; codes when
/// available (ISO 3166-1 alpha-2 country code).
class HomeLocation {
  final String countryCode; // e.g., "IN"
  final String countryName; // e.g., "India"
  final String? stateName; // e.g., "Telangana"
  final String? districtName; // e.g., "Hyderabad"
  final double lat;
  final double lng;

  const HomeLocation({
    required this.countryCode,
    required this.countryName,
    this.stateName,
    this.districtName,
    required this.lat,
    required this.lng,
  });

  /// Best display name: "Hyderabad, Telangana" or whatever's available.
  String get summary {
    final parts = <String>[
      if (districtName != null && districtName!.isNotEmpty) districtName!,
      if (stateName != null && stateName!.isNotEmpty) stateName!,
      if ((districtName == null || districtName!.isEmpty) &&
          (stateName == null || stateName!.isEmpty))
        countryName,
    ];
    return parts.take(2).join(', ');
  }
}

/// Resolves a user's home district using two complementary paths:
///   1. Device location  — request COARSE_LOCATION, fetch a fix, reverse-
///      geocode on-device via the OS-native Geocoder. Free, fast, no API
///      key. Used when the user taps "Use my location" at signup.
///   2. PIN / postal code — call api.postalpincode.in (India) or
///      Zippopotam.us (international fallback). Free public APIs, no key.
///      Used when the user types a postal code instead of using GPS.
///
/// Returns a [HomeLocation] with whatever fields the source provided.
class GeoService {
  /// Request location permission and grab a single coarse-location fix.
  ///
  /// Returns null if:
  ///   - Location services are disabled at OS level
  ///   - User denies the runtime permission
  ///   - GPS times out (10s)
  Future<Position?> getCurrentLocation() async {
    AppLogger.geo.i('getCurrentLocation:start');
    if (!await Geolocator.isLocationServiceEnabled()) {
      AppLogger.geo.w('getCurrentLocation:servicesOff');
      return null;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      AppLogger.geo
          .i('getCurrentLocation:permRequested', fields: {'result': permission.name});
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) {
      AppLogger.geo.w('getCurrentLocation:deniedForever');
      return null;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        // Coarse is enough for district-level — saves battery + faster fix.
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 10),
        ),
      );
      AppLogger.geo.i('getCurrentLocation:done',
          fields: {'lat': pos.latitude, 'lng': pos.longitude});
      return pos;
    } catch (e, s) {
      AppLogger.geo.e('getCurrentLocation:failed', error: e, stack: s);
      return null;
    }
  }

  /// Reverse-geocode a lat/lng into a [HomeLocation] using the platform's
  /// native geocoder (free; uses Google Play Services on Android, CLGeocoder
  /// on iOS). Returns null if the geocoder couldn't resolve.
  Future<HomeLocation?> reverseGeocode(double lat, double lng) async {
    try {
      final placemarks = await gc.placemarkFromCoordinates(lat, lng);
      if (placemarks.isEmpty) return null;
      final p = placemarks.first;

      final country = p.country?.trim() ?? '';
      final iso = p.isoCountryCode?.trim().toUpperCase() ?? '';
      if (iso.isEmpty || country.isEmpty) return null;

      // `subAdministrativeArea` ≈ district / county / borough
      // `administrativeArea` ≈ state / province
      // `locality` ≈ city / town — used as a fallback if no district
      final district = (p.subAdministrativeArea?.trim().isNotEmpty ?? false)
          ? p.subAdministrativeArea!.trim()
          : (p.locality?.trim().isNotEmpty ?? false)
              ? p.locality!.trim()
              : null;
      final state = p.administrativeArea?.trim().isNotEmpty == true
          ? p.administrativeArea!.trim()
          : null;

      return HomeLocation(
        countryCode: iso,
        countryName: country,
        stateName: state,
        districtName: district,
        lat: lat,
        lng: lng,
      );
    } catch (_) {
      return null;
    }
  }

  /// Resolve a postal code → [HomeLocation]. Uses Indian Post's free
  /// `api.postalpincode.in` for 6-digit Indian PINs; Zippopotam.us for
  /// other countries (free, no key, supports ~60 countries).
  ///
  /// [countryCode] is an ISO 3166-1 alpha-2 hint when known; if omitted,
  /// 6-digit numeric inputs assume India.
  Future<HomeLocation?> resolvePincode(
    String pincode, {
    String? countryCode,
  }) async {
    final clean = pincode.trim().replaceAll(RegExp(r'\s+'), '');
    if (clean.isEmpty) return null;

    // Indian PIN code (6 digits, all numeric) — use api.postalpincode.in
    if (countryCode == 'IN' ||
        (countryCode == null && RegExp(r'^\d{6}$').hasMatch(clean))) {
      return _resolveIndianPin(clean);
    }

    // Everywhere else — Zippopotam.us
    final cc = (countryCode ?? 'US').toLowerCase();
    return _resolveZippopotam(cc, clean);
  }

  Future<HomeLocation?> _resolveIndianPin(String pin) async {
    try {
      final res = await http
          .get(Uri.parse('https://api.postalpincode.in/pincode/$pin'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as List<dynamic>;
      if (body.isEmpty) return null;
      final entry = body.first as Map<String, dynamic>;
      if (entry['Status'] != 'Success') return null;
      final offices = entry['PostOffice'] as List<dynamic>?;
      if (offices == null || offices.isEmpty) return null;
      final office = offices.first as Map<String, dynamic>;

      final district = office['District'] as String?;
      final state = office['State'] as String?;
      // postalpincode.in doesn't return lat/lng; we'll fall back to a
      // state-level coarse location via reverse-geocode of the state name
      // when we need lat/lng. For now, return 0,0 — the map screen handles
      // missing coords gracefully by zooming to the country instead.
      return HomeLocation(
        countryCode: 'IN',
        countryName: 'India',
        stateName: state,
        districtName: district,
        lat: 0,
        lng: 0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<HomeLocation?> _resolveZippopotam(
      String countryCode, String postalCode) async {
    try {
      final res = await http
          .get(Uri.parse('https://api.zippopotam.us/$countryCode/$postalCode'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final places = body['places'] as List<dynamic>?;
      if (places == null || places.isEmpty) return null;
      final place = places.first as Map<String, dynamic>;
      return HomeLocation(
        countryCode: countryCode.toUpperCase(),
        countryName: body['country'] as String? ?? '',
        stateName: place['state'] as String?,
        districtName: place['place name'] as String?,
        lat: double.tryParse(place['latitude'] as String? ?? '') ?? 0,
        lng: double.tryParse(place['longitude'] as String? ?? '') ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Persist resolved [HomeLocation] to the user's Supabase profile row.
  /// Geo-scoped leaderboards read from these columns
  /// ([LeaderboardService.getDistrictRanks] etc.).
  Future<void> saveHomeForUser({
    required String userId,
    required HomeLocation home,
  }) async {
    AppLogger.geo.i('saveHomeForUser', fields: {
      'userId': userId,
      'countryCode': home.countryCode,
      'state': home.stateName,
      'district': home.districtName,
    });
    try {
      await Supabase.instance.client.from('profiles').update({
        'country_code': home.countryCode,
        'country_name': home.countryName,
        'state_name': home.stateName,
        'district_name': home.districtName,
        'home_lat': home.lat,
        'home_lng': home.lng,
        'home_set_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
    } catch (e, s) {
      AppLogger.geo.e('saveHomeForUser:failed',
          fields: {'userId': userId}, error: e, stack: s);
      rethrow;
    }
  }
}
