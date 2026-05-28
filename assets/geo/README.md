# Bundled geo boundary data

Files in this directory are shipped inside the APK and read by
`lib/services/geo_boundary_loader.dart`.

## `IN-districts.geojson`

Currently a placeholder (empty FeatureCollection). To enable
district-level rendering on the cinematic map for Indian users, replace
this file with the real Indian district boundaries.

### Where to get it

Pick whichever is most convenient:

1. **DataMeet India boundaries** — community-maintained, simplified, Apache 2.0
   - https://github.com/datameet/maps/tree/master/Districts
   - Concatenate the per-state district files into one `IN-districts.geojson`
2. **GADM** — high quality, free for non-commercial. Watch the license.
   - https://gadm.org/download_country.html → India → Level 2 → Better Format → GeoJSON
3. **data.gov.in** — official, varies in quality
   - https://data.gov.in/

### Required properties on each feature

The parser looks for the district name on the feature properties under any
of (in order): `district`, `District`, `DISTRICT`, `NAME_2`.

The state name is required so the loader can filter by state. It looks for:
`STATE`, `State`, `state`, `NAME_1`.

If your source uses different field names, either rename them at build time
or update `_parseGeoJsonFeatures` in
`lib/services/geo_boundary_loader.dart`.

### Simplification

Run the data through https://mapshaper.org with simplification at ~5–10%
before bundling — the difference between a 50MB raw GADM dump and a 3MB
mobile-friendly file is just simplification level.

### What happens with the placeholder

The empty FeatureCollection causes `loadDistrictsForState` to return an
empty list. The map still works — it just doesn't draw district polygons,
only the home pin at district zoom. Other countries will see the same
behavior (no district polygons available globally).
