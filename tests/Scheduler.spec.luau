-- Worker scripts only run in a playtest, so this spec is empty in Edit.
local RunService = game:GetService("RunService")

return function(lib)
	if not RunService:IsRunning() then
		return {}
	end
	local function load()
		return require(lib.Scheduler), require(lib.Geometry.MeshData), require(lib.Config)
	end
	local Fixtures = require(game:GetService("ReplicatedStorage").VoronoiTests.Fixtures:Clone())

	local function randomSites(seed: number, count: number, half: Vector3)
		local random = Random.new(seed)
		local sites = {}
		for i = 1, count do
			sites[i] = Vector3.new(
				random:NextNumber(-half.X, half.X),
				random:NextNumber(-half.Y, half.Y),
				random:NextNumber(-half.Z, half.Z)
			)
		end
		return sites
	end

	local function run(source, sites, workers: number)
		local Scheduler, _, Config = load()
		return Scheduler.run(source, sites, Config.resolve({ workers = workers }))
	end

	local function same(a, b, sites)
		local _, MeshData = load()
		local count = 0
		for i in sites do
			assert((a[i] == nil) == (b[i] == nil), `cell {i} empty in one run only`)
			if a[i] then
				count += 1
				assert(buffer.tostring(MeshData.pack(a[i])) == buffer.tostring(MeshData.pack(b[i])), `cell {i} differs`)
			end
		end
		assert(count > 1, "nothing to compare")
	end

	-- pool folders created by this copy of the library
	local function pools()
		local container = if RunService:IsServer()
			then game:GetService("ServerScriptService")
			else game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts")
		local found = {}
		for _, folder in container:GetChildren() do
			local core = folder.Name == "VoronoiWorkers" and folder:FindFirstChild("Core", true)
			if core and core.Value and core.Value:IsDescendantOf(lib) then
				table.insert(found, folder)
			end
		end
		return found
	end

	return {
		matches_serial = function()
			local _, MeshData = load()
			local source = Fixtures.tunnel(MeshData)
			local sites = randomSites(3, 24, Vector3.new(2, 2, 1))
			local serial = run(source, sites, 0)
			local parallel, stats = run(source, sites, 8)
			same(serial, parallel, sites)
			assert(stats.cpuMs > 0)
			local used = false
			for _, folder in pools() do
				used = used or #folder:GetChildren() == 8
			end
			assert(used, "no pool of 8 workers was used")
		end,
		-- cells running side by side do not lengthen a frame, so even a tiny budget
		-- must still send a full set of workers each frame
		budget_keeps_workers_busy = function()
			local _, MeshData = load()
			local Scheduler, _, Config = load()
			local source = Fixtures.tunnel(MeshData)
			local sites = randomSites(9, 32, Vector3.new(2, 2, 1))
			local config = Config.resolve({ workers = 8, frameBudgetMs = 0.001 })
			Scheduler.run(source, sites, config)
			local frames = 0
			local connection = RunService.Heartbeat:Connect(function()
				frames += 1
			end)
			Scheduler.run(source, sites, config)
			connection:Disconnect()
			assert(frames <= 32 / 4 + 4, `{frames} frames for 32 cells`)
		end,
		concurrent = function()
			local _, MeshData = load()
			local jobs = {
				{ source = Fixtures.tunnel(MeshData), sites = randomSites(4, 20, Vector3.new(2, 2, 1)) },
				{ source = Fixtures.box(MeshData, Vector3.zero, Vector3.one * 3), sites = randomSites(5, 28, Vector3.one * 3) },
			}
			local finished = 0
			for _, job in jobs do
				task.spawn(function()
					job.ok, job.result = pcall(run, job.source, job.sites, 4)
					finished += 1
				end)
			end
			local started = os.clock()
			while finished < 2 and os.clock() - started < 15 do
				task.wait()
			end
			for _, job in jobs do
				assert(job.ok, tostring(job.result))
				same(run(job.source, job.sites, 0), job.result, job.sites)
			end
		end,
		worker_error = function()
			local _, MeshData = load()
			local broken = Fixtures.tunnel(MeshData)
			broken.tris[1] = 999999
			local sites = randomSites(6, 8, Vector3.new(2, 2, 1))
			local ok, err = pcall(run, broken, sites, 4)
			assert(not ok and string.find(tostring(err), "Voronoi"), tostring(err))
			local good = Fixtures.tunnel(MeshData)
			same(run(good, sites, 0), run(good, sites, 4), sites)
		end,
		timeout = function()
			local _, MeshData = load()
			local source = Fixtures.tunnel(MeshData)
			local sites = randomSites(7, 8, Vector3.new(2, 2, 1))
			run(source, sites, 2)
			local silenced = 0
			for _, folder in pools() do
				if #folder:GetChildren() >= 2 then
					for _, descendant in folder:GetDescendants() do
						if descendant:IsA("BaseScript") and #folder:GetChildren() == 2 then
							descendant:Destroy()
							silenced += 1
						end
					end
				end
			end
			assert(silenced == 2, `silenced {silenced} workers`)
			local started = os.clock()
			local ok, err = pcall(run, source, sites, 2)
			assert(not ok and string.find(tostring(err), "respond"), tostring(err))
			assert(os.clock() - started < 11.5, "took too long to give up")
			same(run(source, sites, 0), run(source, sites, 2), sites)
		end,
		zz_no_leftovers = function()
			local Scheduler, MeshData = load()
			run(Fixtures.tunnel(MeshData), randomSites(8, 4, Vector3.one), 3)
			assert(#pools() > 0)
			Scheduler.shutdown()
			assert(#pools() == 0, "worker folders left behind")
		end,
	}
end
