import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/services/geo_boundary_loader.dart';

void main() {
  // The parser is exposed via @visibleForTesting on GeoBoundaryLoader.
  // We don't need network or Hive for these tests — pure string-in,
  // GeoRegion-out.
  final loader = GeoBoundaryLoader();

  group('parseGeoJsonFeatures', () {
    test('parses a single Polygon feature with name + ISO code', () {
      const src = '''
      {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "properties": {"name": "TestLand", "ISO_A2": "TL"},
            "geometry": {
              "type": "Polygon",
              "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]]
            }
          }
        ]
      }
      ''';
      final regions = loader.parseGeoJsonFeatures(src);
      expect(regions, hasLength(1));
      expect(regions.first.name, 'TestLand');
      expect(regions.first.id, 'TL');
      expect(regions.first.polygons, hasLength(1));
      expect(regions.first.polygons.first, hasLength(5));
      expect(regions.first.polygons.first.first.latitude, 0);
      expect(regions.first.polygons.first.first.longitude, 0);
    });

    test('parses MultiPolygon yielding multiple polygon rings', () {
      const src = '''
      {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "properties": {"name": "Archipelago"},
            "geometry": {
              "type": "MultiPolygon",
              "coordinates": [
                [[[0,0],[1,0],[1,1],[0,1],[0,0]]],
                [[[10,10],[11,10],[11,11],[10,11],[10,10]]]
              ]
            }
          }
        ]
      }
      ''';
      final regions = loader.parseGeoJsonFeatures(src);
      expect(regions, hasLength(1));
      expect(regions.first.polygons, hasLength(2));
    });

    test('drops inner rings (holes) — only outer ring kept', () {
      // Outer ring [0,0..2,2], hole inside [0.5,0.5..1.5,1.5].
      // Parser should keep only the outer.
      const src = '''
      {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "properties": {"name": "WithHole"},
            "geometry": {
              "type": "Polygon",
              "coordinates": [
                [[0,0],[2,0],[2,2],[0,2],[0,0]],
                [[0.5,0.5],[1.5,0.5],[1.5,1.5],[0.5,1.5],[0.5,0.5]]
              ]
            }
          }
        ]
      }
      ''';
      final regions = loader.parseGeoJsonFeatures(src);
      expect(regions, hasLength(1));
      expect(regions.first.polygons, hasLength(1));
      expect(regions.first.polygons.first, hasLength(5));
    });

    test('tags regions with state|district when India flag is set', () {
      const src = '''
      {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "properties": {"district": "Hyderabad", "state": "Telangana"},
            "geometry": {
              "type": "Polygon",
              "coordinates": [[[0,0],[1,0],[1,1],[0,1],[0,0]]]
            }
          },
          {
            "type": "Feature",
            "properties": {"district": "Bengaluru Urban", "state": "Karnataka"},
            "geometry": {
              "type": "Polygon",
              "coordinates": [[[0,0],[1,0],[1,1],[0,1],[0,0]]]
            }
          }
        ]
      }
      ''';
      final regions =
          loader.parseGeoJsonFeatures(src, tagWithStateForIndia: true);
      expect(regions, hasLength(2));
      expect(regions[0].id, 'Telangana|Hyderabad');
      expect(regions[0].name, 'Hyderabad');
      expect(regions[1].id, 'Karnataka|Bengaluru Urban');
    });

    test('falls back through alt name fields (NAME, ADMIN, NAME_2, etc.)', () {
      const src = '''
      {
        "type": "FeatureCollection",
        "features": [
          { "type": "Feature",
            "properties": {"NAME": "AltName"},
            "geometry": {"type": "Polygon",
              "coordinates": [[[0,0],[1,0],[1,1],[0,0]]]}
          },
          { "type": "Feature",
            "properties": {"ADMIN": "AdminLand"},
            "geometry": {"type": "Polygon",
              "coordinates": [[[0,0],[1,0],[1,1],[0,0]]]}
          },
          { "type": "Feature",
            "properties": {"NAME_2": "DistrictNameTwo"},
            "geometry": {"type": "Polygon",
              "coordinates": [[[0,0],[1,0],[1,1],[0,0]]]}
          }
        ]
      }
      ''';
      final regions = loader.parseGeoJsonFeatures(src);
      expect(regions[0].name, 'AltName');
      expect(regions[1].name, 'AdminLand');
      expect(regions[2].name, 'DistrictNameTwo');
    });

    test('skips features without geometry', () {
      const src = '''
      {
        "type": "FeatureCollection",
        "features": [
          { "type": "Feature", "properties": {"name": "GhostLand"} },
          { "type": "Feature",
            "properties": {"name": "Real"},
            "geometry": {"type": "Polygon",
              "coordinates": [[[0,0],[1,0],[1,1],[0,0]]]}
          }
        ]
      }
      ''';
      final regions = loader.parseGeoJsonFeatures(src);
      expect(regions, hasLength(1));
      expect(regions.first.name, 'Real');
    });

    test('returns empty list for empty FeatureCollection', () {
      const src = '{"type":"FeatureCollection","features":[]}';
      final regions = loader.parseGeoJsonFeatures(src);
      expect(regions, isEmpty);
    });

    test('computes plausible bounding box + centroid', () {
      const src = '''
      {
        "type": "FeatureCollection",
        "features": [{
          "type": "Feature",
          "properties": {"name": "Square"},
          "geometry": {
            "type": "Polygon",
            "coordinates": [[[10,20],[30,20],[30,40],[10,40],[10,20]]]
          }
        }]
      }
      ''';
      final r = loader.parseGeoJsonFeatures(src).first;
      // GeoJSON is [lng, lat] — so this is lng 10..30, lat 20..40.
      expect(r.boundsSouthWest.longitude, 10);
      expect(r.boundsSouthWest.latitude, 20);
      expect(r.boundsNorthEast.longitude, 30);
      expect(r.boundsNorthEast.latitude, 40);
      // Centroid is the simple average of points (incl. closing point).
      expect(r.center.longitude, closeTo(18, 0.0001));
      expect(r.center.latitude, closeTo(28, 0.0001));
    });
  });
}
