import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/services/geo_service.dart';

void main() {
  group('HomeLocation.summary', () {
    test('shows district + state when both are present', () {
      const home = HomeLocation(
        countryCode: 'IN',
        countryName: 'India',
        stateName: 'Telangana',
        districtName: 'Hyderabad',
        lat: 17.385,
        lng: 78.486,
      );
      expect(home.summary, 'Hyderabad, Telangana');
    });

    test('shows just state when district missing', () {
      const home = HomeLocation(
        countryCode: 'IN',
        countryName: 'India',
        stateName: 'Telangana',
        districtName: null,
        lat: 17.385,
        lng: 78.486,
      );
      expect(home.summary, 'Telangana');
    });

    test('falls back to country when state and district both missing', () {
      const home = HomeLocation(
        countryCode: 'IN',
        countryName: 'India',
        lat: 0,
        lng: 0,
      );
      expect(home.summary, 'India');
    });

    test('district + state gets capped at 2 parts (no country tail)', () {
      const home = HomeLocation(
        countryCode: 'US',
        countryName: 'United States',
        stateName: 'California',
        districtName: 'San Francisco',
        lat: 0,
        lng: 0,
      );
      expect(home.summary, 'San Francisco, California');
      expect(home.summary.contains('United States'), isFalse);
    });

    test('treats empty strings the same as null', () {
      const home = HomeLocation(
        countryCode: 'IN',
        countryName: 'India',
        stateName: '',
        districtName: '',
        lat: 0,
        lng: 0,
      );
      expect(home.summary, 'India');
    });
  });
}
