# Arena GLB — light + material optimization ask

## Problem

Field data from a real device (Samsung SM-M346B, mid-tier Mali-G68):

```
arena3d:screenInit  10:56:05.253
arena3d:onLoad      msSinceInit=15136 ms       ← the arena stutter
char3d character    msSinceMount=14403 ms      ← corner viewer, concurrent
char3d Taunt        msSinceMount=26812 ms      ← post-cinematic re-mount
```

15 s from arena screen mount to the first painted frame. The dominant
cost is not disk (the GLB is a Draco-compressed 9.8 MB) or JS parse
(model-viewer loads in ~500 ms) — it's the **PBR shader compile inside
the WebView**.

## Why the shader compile is slow

Each `city_arena_{tod}.glb` currently ships **52 KHR_lights_punctual**
entries:

- **1** directional sun (color + direction + intensity per TOD)
- **1** directional fill (opposite-side softener)
- **50** point lights, one per lamp post
   - 0 intensity at morning/afternoon
   - 1358 intensity at evening
   - 6522 intensity at night

model-viewer / three.js compile a distinct PBR shader permutation per
light-count. With 52 lights, the shader has 52 accumulation loops and
52 shadow-map samplers to configure. Compiling that on a mid-tier GPU
at cold start is the ~15 s wait.

## What we want changed

Two independent improvements. Either alone helps; both together give the
biggest win. Do them in `.blend` and re-export; **no client code change
required**.

### 1. Cluster the 50 lamp lights → 5–8 grouped point lights

Right now each lamp post is a physical point light. On the run camera
you can't see individual lamp contribution — you see the aggregate glow
along the street. Replace with **5–8 point lights placed at street-cluster
centroids**, each with roughly `(sum of lamps it replaces).intensity /
count`.

Concrete recipe:

1. In Blender, group lamp posts by their street segment. If the street
   grid is 6 blocks, that's 6 clusters.
2. Delete the per-lamp point lights.
3. Add one point light at the geometric centroid of each cluster.
4. Set its `energy` to the average of the deleted lamps' energies
   times a fudge factor (start at 1.2×; tune visually).
5. Set `radius` to ~40 % of the cluster's bounding-box diagonal so the
   falloff still gives a "street-lined" gradient at eye level.

Expected shader compile improvement: **~60 % faster** (52 → 8 lights).

Keep the emissive materials on the lamp bulbs themselves — those cost
nothing extra at shader-compile time (they read from the material's
`emissiveFactor` × `KHR_materials_emissive_strength` and blend in the
same PBR fragment). Bulb glow stays visually crisp.

### 2. Split evening / night lamps from morning / afternoon GLBs

Morning + afternoon lamps have `intensity = 0`. They contribute zero
photons but still count against the shader permutation. In those two
GLBs, **delete the lamp lights entirely** (keep the geometry + emissive
material for consistency — visually indistinguishable when energy = 0).

Result: morning + afternoon GLBs go from ~52 lights → **2 lights** (sun
+ fill). Shader compile becomes near-instant for the daytime scenes
(the ones users see most).

Expected impact on the 15 s wait: **8–10 s reduction for the daytime
TODs**, which are the ones the user is entering most often.

## Verification checklist post-export

1. Load each of the 4 GLBs in a stock model-viewer sandbox
   (`https://modelviewer.dev/editor`) and eyeball each TOD variant to
   confirm the sun / fill / lamp mix reads similarly to today.
2. Compare bounding-box + triangle count to the current file — should
   be near-identical since we're not touching geometry.
3. `du -h city_arena_*.glb` — file size should drop 10-20 % for morning
   + afternoon (fewer light nodes in the glTF JSON) and stay flat for
   evening + night.
4. Deploy to a device, open a battle, watch the log line
   `arena3d:onLoad msSinceInit=<N>`. Target: < 5 s for morning /
   afternoon, < 8 s for evening / night.

## What we've already tried (so this ask isn't a repeat)

- Runtime `setShadowConfig(exposure, environmentIntensity)` — reverted;
  it was fighting the GLB's baked lighting and washing everything to
  white. Confirmed 4 ms cost, zero impact on stutter.
- Draco geometry compression — already applied (9.8 MB is the
  post-Draco size; pre-Draco was ~17 MB per file).
- Splash preload via `rootBundle.load` — warms the Flutter asset
  bundle, but the WebView still parses / decodes the GLB independently.
- Staggered character-viewer mount — client-side change already landed
  (character corner tile now waits for arena `onLoad`). Cuts GPU
  contention during the arena's shader compile.

## Non-goals

- Removing the 50-lamp visuals entirely — the lit street IS the
  identity of the evening / night scenes. The consolidation preserves
  that; it does not strip the vibe.
- Migrating away from model-viewer to a native 3D renderer — that's a
  weeks-long project and out of scope for this optimization.
