# mesh-voronoi

Voronoi destruction for Roblox, cut in Parallel Luau: shatter any mesh, or punch
holes in walls with shells.

## Run it

1. In the experience, enable **Experience Settings > Security > Allow Mesh / Image
   APIs**. Mesh assets must be owned by or shared with the experience owner.
2. `rokit install`, then `rojo serve` from this folder and connect the Rojo plugin.
   The project only syncs into the demo place (`servePlaceIds`); change that id to use
   it elsewhere. After adding a new service to the project file, disconnect and
   connect again.
3. Play. Click a Suzanne to blow it up; click a wall to shell it.

The scene itself (Suzannes in `workspace.Map.Items`, block parts in
`workspace.Map.Walls`) is saved in the place, not in this repo.

## Shattering a mesh

```lua
local Voronoi = require(game.ReplicatedStorage.Voronoi)

Voronoi.preload(part)                                   -- optional: read mesh, start workers
local config = { count = 32, seed = 7 }
local sites = Voronoi.Points.generate(part, config)     -- part-local studs
local result = Voronoi.fracture(part, sites, config)    -- yields

for _, piece in result.pieces do                        -- unparented MeshParts
	piece.part.Anchored = false
	piece.part.Parent = workspace
end
-- later
result:destroy()                                        -- frees the pieces and their memory
```

- `part` is a MeshPart or a block Part, and is never modified.
- A piece is `{ part, siteIndex, site, center, mesh, volume, destroy }`. Pass
  `piece.mesh` as the fourth argument of `fracture` to cut a piece again.
- Call it on a client for effects only that player sees. Call it on the server for
  pieces everyone shares.
- `Voronoi.Points.sample(size, localFocus, config)` makes sites without a part. Any
  list of Vector3 in part-local studs works as sites.

## Breakable walls

```lua
local Breakable = require(game.ReplicatedStorage.Voronoi.Breakable)

local wall = Breakable.get(wallPart, { holeRadius = 3, maxHits = 8 })
local report = wall:hit(hitPosition, shellDirection, seed)   -- yields
-- report: { flying, dropped, standing, collapsed, remaining, targets, seconds } or nil
Breakable.rootOf(someFragment)                               -- the wall a fragment came from
wall:collapse()                                              -- bring it down now
wall:reset()
```

Each hit punches a hole; chunks inside it fly along the shot and the rest can be hit
again. A damaged wall cleans up after itself: small slivers and pieces no longer
connected to the ground fall off, debris despawns and is capped across all walls, and
the whole wall collapses after too much damage. `hit` returns `nil` when the shot goes
through an existing hole or the wall has collapsed. Support is measured along the part's
axis closest to world up, so a wall may be turned any way, as long as it stands roughly
upright or lies flat.

For walls built of several parts one behind the other, give `hit` the same sites for each
as its sixth argument, `{ sites, flies }` (see `Breakable.holeSites`); sites all in one
plane cut straight through every layer. Set `attach` for a wall that is part of something
that can move or fall: its fragments are then welded to the part instead of anchored.

Destroying the wall part, or taking it out of `workspace`, removes its fragments and
debris too; call `Breakable.get` again for a new part. If an error interrupts a hit,
the wall is rebuilt rather than left half broken.

For a tank game, call `hit` on the **server** so every player agrees on where the
holes are. Pass the shell's arrival time (`os.clock() + flightTime`) as the fourth
argument to open the hole exactly on impact.

| Setting | Default | Meaning |
|---|---|---|
| `holeRadius` | 3 | studs; real holes come out slightly larger. `hit`'s fifth argument overrides it per shot |
| `attach` | false | weld fragments to the wall part instead of anchoring them |
| `rings` | `false` | custom hole layout: `{ { distance, count, flies? }, ... }`, distances in hole radii |
| `maxHits` | 8 | the wall collapses on this hit |
| `collapseBelow` | 0.45 | ...or when this fraction of material is left |
| `maxFragments` | 90 | ...or above this many standing parts |
| `minFragmentVolume` | 0.6 | cubic studs; smaller fragments fall off |
| `debrisLifetime` | 4 | seconds |
| `maxDebris` | 120 | loose pieces alive across all walls |
| `rebuildAfter` | 20 | seconds without a hit; `false` stays broken |
| `launchSpeed`, `spread` | 70, 25 | debris speed along and away from the shot |
| `debrisCollides` | true | |
| `fracture` | `workers = 0, frameBudgetMs = 10, simplify = true, meshContent = "opaque"` | Voronoi options for every cut; yours are merged over these |

The demo's values are in `src/demo/shared/WallSettings.luau`.

## Configuration

Unknown keys and invalid values raise an error.

| Key | Default | Meaning |
|---|---|---|
| `count` | 32 | sites to generate (empty cells produce no piece) |
| `seed` | 1 | same seed, mesh and options give the same pieces |
| `distribution` | `"uniform"` | or `"clustered"` around `focus` |
| `focus`, `focusRadius` | nil | world position; radius defaults to a quarter diagonal |
| `minSpacing` | 0 | studs between sites |
| `boundsPadding` | 0 | studs added to each face of the box; negative shrinks |
| `closeHoles` | true | cap open mesh edges before cutting |
| `splitIslands` | true | separate disconnected chunks of one cell |
| `capColor` | nil | tint of cut faces |
| `simplify` | false | merge flat faces into fewer triangles |
| `workers` | 8 | Actors; 0 cuts on the calling thread |
| `frameBudgetMs` | 4 | main-thread time per frame, and how fast cells are dispatched |
| `parallelism` | 8 | cells expected to run side by side; lower for weak devices |
| `meshContent` | `"auto"` | `"opaque"` pieces use no editable memory but build slower |
| `collisionFidelity` | Hull | |
| `renderFidelity` | Automatic | |
| `printTimings` | false | print a benchmark line in seconds |
| `demoSide`, `force`, `upwardBias`, `resetAfter` | | click demo only |

## Measured performance

Roblox Studio playtest on a 16-thread desktop, 2026-11-27. Treat these as indicative:
they vary between sessions, and a published game was not measured.

**Suzanne (about 1,000 triangles), evenly spread sites**, medians of five, before the
frame budget was shared between concurrent work:

| Sites | One thread, 4 ms budget | 8 workers, 4 ms budget | 8 workers, no budget |
|---|---|---|---|
| 8 | 117 ms | 50 ms | 38 ms |
| 32 | 416 ms | 200 ms | 107 ms |
| 64 | 884 ms | 333 ms | 183 ms |

Enforcing the shared budget made building slower: the same 32-site case measured
about 270 to 450 ms at a 4 ms budget.

**The click demo** clusters sites around the click, which costs about twice as much
as spreading them evenly. One real click measured 0.19 s to fracture one Suzanne
(258 ms from click to broken, worst frame 51 ms) in client mode and 0.30 s in server
mode; scripted runs ranged from 0.3 to 0.4 s. Four breaking at once took 0.9 to
1.3 s, with worst frames of 120 to 210 ms.

**Walls** (client, 43 shots until collapse): median 204 ms per hit with opaque pieces
(worst frame 36 ms), 127 ms with `"auto"` (worst frame 25 ms). Server mode reached
the client in 250 to 350 ms.

**16,000 triangles, 32 sites:** cutting took 1,154 ms on one thread and 410 ms on 8
workers (554 ms at a 4 ms budget); building took 146 to 395 ms.

## Known limits

- The 100 ms target for 32 sites on Suzanne was not met. The best measurement was
  107 ms, with no frame budget and evenly spread sites.
- One cell cannot be split across frames. Large cells (up to about 70 ms each with
  clustered sites on Suzanne) set the worst frame.
- Fractures running at the same time each send a full wave of cells to the workers.
- On large meshes cutting is the main cost. Partitioning the mesh into chunks is the
  planned next step and is not built.
- Client editable memory is limited. Pieces fall back to opaque content when it runs
  out; a mesh cannot be read or built if none is left at all.
- Skinned meshes and source vertex colours are not carried over.

## Tests

Specs live in `tests/` and run inside Studio from the command bar:

```lua
print(require(game.ReplicatedStorage.VoronoiTests.Runner:Clone())())          -- all
print(require(game.ReplicatedStorage.VoronoiTests.Runner:Clone())("Breakable")) -- one
```

Run them in Edit mode, and in a playtest on both client and server: the worker and
memory-budget tests only do anything while the game runs. A playtest is a snapshot,
so restart it after editing files.

`src/server/` holds the original plane-slicing script, kept but disabled.
