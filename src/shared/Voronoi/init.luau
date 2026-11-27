-- Voronoi fracture of a MeshPart.
--
--   local sites = Voronoi.Points.generate(meshPart, config)
--   local result = Voronoi.fracture(meshPart, sites, config)  -- yields
--   for _, piece in result.pieces do piece.part.Parent = workspace end
--   result:destroy()
--
-- Voronoi.preload(meshPart, config) reads the mesh and starts workers ahead of time.

local RunService = game:GetService("RunService")

local Budget = require(script.Budget)
local Config = require(script.Config)
local MeshData = require(script.Geometry.MeshData)
local MeshReader = require(script.MeshReader)
local PartBuilder = require(script.PartBuilder)
local Points = require(script.Points)
local Scheduler = require(script.Scheduler)

type MeshData = MeshData.MeshData
export type Config = Config.Config
export type Piece = PartBuilder.Piece
export type Stats = {
	readMs: number,
	cutMs: number,
	buildMs: number,
	totalMs: number,
	longestFrameMs: number,
	sourceTriangles: number,
	pieceTriangles: number,
	workers: number,
	warnings: { string },
}
export type Result = {
	pieces: { Piece },
	stats: Stats,
	destroy: (Result?) -> (),
}

local Voronoi = {}

Voronoi.Config = Config
Voronoi.Points = Points

local function milliseconds(since: number): number
	return (os.clock() - since) * 1000
end

-- The benchmark line printed when `printTimings` is on.
function Voronoi.describe(name: string, pieces: number, stats: Stats): string
	return string.format(
		"[Voronoi] %s -> %d pieces in %.3f s (read %.3f s, cut %.3f s, build %.3f s), longest frame %.3f s, %d workers",
		name,
		pieces,
		stats.totalMs / 1000,
		stats.readMs / 1000,
		stats.cutMs / 1000,
		stats.buildMs / 1000,
		stats.longestFrameMs / 1000,
		stats.workers
	)
end

local function resolve(overrides: { [string]: any }?): Config
	local config = Config.resolve(overrides)
	-- worker scripts only run while the game is running
	if not RunService:IsRunning() then
		config.workers = 0
	end
	return config
end

-- One cell per disconnected chunk.
function Voronoi.splitCells(cells: { PartBuilder.Cell }): { PartBuilder.Cell }
	local out = {}
	for _, cell in cells do
		for _, mesh in MeshData.splitIslands(cell.mesh) do
			table.insert(out, { siteIndex = cell.siteIndex, site = cell.site, mesh = mesh })
		end
	end
	return out
end

local function isBlock(part: BasePart): boolean
	return part:IsA("Part") and part.Shape == Enum.PartType.Block
end

local function run(part: BasePart, sites: { Vector3 }, config: Config, stats: Stats, mesh: MeshData?): ({ Piece }, () -> ())
	local mark = os.clock()
	local source: MeshData = if mesh
		then mesh
		elseif part:IsA("MeshPart") then MeshReader.read(part, config.closeHoles)
		else MeshData.box(part.Size)
	stats.readMs = milliseconds(mark)
	stats.sourceTriangles = #source.tris / 3

	mark = os.clock()
	local meshes, cutStats = Scheduler.run(source, sites, config)
	local cells: { PartBuilder.Cell } = {}
	for i, site in sites do
		local mesh = meshes[i]
		if mesh then
			table.insert(cells, { siteIndex = i, site = site, mesh = mesh })
		end
	end
	if config.simplify then
		for _, cell in cells do
			Budget.checkpoint(config.frameBudgetMs)
			cell.mesh = MeshData.simplify(cell.mesh)
		end
	end
	if config.splitIslands then
		cells = Voronoi.splitCells(cells)
	end
	stats.cutMs = milliseconds(mark)
	if cutStats.warnings > 0 then
		table.insert(stats.warnings, `{cutStats.warnings} cut outlines needed repair`)
	end
	for _, cell in cells do
		stats.pieceTriangles += #cell.mesh.tris / 3
	end

	mark = os.clock()
	local pieces, destroy, buildWarnings = PartBuilder.build(part, cells, config)
	stats.buildMs = milliseconds(mark)
	table.move(buildWarnings, 1, #buildWarnings, #stats.warnings + 1, stats.warnings)
	return pieces, destroy
end

-- Yields. Does the one-off work (reading the mesh, starting workers) so that the
-- first fracture of this part is as fast as later ones.
function Voronoi.preload(part: BasePart, overrides: { [string]: any }?)
	local config = resolve(overrides)
	if part:IsA("MeshPart") then
		MeshReader.read(part, config.closeHoles)
	end
	Scheduler.prepare(config)
end

-- Stops the worker pool.
function Voronoi.shutdown()
	Scheduler.shutdown()
end

-- Yields. The source part is not modified. Pieces come back unparented.
-- `part` is a MeshPart or a block Part. Pass `mesh` (part-local studs, such as a
-- piece's `mesh`) to skip reading the geometry.
function Voronoi.fracture(part: BasePart, sites: { Vector3 }, overrides: { [string]: any }?, mesh: MeshData?): Result
	assert(
		typeof(part) == "Instance" and part:IsA("BasePart") and (mesh ~= nil or part:IsA("MeshPart") or isBlock(part)),
		"Voronoi.fracture: part must be a MeshPart or a block Part"
	)
	assert(type(sites) == "table" and #sites > 0, "Voronoi.fracture: needs at least one site")
	local config = resolve(overrides)

	local stats: Stats = {
		readMs = 0,
		cutMs = 0,
		buildMs = 0,
		totalMs = 0,
		longestFrameMs = 0,
		sourceTriangles = 0,
		pieceTriangles = 0,
		workers = config.workers,
		warnings = {},
	}
	local frames = RunService.Heartbeat:Connect(function(delta)
		stats.longestFrameMs = math.max(stats.longestFrameMs, delta * 1000)
	end)
	local start = os.clock()
	local ok, pieces, destroy = pcall(run, part, sites, config, stats, mesh)
	stats.totalMs = milliseconds(start)
	frames:Disconnect()
	if not ok then
		error(pieces, 0)
	end
	if config.printTimings then
		print(Voronoi.describe(part.Name, #pieces, stats))
	end

	return {
		pieces = pieces,
		stats = stats,
		destroy = function()
			destroy()
		end,
	}
end

return Voronoi
