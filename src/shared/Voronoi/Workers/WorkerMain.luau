--!optimize 2
-- Runs inside a worker Actor. Each Actor is its own Luau VM, so everything here is
-- per worker.

return function(actor: Actor)
	local Geometry = script.Parent.Parent.Geometry
	local CellCutter = require(Geometry.CellCutter)
	local MeshData = require(Geometry.MeshData)

	local CACHED_JOBS = 4
	local cache: { [number]: any } = {}
	local order: { number } = {}

	local function load(jobId: number, job: SharedTable)
		local cached = cache[jobId]
		if cached then
			return cached
		end
		local packedSites = job.sites :: buffer
		local sites = table.create(buffer.len(packedSites) / 12)
		for offset = 0, buffer.len(packedSites) - 12, 12 do
			table.insert(
				sites,
				Vector3.new(
					buffer.readf32(packedSites, offset),
					buffer.readf32(packedSites, offset + 4),
					buffer.readf32(packedSites, offset + 8)
				)
			)
		end
		cached = { source = MeshData.unpack(job.mesh :: buffer), sites = sites, epsilon = job.epsilon :: number }
		cache[jobId] = cached
		table.insert(order, jobId)
		if #order > CACHED_JOBS then
			cache[table.remove(order, 1) :: number] = nil
		end
		return cached
	end

	actor:BindToMessageParallel("VoronoiCut", function(jobId: number, job: SharedTable, index: number, reply: BindableEvent)
		local started = os.clock()
		local ok, mesh, detail = pcall(function()
			local data = load(jobId, job)
			local cell, stats = CellCutter.cut(data.source, data.sites, index, data.epsilon)
			return if cell then MeshData.pack(cell) else nil, stats.warnings
		end)
		local cpuMs = (os.clock() - started) * 1000
		task.synchronize()
		if ok then
			reply:Fire(jobId, index, true, mesh, cpuMs, detail)
		else
			reply:Fire(jobId, index, false, nil, cpuMs, tostring(mesh))
		end
	end)
	actor:SetAttribute("Ready", true)
end
