# Voronoi Mesh Fracture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A configurable Parallel Luau library that breaks a MeshPart into Voronoi pieces, plus a click-Suzanne demo.

**Architecture:** Pure geometry modules (no instance APIs) cut one closed copy of the mesh per cell by bisector planes. A serial reader turns an `EditableMesh` into plain data, a scheduler runs cells serially or on Actors, and a serial builder turns the results into MeshParts.

**Tech Stack:** Luau, Rojo 7.7.1, Roblox `EditableMesh`/`AssetService`, Actors, `SharedTable`, `buffer`.

**Spec:** `docs/superpowers/specs/2026-11-27-voronoi-fracture-design.md`

## Global Constraints

- `EditableMesh` reads are safe in parallel. All writes, `CreateEditableMesh*` and `CreateMeshPartAsync` are serial only.
- Geometry modules call no Instance or Service APIs and never `require` in a parallel phase.
- All geometry is in part-local studs: mesh positions times `Size / MeshSize`.
- One `EditableMesh` holds at most 60,000 vertices or 20,000 triangles.
- Never set `Object` content on a server-side Instance that replicates.
- Defaults: `workers = 8` (0 = serial), `collisionFidelity = Hull`, `seed = 1`.
- The same seed, mesh and config give the same pieces.
- The source part is never modified by the library. It is never hidden when a fracture failed.
- Piece volumes add up to the source volume within 0.5%.
- Target: 32 sites on Suzanne within 100 ms. The frame budget wins over the target.
- Playtests need **Experience Settings > Security > Allow Mesh / Image APIs** (owner's action; never change it yourself).
- Studio instance: "Voronoi Suzzane", placeId 98017474124994. Never touch the other open place.
- Edit files in the repo, not scripts in Studio; `rojo serve` syncs them. No git worktree: Rojo serves from the repo root.
- Commit steps apply only if the owner allowed commits; use branch `voronoi-fracture`, never `main`.

## Review Focus

1. Bisectors passing exactly through vertices or edges (symmetric sites on a symmetric mesh): watertight, volume conserved. (Task 4)
2. Duplicate sites, a single site, or sites far outside the mesh: no NaN, no error, empty cells omitted. (Task 4)
3. Flat or tiny sliver cells: skipped with a warning; they never fail the whole fracture. (Task 7)
4. Two fractures overlapping in time: both correct, no cross-talk. (Task 8)
5. A worker that errors or never replies: the fracture raises, the source is untouched, the next call works. (Task 8)

## File map

| Path | Responsibility |
|---|---|
| `src/shared/Voronoi/init.luau` | Public API: `fracture`, `Points`, `Config`, `shutdown` |
| `src/shared/Voronoi/Config.luau` | Defaults and validation |
| `src/shared/Voronoi/Points.luau` | Site generation |
| `src/shared/Voronoi/Geometry/Triangulate.luau` | Planar loops with holes to triangles (pure) |
| `src/shared/Voronoi/Geometry/MeshData.luau` | Mesh representation and operations (pure) |
| `src/shared/Voronoi/Geometry/CellCutter.luau` | Cut one cell (pure) |
| `src/shared/Voronoi/MeshReader.luau` | `EditableMesh` to `MeshData` (serial) |
| `src/shared/Voronoi/PartBuilder.luau` | `MeshData` to MeshParts (serial) |
| `src/shared/Voronoi/Scheduler.luau` | Serial or Actor execution, frame budget |
| `src/shared/Voronoi/Workers/` | `WorkerMain.luau`, `ClientWorker.client.luau`, `ServerWorker.server.luau` |
| `src/demo/server/init.server.luau`, `src/demo/client/init.client.luau` | Click demo |
| `tests/` | `Runner.luau`, `Fixtures.luau`, `*.spec.luau` |

## Running tests

Run with the Studio MCP `execute_luau` tool (`datamodel_type` "Edit" unless a task says otherwise):

```lua
return require(game:GetService("ReplicatedStorage").VoronoiTests.Runner:Clone())("MeshData")
```

The argument is a spec name filter; omit it to run all. Passing output ends `FAIL 0`.

A playtest is a snapshot: files edited during Play reach only the Edit datamodel. Stop and start Play again after every edit.

A spec is a ModuleScript returning `function(lib: Instance): { [string]: () -> () }`, where `lib` is a fresh clone of the `Voronoi` module tree.

---

### Task 1: Project wiring, test runner, Config

**Files:**
- Modify: `default.project.json`
- Create: `src/server/init.meta.json`, `src/shared/Voronoi/init.luau` (returns an empty table for now), `src/shared/Voronoi/Config.luau`, `tests/Runner.luau`, `tests/Config.spec.luau`

**Interfaces:**
- Produces: `Config.defaults` (frozen), `Config.resolve(overrides: { [string]: any }?): Config`
- Produces: `Runner(filter: string?): string`
- Config keys and defaults: `count=32, seed=1, distribution="uniform", focus=nil, focusRadius=nil, minSpacing=0, boundsPadding=0, closeHoles=true, splitIslands=true, capColor=nil, workers=8, frameBudgetMs=4, collisionFidelity=Hull, renderFidelity=Automatic, force=40, upwardBias=0.35, resetAfter=6`

- [ ] **Step 1: Add Rojo mappings.** `ReplicatedStorage.Voronoi` → `src/shared/Voronoi`; `ReplicatedStorage.VoronoiTests` → `tests` (it must replicate so tests can run on the client). Keep the existing `ServerScriptService.Script` entry. Every service node gets `"$ignoreUnknownInstances": true`.
- [ ] **Step 2: Disable the old script** with `src/server/init.meta.json`: `{"properties": {"Disabled": true}}`
- [ ] **Step 3: Write `tests/Runner.luau`.** Clone `ReplicatedStorage.Voronoi` into a temporary folder in `ReplicatedStorage`, require a clone of each matching `*.spec` from `ReplicatedStorage.VoronoiTests` (so edits are picked up), `pcall` each test, call the cloned library's `shutdown` if it has one, destroy the folder, return one `FAIL <spec> / <test>: <error>` line per failure and a final `PASS n FAIL m`. Specs reach `Fixtures` through `game.ReplicatedStorage.VoronoiTests.Fixtures:Clone()`.
- [ ] **Step 4: Write the failing test** `tests/Config.spec.luau`:

```lua
return function(lib)
	local Config = require(lib.Config)
	return {
		defaults = function()
			local c = Config.resolve()
			assert(c.count == 32 and c.workers == 8 and c.seed == 1 and c.frameBudgetMs == 4)
			assert(c.collisionFidelity == Enum.CollisionFidelity.Hull)
		end,
		override_does_not_leak = function()
			assert(Config.resolve({ count = 5 }).count == 5)
			assert(Config.resolve().count == 32)
		end,
		unknown_key_errors = function()
			local ok, err = pcall(Config.resolve, { cout = 5 })
			assert(not ok and string.find(err, "cout"))
		end,
		invalid_values_error = function()
			for _, bad in { { count = 0 }, { count = 1.5 }, { workers = -1 }, { distribution = "x" }, { frameBudgetMs = 0 }, { minSpacing = -1 } } do
				assert(not pcall(Config.resolve, bad))
			end
		end,
	}
end
```

- [ ] **Step 5: Confirm sync and failure.** Run the tests. Expected: failure because `Config` is missing. If `ReplicatedStorage.VoronoiTests` does not exist, restart `rojo serve` and ask the owner to reconnect. Also confirm `ServerScriptService.Script.Disabled == true`.
- [ ] **Step 6: Implement `Config.luau`.** `resolve` errors naming the offending key.
- [ ] **Step 7: Run tests.** Expected: `PASS 4 FAIL 0`.
- [ ] **Step 8: Gate, opaque content (Edit).** Make a small box `EditableMesh`, convert it with `CreateDataModelContentAsync`, pass the result to `CreateMeshPartAsync`, destroy the mesh. Expect a part with the box's `MeshSize` that a `WorkspaceRoot:Raycast` hits (use a temporary part, then destroy it). If it fails, Task 7 uses only fixed-size copies.
- [ ] **Step 9: Gate, setting.** Start a playtest; in the `Client` datamodel call `game:GetService("AssetService"):CreateEditableMesh()`. If it errors, ask the owner to enable the setting, skip Steps 10 and 11, carry on with Tasks 2-7 in Edit, and run them before Task 8.
- [ ] **Step 10: Gate, replication.** In a playtest, from `Server`: build one MeshPart from `Content.fromObject` and one from `CreateDataModelContentAsync` content, parent both in view. On the client, `screen_capture` and also call `CreateEditableMeshAsync(probe.MeshContent)` and count faces (the capture tool is described as edit-time, so do not rely on it alone). **If the opaque one renders on the client, stop after this task, destroy the probes and ask the owner** whether the demo should fracture on the server instead.
- [ ] **Step 11: Gate, client Actors.** Temporarily add a `ModuleScript` under `ReplicatedStorage` and a `.client.luau` worker under `src/` that is cloned into an Actor in `PlayerScripts`, requires the module serially, and reports from a `BindToMessageParallel` callback that the module's function ran with `task.synchronize` afterwards. Expect a reply and no errors. Remove the temporary files.
- [ ] **Step 12: Commit** `feat: project wiring, test runner and config`

### Task 2: Triangulate

**Files:** Create `src/shared/Voronoi/Geometry/Triangulate.luau`, `tests/Triangulate.spec.luau`

**Interfaces:**
- Produces: `Triangulate.loops(points: {Vector3}, loops: {{number}}, normal: Vector3): ({number}, number)` returning flat point indices (3 per triangle, counter-clockwise about `normal`) and a warning count. Outer loops are counter-clockwise about `normal`, holes clockwise. A counter-clockwise loop nested in another is filled on its own.

- [ ] **Step 1: Write failing tests.** Points lie in z=0, `normal = Vector3.zAxis`. A helper sums `(b - a):Cross(c - a):Dot(normal) / 2`, asserts each term `>= -1e-6`, and records which indices were used.

| Test | Input | Assert |
|---|---|---|
| `square` | unit square CCW | 2 triangles, area 1 |
| `concave` | L (0,0),(2,0),(2,1),(1,1),(1,2),(0,2) | 4 triangles, area 3 |
| `hole` | square side 2 CCW, centred square side 1 CW | 8 triangles, area 3 |
| `collinear` | unit square with all four edge midpoints | 6 triangles, area 1, all 8 indices used |
| `two_outers` | two disjoint unit squares | 4 triangles, area 2 |
| `tilted` | the square rotated by `CFrame.Angles(0.7, 0.3, 0)`, normal rotated too | area 1 |
| `degenerate` | three collinear points | no error |

- [ ] **Step 2: Run, expect failure** (module missing).
- [ ] **Step 3: Implement.** Project to a 2D basis on `normal`; classify by signed area; bridge each hole to the smallest containing outer (rightmost-vertex bridge); ear-clip. Never drop a vertex: if no strictly convex ear remains, clip the flattest one and count a warning.
- [ ] **Step 4: Run, expect** `FAIL 0`.
- [ ] **Step 5: Commit** `feat: planar triangulation with holes`

### Task 3: MeshData

**Files:** Create `src/shared/Voronoi/Geometry/MeshData.luau`, `tests/Fixtures.luau`, `tests/MeshData.spec.luau`

**Interfaces:**
- Consumes: `Triangulate.loops`
- Produces:
  - `type MeshData = { positions: {Vector3}, tris: {number}, normals: {Vector3}, uvs: {Vector2}, caps: {boolean} }` (`normals`, `uvs`: one per corner, parallel to `tris`; `caps`: one per triangle)
  - `fromSoup(corners: {Vector3}, normals: {Vector3}?, uvs: {Vector2}?, weld: number?): MeshData` (3 corners per triangle; welds positions, default 1e-5; drops triangles degenerate after welding; missing normals become face normals)
  - `bounds(m): (Vector3, Vector3)`, `volume(m): number` (signed), `boundaryEdges(m): number` (undirected edges used by exactly one triangle)
  - `closeHoles(m): (MeshData, number)` (closed copy, loops closed)
  - `splitIslands(m): {MeshData}` (connected through shared position indices)
  - `pack(m): buffer`, `unpack(b: buffer): MeshData`
- Produces (Fixtures, each takes the `MeshData` module): `box(MD, center: Vector3, half: Vector3)`, `openBox(MD)` (side 2, +Y face missing), `tunnel(MD)` (4×4×2 box with a 2×2 square tunnel along Z, volume 24, watertight). All wound outward.

- [ ] **Step 1: Write fixtures and failing tests.**

| Test | Assert |
|---|---|
| `box_welds` | `box(origin, one)`: 8 positions, 12 triangles, volume 8, `boundaryEdges` 0 |
| `tunnel_closed` | volume 24, `boundaryEdges` 0 |
| `open_box` | `boundaryEdges` 4; after `closeHoles`: 1 loop, 0 boundary edges, volume 8 |
| `degenerate_dropped` | soup with one zero-area triangle added keeps 12 triangles |
| `islands` | soup of two disjoint boxes splits into 2, each volume 8 |
| `roundtrip` | `buffer.tostring(pack(unpack(pack(m)))) == buffer.tostring(pack(m))` |

Volume tolerance 1e-4.

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** `closeHoles` chains the reverse of each boundary edge into loops and triangulates each about its Newell normal; the new triangles get that normal and the corner UVs of the boundary vertices.
- [ ] **Step 4: Run, expect** `FAIL 0`.
- [ ] **Step 5: Commit** `feat: mesh data operations`

### Task 4: CellCutter

**Files:** Create `src/shared/Voronoi/Geometry/CellCutter.luau`, `tests/CellCutter.spec.luau`

**Interfaces:**
- Consumes: `MeshData`, `Triangulate.loops`, `Fixtures`
- Produces: `CellCutter.cut(source: MeshData, sites: {Vector3}, index: number, epsilon: number?): (MeshData?, { tested: number, cut: number, warnings: number })`. `nil` means an empty cell. `source` is not mutated. Default epsilon 1e-5.

- [ ] **Step 1: Write failing tests.** A helper `cells(source, sites)` cuts every index. `check(result, volume)` asserts every non-nil cell has `boundaryEdges == 0`, no NaN positions, and the volumes sum to `volume` within 0.5%.

| Test | Setup | Assert |
|---|---|---|
| `halves` | box half 1; sites {(-0.5,0,0), (0.5,0,0)} in that order | each volume 4; cell 1 max x ≈ 0; its cap triangles have normal +X |
| `octants_on_edges` | box half 1; 8 sites (±0.5,±0.5,±0.5) | each volume 1 |
| `diagonal_through_vertices` | box half 1; sites (0.5,0.5,0), (-0.5,-0.5,0) | each volume 4 |
| `buried` | box half 3; 27 sites on {-2,0,2}³ | centre cell volume 8, every triangle a cap |
| `tunnel_hole_cap` | tunnel; sites (0,0,±0.5) | each volume 12 |
| `random_conserves` | tunnel; 20 sites from `Random.new(7)` in its bounds | `check(_, 24)` |
| `single_site` | box half 1; one site | volume 8 |
| `duplicate_sites` | box half 1; sites {origin, origin, (0.5,0,0)} | cell 2 is `nil`; `check(_, 8)` |
| `far_site` | box half 1; sites {origin, (100,0,0)} | cell 2 is `nil`; cell 1 volume 8 |
| `early_exit` | box half 1; 64 sites on a grid | some cell reports `tested < 63` |
| `source_untouched` | pack source before and after | buffers equal |

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.**
  - Order other sites by distance, ties by index. An identical site with a lower index empties the cell; with a higher index it is ignored.
  - For neighbour at distance `d`: plane through the midpoint, normal `n` toward the neighbour. Stop when `d / 2 >= R` (farthest current vertex from the site). Skip if the current bounds are wholly on the kept side.
  - Signed distance per vertex once; `|dist| <= epsilon` becomes `-epsilon`. All outside: return `nil`.
  - One new vertex per crossed edge, keyed by the unordered vertex index pair, interpolated from the inside end. Interpolate corner normals and UVs.
  - Cap segment direction: walking a triangle's corners in order, call the inside-to-outside crossing X and the outside-to-inside crossing E. The cap edge runs **E → X**, which makes outer loops counter-clockwise about `n`.
  - Chain segments into loops (close dead ends back to their start and count a warning), triangulate about `n`, mark `caps`, corner normal `n`, planar UVs from a basis on the plane.
  - Compact unused positions after each cut.
- [ ] **Step 4: Run, expect** `FAIL 0`.
- [ ] **Step 5: Commit** `feat: per-cell bisector cutting`

### Task 5: Points

**Files:** Create `src/shared/Voronoi/Points.luau`, `tests/Points.spec.luau`

**Interfaces:**
- Consumes: `Config.resolve`
- Produces: `Points.sample(size: Vector3, localFocus: Vector3?, config: { [string]: any }?): {Vector3}` (pure) and `Points.generate(part: BasePart, config: { [string]: any }?): {Vector3}`. Both return part-local studs, at most `count` sites. `boundsPadding` grows (negative shrinks) each face of the box. `clustered` samples within `focusRadius` of the focus (default: a quarter of `size.Magnitude`; no focus means the centre), denser near it, clamped to the box.

- [ ] **Step 1: Write failing tests**, size (4,2,6):

| Test | Assert |
|---|---|
| `count_in_bounds` | 50 sites, all inside half-size |
| `deterministic` | same seed equal lists; seed 2 differs |
| `padding` | `boundsPadding = -0.5`: all within half-size minus 0.5 |
| `min_spacing` | `minSpacing = 1, count = 20`: every pair ≥ 1 apart |
| `impossible_spacing` | `minSpacing = 100, count = 5`: returns 1 site, no hang |
| `clustered` | focus (2,0,0), radius 0.5: all within 0.5 of it |
| `world_focus` | Part at (10,0,0) rotated 90° about Y; `focus = part.CFrame:PointToWorldSpace(Vector3.xAxis)`, `focusRadius = 0.01`: all within 0.011 of local (1,0,0) |

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement** with `Random.new(seed)`; rejection sampling capped at `count * 30` attempts.
- [ ] **Step 4: Run, expect** `FAIL 0`.
- [ ] **Step 5: Commit** `feat: site generation`

### Task 6: MeshReader

**Files:** Create `src/shared/Voronoi/MeshReader.luau`, `tests/MeshReader.spec.luau`

**Interfaces:**
- Consumes: `MeshData.fromSoup`, `MeshData.closeHoles`
- Produces: `MeshReader.read(part: MeshPart, closeHoles: boolean): (MeshData, { holes: number })` (yields; result is cached and must not be mutated; cache key is content URI, scale and `closeHoles`; `Object` and `Opaque` content is not cached), `MeshReader.clearCache()`

- [ ] **Step 1: Write failing tests** against `workspace.Map.Items.default`:

| Test | Assert |
|---|---|
| `scaled_bounds` | `bounds` extent equals `part.Size` within 0.01 |
| `closed` | `closeHoles = true`: `holes == 4`, `boundaryEdges == 0`, volume > 0 |
| `raw` | `closeHoles = false`: `boundaryEdges == 42` |
| `non_uniform` | unparented clone with `Size = Size * Vector3.new(2, 1, 0.5)`: extent equals new size |
| `cached` | two reads return the same table |
| `suzanne_cells` | `Points.generate(part, {count = 16})`, cut all: volumes sum to the source within 0.5%, every cell `boundaryEdges == 0` |
| `suzanne_cells_transformed` | same assertions on an unparented clone, rotated by `CFrame.Angles(0.5, 1, 0.2)` with the non-uniform size above |

If `suzanne_cells` fails only because of the four-face edge or the two misordered edges, report which triangles and adjust the assertion to name that defect; do not loosen the tolerance.

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement.** `CreateEditableMeshAsync(part.MeshContent, {FixedSize = true})`; per face read `GetFaceVertices`, `GetFaceNormals`/`GetNormal`, `GetFaceUVs`/`GetUV`. Scale positions by `Size / MeshSize`; scale normals by its reciprocal, then normalise. Destroy the `EditableMesh`, also on error.
- [ ] **Step 4: Run, expect** `FAIL 0`.
- [ ] **Step 5: Commit** `feat: mesh reader`

### Task 7: PartBuilder and serial fracture

**Files:** Create `src/shared/Voronoi/PartBuilder.luau`, `tests/Fracture.spec.luau`; modify `src/shared/Voronoi/init.luau`

**Interfaces:**
- Consumes: all earlier modules
- Produces:
  - `type Cell = { siteIndex: number, site: Vector3, mesh: MeshData }`
  - `type Piece = { part: MeshPart, siteIndex: number, site: Vector3, center: Vector3 }` (`site`, `center`: source part-local studs)
  - `PartBuilder.build(source: MeshPart, cells: {Cell}, config): ({Piece}, () -> (), {string})` returning pieces, destroy function, warnings
  - `Voronoi.fracture(part: MeshPart, sites: {Vector3}, config: { [string]: any }?): Result` with `Result = { pieces: {Piece}, stats: Stats, destroy: (Result) -> () }`
  - `Stats = { readMs, cutMs, buildMs, totalMs, longestFrameMs, sourceTriangles, pieceTriangles, workers: number, warnings: {string} }`
  - `Voronoi.Points`, `Voronoi.Config`

- [ ] **Step 1: Write failing tests** (all with `workers = 0`):

| Test | Assert |
|---|---|
| `pieces` | 8 sites on Suzanne: at least 2 pieces; every `part.Parent == nil`; `part.Size` equals its cell's extent within 0.01 |
| `placement` | `part.CFrame` equals `source.CFrame * CFrame.new(center)` for a rotated, non-uniformly scaled clone |
| `source_untouched` | `Size`, `CFrame`, `Transparency`, `CanCollide`, `Parent` unchanged |
| `destroy` | after `result:destroy()`, assigning any piece's `Parent` errors; calling `destroy` again does not |
| `empty_sites` | `fracture(part, {})` errors |
| `sliver_skipped` | `PartBuilder.build` with one normal box cell and one box of half (1,1,1e-5): 1 piece, 1 warning |
| `properties` | `Color`, `Material`, `CollisionGroup` copied from source |

- [ ] **Step 2: Run, expect failure.**
- [ ] **Step 3: Implement `PartBuilder`.**
  - Skip cells with any extent < 0.001 or volume < 1e-6, with a warning. Error above the mesh limits.
  - Recentre positions on the bounds centre. Per piece: `CreateEditableMesh()`, `BatchAdd(Enum.MeshAttribute.Vertex | Normal | UV | Face, array)`, then `BatchSetFaceAttributes(faceIds, idTriples)` once for normal ids and once for UV ids (two arguments; the id type selects the attribute). With `capColor`, add two colours (white, `capColor`) and set colour ids the same way.
  - Content: `pcall` `CreateDataModelContentAsync(Content.fromObject(mesh))`; on `Success` use it and destroy the mesh, otherwise make a `FixedSize` copy with `CreateEditableMeshAsync`, destroy the original and keep the copy for `destroy`. A `nil` mesh is a budget failure.
  - Start every `CreateMeshPartAsync` together and wait for all, then on any failure destroy everything and error.
  - Copy `Color, Material, MaterialVariant, Transparency, Reflectance, CanCollide, CanTouch, CanQuery, Anchored, Massless, CustomPhysicalProperties, CollisionGroup, CastShadow, TextureContent, DoubleSided, EnableFluidForces, AudioCanCollide` and clone `SurfaceAppearance` children. Name `<source>_<n>`.
- [ ] **Step 4: Implement `fracture`:** read, cut serially (yield when elapsed exceeds `frameBudgetMs`), apply `splitIslands`, build, collect stats. `longestFrameMs` is the largest `Heartbeat` delta during the call.
- [ ] **Step 5: Run, expect** `FAIL 0`.
- [ ] **Step 6: Visual check.** In Studio, parent pieces of a 16-site fracture 30 studs aside, each pushed 15% out from the centre, with `capColor` red. `screen_capture`. Expect a recognisable exploded monkey, red cut faces only, no holes or inside-out faces. If vertex colour does not tint caps as intended, report it. Destroy the result.
- [ ] **Step 7: Commit** `feat: part builder and serial fracture`

### Task 8: Parallel scheduler

**Files:** Create `Scheduler.luau`, `Workers/WorkerMain.luau`, `Workers/ClientWorker.client.luau`, `Workers/ServerWorker.server.luau` (under `src/shared/Voronoi/`), `tests/Scheduler.spec.luau`; modify `init.luau`

**Interfaces:**
- Produces:
  - `Scheduler.run(source: MeshData, sites: {Vector3}, config): ({ [number]: MeshData }, { cpuMs: number, warnings: number })` (yields; keys are site indices; empty cells absent)
  - `Scheduler.shutdown()`; `Voronoi.shutdown()` calls it
  - Message `"VoronoiCut"`: `(jobId: number, job: SharedTable { mesh: buffer, sites: buffer, epsilon: number }, index: number, reply: BindableEvent)`
  - Reply: `reply:Fire(jobId, index, ok: boolean, packed: buffer?, cpuMs: number, warningsOrError)`

- [ ] **Step 1: Check the setting.** In a playtest, `Client` datamodel: `game:GetService("AssetService"):CreateEditableMesh()`. If it errors, stop and ask the owner to enable the setting.
- [ ] **Step 2: Write failing tests** (return `{}` when `RunService:IsRunning()` is false):

| Test | Assert |
|---|---|
| `matches_serial` | tunnel, 24 sites: packed cells identical for `workers = 0` and `8` |
| `concurrent` | two `run` calls on different fixtures in `task.spawn`: each matches its serial result |
| `worker_error` | source with a triangle index out of range: `run` errors; a following good `run` succeeds |
| `timeout` | pool whose actors' scripts are destroyed after start: `run` errors within 11 s |
| `no_leftovers` | after `shutdown()`, no `VoronoiWorkers` folder remains |

- [ ] **Step 3: Run in a playtest `Client` datamodel, expect failure.**
- [ ] **Step 4: Implement.**
  - Pool folder `VoronoiWorkers` under `LocalPlayer.PlayerScripts` (client) or `ServerScriptService` (server); one Actor per worker with a clone of the matching worker script, an `ObjectValue` "Core" pointing to `WorkerMain`, and a `Ready` attribute set after binding. Reuse the pool; rebuild if `workers` changes.
  - `WorkerMain` takes the actor as an argument from the worker script (`script:GetActor()` is nil inside a module stored outside the Actor), requires geometry modules serially, uses `BindToMessageParallel`, caches the unpacked job by `jobId`, wraps the cut in `pcall`, and `task.synchronize()`s before replying.
  - One cell per message, round robin. Each frame send at most `max(1, floor(frameBudgetMs * min(workers, 4) / averageCellMs))`; the first frame sends `min(workers, 4)`.
  - No reply for 10 s: destroy the pool and error.
- [ ] **Step 5: Use it from `fracture`** when `workers > 0` and `RunService:IsRunning()`. Otherwise cut serially (worker scripts do not run in Edit) and report `stats.workers = 0`. Add test `edit_fallback` in `Fracture.spec`: in Edit, `workers = 8` returns pieces with `stats.workers == 0`.
- [ ] **Step 6: Run all specs** in a playtest `Client`, then `Server` datamodel, then `Edit`. Expect `FAIL 0` in each, and no output errors.
- [ ] **Step 7: Commit** `feat: parallel cell scheduling`

### Task 9: Click demo

**Files:** Create `src/demo/server/init.server.luau`, `src/demo/client/init.client.luau`; modify `default.project.json` (`ServerScriptService.VoronoiDemo`, `StarterPlayer.StarterPlayerScripts.VoronoiDemo`)

**Interfaces:**
- Consumes: `Voronoi.Points.generate`, `Voronoi.fracture`
- Produces: `RemoteEvent` `ReplicatedStorage.VoronoiDemoShatter`, created by the server. Client → server `(part, worldPoint)`; server → all clients `(part, localPoint, seed)`

- [ ] **Step 1: Confirm the gate.** Task 1 Step 10 must have run and left the demo client-side. If it has not run, run it now.
- [ ] **Step 2: Server script.** Accept only a `MeshPart` under `workspace.Map.Items`, a `Vector3` within `part.Size.Magnitude` of it, and a part not locked. Lock for `resetAfter + 1` seconds, pick a seed, `FireAllClients`.
- [ ] **Step 3: Client script.**
  - Left click or tap: raycast from the camera; fire if it hits a target.
  - On event: return if `part` is `nil` or already shattered here. Sites: `distribution = "clustered"`, `focus` = hit world point, `focusRadius` = `part.Size.Magnitude / 2`.
  - `pcall` the fracture; on failure warn and leave the part alone. If the part left the DataModel meanwhile, destroy the result.
  - Save then set `Transparency = 1`, `CanCollide = false`, `CanQuery = false`. Parent pieces into `workspace.VoronoiDebris`, unanchored, and `ApplyImpulse((away.Unit + Vector3.yAxis * upwardBias) * force * AssemblyMass)`, `away` from the hit point.
  - After `resetAfter`: `result:destroy()` and restore the saved values.
- [ ] **Step 4: Playtest.** Click Suzanne with `user_mouse_input`. Within 1 s: pieces in `workspace.VoronoiDebris`, original hidden and non-colliding; `screen_capture` shows it breaking. After 7 s: debris empty, original restored. A second click during the break does nothing. Console has no errors from these scripts.
- [ ] **Step 5: Commit** `feat: click-to-shatter demo`

### Task 10: Measure, verify, document

**Files:** Modify `README.md`

- [ ] **Step 1: Timings**, playtest `Client`: Suzanne, 8, 32 and 64 sites, `workers` 0 and 8, five runs each after one warm-up. Record median `readMs`, `cutMs`, `buildMs`, `totalMs`, `longestFrameMs`. Compare 32 sites against 100 ms; if missed, name the costliest stage.
- [ ] **Step 2: 20 click-and-reset cycles** through the demo: in the playtest, fire `VoronoiDemoShatter` from the client, wait for the reset, repeat. Expect 20 breaks, no budget failure, empty `VoronoiDebris` at the end.
- [ ] **Step 3: Large mesh.** Subdivide Suzanne's `MeshData` twice (each triangle into 4, about 16,000 triangles) and time `Scheduler.run` with 32 sites, serial and parallel. Report whether cutting dominates. Do not build partitioning; bring the numbers to the owner.
- [ ] **Step 4: README:** how to run (`rojo serve`, the setting), API, config table, measured timings, known limits.
- [ ] **Step 5: Run all specs** (Edit and playtest), replay Task 9 Step 4, confirm `git status` lists only intended files.
- [ ] **Step 6: Commit** `docs: usage and measurements`
