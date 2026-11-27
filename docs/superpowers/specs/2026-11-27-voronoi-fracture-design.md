# Voronoi mesh fracture: design

Date: 2026-11-27. Status: approved 2026-11-27.

## Intent

Break a MeshPart into Voronoi pieces at runtime, using Parallel Luau, fast enough
to use in a real game. An earlier version of this worked but was too slow to be
usable. The test case: click Suzanne and the monkey blows up.

## Goals

1. A **points module**: MeshPart + configuration in, list of sites out.
2. A **cells module**: MeshPart + sites in, table of pieces out.
3. A **click demo** that blows Suzanne up using both.
4. Cell maths spread across Actors.
5. Heavily configurable.
6. Correct for scaled (including non-uniform) and rotated parts.

### Speed target (proposed)

Suzanne (968 triangles), 32 sites, on the development machine: pieces ready within
100 ms of the request reaching the client, with no single frame spending more than
the configured budget on cell maths. If the two conflict, the frame budget wins and
the total time grows. Report per-stage timings and the longest frame. If the target
is missed, say so and show which stage costs the most.

## Non-goals

- Skinned meshes, bones, facial data, source vertex colours.
- Precomputing or saving fractures as assets.
- Repeated fracture of pieces is not tested, though the API should not prevent it.

## Anti-goals

- Freezing the game while fracturing.
- Hiding or destroying the original when the fracture failed.
- Visible gaps or holes between neighbouring pieces.

## Constraints

Checked on 2026-11-27 against Roblox docs and probes in this place.

- `EditableMesh` reads are safe in parallel. Writes, `CreateEditableMesh*` and
  `CreateMeshPartAsync` are serial only.
- Playtests currently fail with `EditableMesh is not accessible`. The owner must
  enable **Experience Settings > Security > Allow Mesh / Image APIs**.
- Parallel code that runs long still delays the frame.
- Per the docs, `Object` editable content set on the server does not replicate to
  clients.
- The client has a limited editable memory budget; creation can return `nil`.
- One `EditableMesh` holds at most 60,000 vertices or 20,000 triangles.
- Mesh assets must be owned by or shared with the experience owner.
- `StreamingEnabled` is on, so a part reference sent to a client can arrive `nil`.
- Test mesh: 505 welded vertices, scale 5.39, four open boundary loops around the
  eyes, one edge shared by four faces, two inconsistently wound edges.
- Server playtest probe: 64 units of stand-in maths took 194 ms on 1 Actor, 63 ms
  on 4 and 43 ms on 8. A `buffer` was accepted by `SendMessage` and `SharedTable`,
  and a new one came back through a `BindableEvent`.
- Edit-mode probe: 32 simple MeshParts took 531 ms created one by one and 16 ms
  started together.

### Checked during the build (playtest, 2026-11-27)

- Opaque content from `CreateDataModelContentAsync`, made on the server, renders on
  clients. Server `Object` content shows a placeholder.
- A client Actor can require a module from `ReplicatedStorage` and run it in parallel.
- A client held at most 8 dynamic `EditableMesh` objects; 400 small fixed-size copies
  were fine.
- Building 32 pieces of 200 triangles took about 25 ms on a client with fixed-size
  copies, 133 ms with opaque content, and 120-140 ms on the server (opaque).

## Approaches

| | Method | Trade-off |
|---|---|---|
| A | Classify vertices by cell, add edge and corner vertices, then close loops | Little repeated work. Cells share bookkeeping, and triangles or cells without vertices inside need special cases. |
| **B (chosen)** | Each cell cuts its own copy of the mesh by one bisector at a time, capping after each cut | Repeats some work. Cells are independent jobs; corners and buried cells need no special case. |

B was picked because independent cells map directly onto Actors.

## Design

### Pipeline

1. **Read** (serial, cached per mesh): load the `EditableMesh` once into flat
   buffers. Multiply positions by `Size / MeshSize` so everything is in
   part-local studs. Weld positions for topology; keep UVs and normals per
   triangle corner. Close open boundary loops.
2. **Sites** (points module).
3. **Cut** (parallel): one job per cell, one cell per message. Each frame, only as
   many cells are dispatched as fit `frameBudgetMs`. A single cell cannot be
   interrupted, so one very slow cell can exceed it.
4. **Build** (serial): one MeshPart per non-empty piece.

The worker is a script in the repo, cloned into a pool of Actors in a place where
it can run on the side that called the module.

### Cutting one cell

- Visit neighbours nearest first. Stop when half the distance to the next one
  exceeds the distance from the site to the farthest remaining vertex.
- Skip a plane without touching triangles if the cell's bounds are fully on the
  kept side. Compute each vertex distance once per plane.
- Clip triangles. Identify each new vertex by the edge it came from, so
  neighbouring triangles share it and cut segments chain exactly, without
  distance tolerances.
- Treat vertices on the plane as just inside it.
- Chain segments into loops, sort outer loops from holes, and ear-clip. Use every
  loop vertex so no gaps appear. Later planes cut earlier caps like any surface.
- Cap corners get their own normals and planar UVs, so cut edges stay sharp.
- A chain that cannot close is closed as well as possible and counted as a
  warning. It never raises an error.

### Building pieces

- Move each piece's bounding-box centre into its CFrame, so `Position` is the
  piece's real centre and `Size` matches its mesh.
- Add geometry with `BatchAdd`; start all `CreateMeshPartAsync` calls together.
- Copy physical and visual properties and any `SurfaceAppearance` from the source.
- Build with at most 4 dynamic meshes alive at once. On a client, link pieces to
  fixed-size copies (faster), which live until the result is destroyed. On the server,
  use opaque content, which replicates. On a budget failure, destroy partial output
  and raise an error.

### API

```lua
local sites = Voronoi.Points.generate(meshPart, config)        -- part-local studs
local result = Voronoi.fracture(meshPart, sites, config)       -- yields
-- result.pieces: { { part, siteIndex, site, center } }   parts are unparented
-- result.stats:  stage timings in ms, triangle counts, warnings
result:destroy()    -- removes the pieces and frees their editable meshes
```

The source part is not modified. Works on client or server. Client results are
visible to that player; server results are built from opaque content, so every
player sees them.

### Configuration

| Group | Options (defaults are the builder's to tune) |
|---|---|
| Points | `count`, `seed`, `distribution` (`uniform` or `clustered`), `focus`, `focusRadius`, `minSpacing`, `boundsPadding` |
| Geometry | `closeHoles`, `splitIslands` (separate disconnected chunks of one cell), `capColor` |
| Execution | `workers` (default 8; 0 runs serially), `frameBudgetMs` |
| Parts | `collisionFidelity` (default `Hull`), `renderFidelity` |
| Demo | `demoSide` (`client` default, or `server`), `force`, `upwardBias`, `resetAfter` |

The same seed, mesh and config give the same pieces.

### Partitioning for large meshes (second stage)

Cut the mesh once into a grid of closed chunks and cache them. Each cell then cuts
only the chunks it can overlap and discards the chunk walls from its output. This
adds seams and triangles, so build it only after stage one is measured on a
high-triangle mesh and cutting is the main cost. Keep it only if it is faster.
It would be an option, `partitions`, off by default.

### Click demo

- Client raycasts on click and asks the server to shatter a target.
- Targets are MeshParts in `workspace.Map.Items`. The server checks this,
  debounces, picks a seed and tells all clients the part, local hit point and seed.
- `focus` is given in world space, so the demo can pass the hit point directly.
- Each client fractures, then hides its copy of the original and turns off its
  `CanCollide` and `CanQuery`, spawns the pieces locally and pushes them away from
  the hit point. A client without the part (streamed out) does nothing.
- After `resetAfter` seconds the result is destroyed and the monkey returns.
- With `demoSide = "server"` (owner's choice to offer both, 2026-11-27), the server
  fractures instead: everyone sees the same pieces and physics, and the server hides,
  pushes and restores them. The click request is validated the same way.

### Layout

| Repo path | In Studio |
|---|---|
| `src/shared/Voronoi/` | `ReplicatedStorage.Voronoi` |
| `src/demo/server/` | `ServerScriptService.VoronoiDemo` |
| `src/demo/client/` | `StarterPlayer.StarterPlayerScripts.VoronoiDemo` |

The old slicing script stays in place but is set to `Disabled` through
`src/server/init.meta.json`, so it no longer destroys Suzanne on start. Check the
property in Studio after syncing. Its `Debug` part and the `Plane` are left alone.

## Verification

- Serial and parallel runs with one seed produce identical geometry.
- After hole closing, every piece has no boundary edges. Any exception is
  explained by a named source-mesh defect.
- Piece volumes add up to the source volume within 0.5%.
- A rotated, non-uniformly scaled copy passes the same checks.
- Playtest: clicking Suzanne shatters it, reset works, no errors in output.
- Timings and longest frame for 8, 32 and 64 sites, serial against parallel.
- 20 click-and-reset cycles in a row finish without a memory budget failure.

## Left to the builder

Module split inside `Voronoi`, buffer layouts, Actor pool and message design,
triangulation details, default values, and how pure geometry is tested in Studio.

## Additions requested during the build (2026-11-27)

Purpose: this destruction is going into the owner's tank game.

- **Benchmark print:** `printTimings` prints one line per fracture, in seconds.
- **Scene:** several Suzannes; the plane that cut through the test scene is removed.
- **Breakable walls** (`Voronoi.Breakable`): a block part in `workspace.Map.Walls` can
  be hit repeatedly. Each hit punches a hole: small chunks inside the hole radius fly
  along the shot, the rest stays anchored and can be hit again.
- **A wall must not decay into clutter.** It collapses completely after too many
  hits, too little material left, or too many fragments. Fragments below a minimum
  volume, and fragments no longer connected to the ground, fall off. Every removed
  piece frees its editable mesh, falling debris despawns, and the number of live
  debris pieces is capped across all walls.
- The wall rebuilds after a quiet period (can be disabled).
- **Demo:** clicking a wall fires a shell from the camera with a tracer, flash, dust
  and sparks. The cut is computed while the shell is in flight. Client and server
  modes both work; server mode is the one where all players agree on where the holes
  are, which gameplay collision needs.
