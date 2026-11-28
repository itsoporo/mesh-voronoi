-- Cuts every cell, either on the calling thread or across a pool of Actors. Yields.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Budget = require(script.Parent.Budget)
local CellCutter = require(script.Parent.Geometry.CellCutter)
local Config = require(script.Parent.Config)
local MeshData = require(script.Parent.Geometry.MeshData)

type MeshData = MeshData.MeshData
export type Stats = { cpuMs: number, warnings: number }

local TOPIC = "VoronoiCut"
local TIMEOUT = 10 -- seconds without any worker replying
local EPSILON = 1e-5

type Pool = { folder: Folder, actors: { Actor }, nextActor: number }

-- one pool per worker count, so a different setting never pulls workers out from
-- under a fracture that is still running
local pools: { [number]: Pool } = {}
local nextJobId = 0

local Scheduler = {}

-- With `only`, a newer pool that has since replaced it is left alone.
local function destroyPool(workers: number, only: Pool?)
	local pool = pools[workers]
	if pool and (only == nil or pool == only) then
		pools[workers] = nil
		pool.folder:Destroy()
	end
end

local function createPool(workers: number): Pool
	local onServer = RunService:IsServer()
	local container: Instance = if onServer
		then ServerScriptService
		else (Players.LocalPlayer :: Player):WaitForChild("PlayerScripts")
	local scripts = script.Parent.Workers
	local template = if onServer then scripts.ServerWorker else scripts.ClientWorker

	local folder = Instance.new("Folder")
	folder.Name = "VoronoiWorkers"
	local actors = table.create(workers)
	for i = 1, workers do
		local actor = Instance.new("Actor")
		actor.Name = `Worker{i}`
		local worker = template:Clone()
		local core = Instance.new("ObjectValue")
		core.Name = "Core"
		core.Value = scripts.WorkerMain
		core.Parent = worker
		worker.Parent = actor
		actor.Parent = folder
		actors[i] = actor
	end
	folder.Parent = container
	return { folder = folder, actors = actors, nextActor = 1 }
end

local function getPool(workers: number): Pool
	local pool = pools[workers]
	if not pool or not pool.folder.Parent then
		destroyPool(workers)
		pool = createPool(workers)
		pools[workers] = pool
	end
	local ready = pool :: Pool
	local started = os.clock()
	for _, actor in ready.actors do
		while not actor:GetAttribute("Ready") do
			if not ready.folder.Parent then
				error("Voronoi: workers were shut down while starting", 0)
			end
			if os.clock() - started > TIMEOUT then
				destroyPool(workers, ready)
				error("Voronoi: workers did not respond while starting", 0)
			end
			task.wait()
		end
	end
	return ready
end

local function packSites(sites: { Vector3 }): buffer
	local data = buffer.create(#sites * 12)
	for i, site in sites do
		local offset = (i - 1) * 12
		buffer.writef32(data, offset, site.X)
		buffer.writef32(data, offset + 4, site.Y)
		buffer.writef32(data, offset + 8, site.Z)
	end
	return data
end

-- Cuts on this thread, yielding whenever the frame budget is spent.
local function runSerial(source: MeshData, sites: { Vector3 }, config: Config.Config): ({ [number]: MeshData }, Stats)
	local meshes: { [number]: MeshData } = {}
	local stats: Stats = { cpuMs = 0, warnings = 0 }
	for i in sites do
		Budget.checkpoint(config.frameBudgetMs)
		local started = os.clock()
		local mesh, cutStats = CellCutter.cut(source, sites, i, EPSILON)
		stats.cpuMs += (os.clock() - started) * 1000
		stats.warnings += cutStats.warnings
		meshes[i] = mesh :: any
	end
	return meshes, stats
end

local function runParallel(source: MeshData, sites: { Vector3 }, config: Config.Config): ({ [number]: MeshData }, Stats)
	local workers = config.workers
	local pool = getPool(workers)

	nextJobId += 1
	local jobId = nextJobId
	local job = SharedTable.new({
		mesh = MeshData.pack(source),
		sites = packSites(sites),
		epsilon = EPSILON,
	})

	local packed: { [number]: buffer } = {}
	local stats: Stats = { cpuMs = 0, warnings = 0 }
	local finished = 0
	local failure: string? = nil
	local lastReply = os.clock()

	local reply = Instance.new("BindableEvent")
	reply.Name = `Job{jobId}`
	reply.Parent = pool.folder
	local connection = reply.Event:Connect(function(id: number, index: number, ok: boolean, mesh: buffer?, cpuMs: number, detail: any)
		if id ~= jobId then
			return
		end
		lastReply = os.clock()
		finished += 1
		stats.cpuMs += cpuMs
		if ok then
			stats.warnings += detail
			if mesh then
				packed[index] = mesh
			end
		else
			failure = failure or `Voronoi: cell {index} failed: {detail}`
		end
	end)

	local sent = 0
	while finished < #sites and not failure do
		-- Cells that run side by side cost the frame no more than one cell, so always
		-- send a full wave; send more waves only if they fit the budget.
		local wave = math.min(workers, config.parallelism)
		local perFrame = wave
		if finished > 0 then
			local average = math.max(stats.cpuMs / finished, 0.01)
			perFrame = wave * math.max(1, math.floor(config.frameBudgetMs / average))
		end
		for _ = 1, math.min(perFrame, #sites - sent) do
			if not pool.folder.Parent then
				break
			end
			sent += 1
			local actor = pool.actors[pool.nextActor]
			pool.nextActor = pool.nextActor % #pool.actors + 1
			actor:SendMessage(TOPIC, jobId, job, sent, reply)
		end
		task.wait()
		if finished < #sites then
			if not pool.folder.Parent then
				failure = failure or "Voronoi: workers did not respond; they were shut down mid-job"
			elseif os.clock() - lastReply > TIMEOUT then
				destroyPool(workers, pool)
				failure = "Voronoi: workers did not respond in time"
			end
		end
	end
	connection:Disconnect()
	reply:Destroy()
	if failure then
		error(failure, 0)
	end

	local meshes: { [number]: MeshData } = {}
	for index, data in packed do
		meshes[index] = MeshData.unpack(data)
	end
	return meshes, stats
end

-- Meshes keyed by site index; empty cells are absent. `config.workers == 0` runs serially.
function Scheduler.run(source: MeshData, sites: { Vector3 }, config: Config.Config): ({ [number]: MeshData }, Stats)
	if config.workers == 0 then
		return runSerial(source, sites, config)
	end
	return runParallel(source, sites, config)
end

-- Starts the workers ahead of the first fracture.
function Scheduler.prepare(config: Config.Config)
	if config.workers > 0 then
		getPool(config.workers)
	end
end

function Scheduler.shutdown()
	for workers in pools do
		destroyPool(workers)
	end
end

return Scheduler
