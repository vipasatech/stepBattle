import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/screens/map/map_screen.dart';

/// Pure-logic tests for the [MapTier] state machine. The map now runs
/// on five tiers: world → country → state → city → district. `city`
/// is a zoom preset without its own polygon data; the tier chain
/// still needs to traverse it cleanly.
void main() {
  group('MapTierX.oneOut', () {
    test('district → city → state → country → world → null', () {
      expect(MapTier.district.oneOut, MapTier.city);
      expect(MapTier.city.oneOut, MapTier.state);
      expect(MapTier.state.oneOut, MapTier.country);
      expect(MapTier.country.oneOut, MapTier.world);
      expect(MapTier.world.oneOut, isNull);
    });
  });

  group('MapTierX.oneIn', () {
    test('world → country → state → city → district → null', () {
      expect(MapTier.world.oneIn, MapTier.country);
      expect(MapTier.country.oneIn, MapTier.state);
      expect(MapTier.state.oneIn, MapTier.city);
      expect(MapTier.city.oneIn, MapTier.district);
      expect(MapTier.district.oneIn, isNull);
    });
  });

  group('MapTierX.targetZoom', () {
    test('zoom levels are strictly monotonic across tiers', () {
      // World should be the most zoomed-out, district the most zoomed-in.
      expect(MapTier.world.targetZoom, lessThan(MapTier.country.targetZoom));
      expect(MapTier.country.targetZoom, lessThan(MapTier.state.targetZoom));
      expect(MapTier.state.targetZoom, lessThan(MapTier.city.targetZoom));
      expect(MapTier.city.targetZoom, lessThan(MapTier.district.targetZoom));
    });

    test('all targetZoom values are within flutter_map render range', () {
      for (final tier in MapTier.values) {
        expect(tier.targetZoom, greaterThanOrEqualTo(1.0));
        expect(tier.targetZoom, lessThanOrEqualTo(12.0));
      }
    });
  });

  group('MapTierX.label', () {
    test('label matches the enum name in upper case', () {
      expect(MapTier.world.label, 'WORLD');
      expect(MapTier.country.label, 'COUNTRY');
      expect(MapTier.state.label, 'STATE');
      expect(MapTier.city.label, 'CITY');
      expect(MapTier.district.label, 'DISTRICT');
    });
  });

  group('MapTier full traversal', () {
    test('zooming all the way out from district lands at world', () {
      var t = MapTier.district;
      var steps = 0;
      while (t.oneOut != null) {
        t = t.oneOut!;
        steps++;
        // Safety: 5-tier system, no more than 4 zoom-outs needed.
        expect(steps, lessThanOrEqualTo(4));
      }
      expect(t, MapTier.world);
      expect(steps, 4);
    });

    test('zooming all the way in from world lands at district', () {
      var t = MapTier.world;
      var steps = 0;
      while (t.oneIn != null) {
        t = t.oneIn!;
        steps++;
        expect(steps, lessThanOrEqualTo(4));
      }
      expect(t, MapTier.district);
      expect(steps, 4);
    });
  });
}
