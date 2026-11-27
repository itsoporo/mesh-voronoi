return function(lib)
	local function load()
		return require(lib), require(lib.Geometry.MeshData)
	end
	local Fixtures = require(game:GetService("ReplicatedStorage").VoronoiTests.Fixtures:Clone())
	local suzanne = workspace.Map.Items.default :: MeshPart

	local function transformed(): MeshPart
		local clone = suzanne:Clone()
		clone.Size = suzanne.Size * Vector3.new(2, 1, 0.5)
		clone.CFrame = CFrame.new(0, 20, 0) * CFrame.Angles(0.5, 1, 0.2)
		return clone
	end

	local function run(part: MeshPart, count: number, extra: { [string]: any }?)
		local Voronoi = load()
		local config = { workers = 0, splitIslands = false, count = count }
		for key, value in extra or {} do
			config[key] = value
		end
		local sites = Voronoi.Points.generate(part, config)
		return Voronoi.fracture(part, sites, config), sites
	end

	-- the cell geometry a piece should have been built from
	local function cellFor(part: MeshPart, sites, index: number)
		local _, MeshData = load()
		local mesh = require(lib.MeshReader).read(part, true)
		local cell = require(lib.Geometry.CellCutter).cut(mesh, sites, index)
		assert(cell, "piece for an empty cell")
		return MeshData.bounds(cell)
	end

	return {
		pieces = function()
			local result, sites = run(suzanne, 8)
			assert(#result.pieces >= 2, `pieces {#result.pieces}`)
			for _, piece in result.pieces do
				assert(piece.part:IsA("MeshPart") and piece.part.Parent == nil)
				assert(piece.site == sites[piece.siteIndex])
				local low, high = cellFor(suzanne, sites, piece.siteIndex)
				assert((piece.part.Size - (high - low)).Magnitude < 0.01, `size {piece.part.Size}, cell {high - low}`)
			end
			local stats = result.stats
			assert(stats.workers == 0 and stats.sourceTriangles >= 968 and stats.pieceTriangles > stats.sourceTriangles)
			assert(stats.readMs >= 0 and stats.cutMs > 0 and stats.buildMs > 0 and stats.totalMs >= stats.cutMs)
			result:destroy()
		end,
		placement = function()
			local source = transformed()
			local result, sites = run(source, 8)
			for _, piece in result.pieces do
				local low, high = cellFor(source, sites, piece.siteIndex)
				assert((piece.center - (low + high) / 2).Magnitude < 0.01, "center")
				local expected = source.CFrame * CFrame.new(piece.center)
				assert((piece.part.Position - expected.Position).Magnitude < 0.01, "position")
				assert(piece.part.CFrame.LookVector:FuzzyEq(expected.LookVector, 1e-4), "rotation")
				assert(piece.part.CFrame.UpVector:FuzzyEq(expected.UpVector, 1e-4), "rotation")
			end
			result:destroy()
		end,
		source_untouched = function()
			local size, cframe, transparency, collide, parent = suzanne.Size, suzanne.CFrame, suzanne.Transparency, suzanne.CanCollide, suzanne.Parent
			run(suzanne, 8).destroy()
			assert(suzanne.Size == size and suzanne.CFrame == cframe and suzanne.Transparency == transparency)
			assert(suzanne.CanCollide == collide and suzanne.Parent == parent)
		end,
		destroy = function()
			local result = run(suzanne, 4)
			local part = result.pieces[1].part
			result:destroy()
			assert(not pcall(function()
				part.Parent = workspace
			end), "piece survived destroy")
			result:destroy()
		end,
		empty_sites = function()
			local Voronoi = load()
			local ok, err = pcall(Voronoi.fracture, suzanne, {}, { workers = 0 })
			assert(not ok and string.find(err, "site"), tostring(err))
		end,
		sliver_skipped = function()
			local _, MeshData = load()
			local PartBuilder = require(lib.PartBuilder)
			local config = require(lib.Config).resolve()
			local cells = {
				{ siteIndex = 1, site = Vector3.zero, mesh = Fixtures.box(MeshData, Vector3.xAxis, Vector3.one) },
				{ siteIndex = 2, site = Vector3.zero, mesh = Fixtures.box(MeshData, Vector3.zero, Vector3.new(1, 1, 2e-4)) },
			}
			local pieces, destroy, warnings = PartBuilder.build(suzanne, cells, config)
			assert(#pieces == 1 and pieces[1].siteIndex == 1, `pieces {#pieces}`)
			assert(#warnings == 1, `warnings {#warnings}`)
			assert((pieces[1].center - Vector3.xAxis).Magnitude < 1e-4)
			assert((pieces[1].part.Size - Vector3.one * 2).Magnitude < 1e-3)
			destroy()
		end,
		over_limit_errors = function()
			local _, MeshData = load()
			local PartBuilder = require(lib.PartBuilder)
			local config = require(lib.Config).resolve()
			local big = Fixtures.box(MeshData, Vector3.zero, Vector3.one)
			while #big.caps <= 20000 do
				table.move(big.tris, 1, 36, #big.tris + 1)
				table.move(big.normals, 1, 36, #big.normals + 1)
				table.move(big.uvs, 1, 36, #big.uvs + 1)
				table.move(big.caps, 1, 12, #big.caps + 1)
			end
			local ok, err = pcall(PartBuilder.build, suzanne, { { siteIndex = 1, site = Vector3.zero, mesh = big } }, config)
			assert(not ok and string.find(err, "20000"), tostring(err))
		end,
		properties = function()
			local source = suzanne:Clone()
			source.Color = Color3.new(0, 1, 0)
			source.Material = Enum.Material.Neon
			source.CollisionGroup = "VoronoiTestGroup"
			source.CanQuery = false
			source.Massless = true
			source.Transparency = 0.25
			source.CustomPhysicalProperties = PhysicalProperties.new(2, 0.1, 0.2)
			local appearance = Instance.new("SurfaceAppearance")
			appearance.Parent = source
			local result = run(source, 4)
			for i, piece in result.pieces do
				local part = piece.part
				assert(part.Color == source.Color and part.Material == source.Material)
				assert(part.CollisionGroup == "VoronoiTestGroup" and part.CanQuery == false and part.Massless)
				assert(math.abs(part.Transparency - 0.25) < 1e-5 and part.CustomPhysicalProperties == source.CustomPhysicalProperties)
				assert(part:FindFirstChildOfClass("SurfaceAppearance"))
				assert(part.Name == `{source.Name}_{i}`)
				assert(part.CollisionFidelity == Enum.CollisionFidelity.Hull)
			end
			result:destroy()
		end,
		cap_color = function()
			local red = Color3.new(1, 0, 0)
			local result = run(suzanne, 4, { capColor = red })
			local editable = game:GetService("AssetService"):CreateEditableMeshAsync(result.pieces[1].part.MeshContent)
			local capped, plain = 0, 0
			for _, face in editable:GetFaces() do
				local color = editable:GetColor(editable:GetFaceColors(face)[1])
				if color == red then
					capped += 1
				elseif color == Color3.new(1, 1, 1) then
					plain += 1
				end
			end
			editable:Destroy()
			result:destroy()
			assert(capped > 0 and plain > 0, `capped {capped}, plain {plain}`)
		end,
		-- worker scripts only run in a playtest; elsewhere the cells are cut serially
		workers_fallback = function()
			local result = run(suzanne, 8, { workers = 8 })
			local expected = if game:GetService("RunService"):IsRunning() then 8 else 0
			assert(result.stats.workers == expected, `workers {result.stats.workers}`)
			assert(#result.pieces >= 2)
			result:destroy()
		end,
		parallel_matches_serial = function()
			local serial = run(suzanne, 12, { workers = 0 })
			local parallel = run(suzanne, 12, { workers = 8 })
			assert(#serial.pieces == #parallel.pieces)
			for i, piece in serial.pieces do
				local other = parallel.pieces[i]
				assert(piece.siteIndex == other.siteIndex and piece.center == other.center)
				assert(piece.part.Size == other.part.Size)
			end
			serial:destroy()
			parallel:destroy()
		end,
		preload = function()
			local Voronoi = load()
			Voronoi.preload(suzanne)
			local result = run(suzanne, 4)
			assert(result.stats.readMs < 20, `read still took {result.stats.readMs} ms`)
			result:destroy()
		end,
		-- the benchmark line reports seconds
		describe = function()
			local Voronoi = load()
			local line = Voronoi.describe("Monkey", 12, {
				readMs = 0, cutMs = 101.4, buildMs = 85, totalMs = 190.25, longestFrameMs = 30,
				sourceTriangles = 1002, pieceTriangles = 4000, workers = 8, warnings = {},
			})
			for _, expected in { "Monkey", "12 pieces", "0.190 s", "cut 0.101 s", "build 0.085 s", "longest frame 0.030 s", "8 workers" } do
				assert(string.find(line, expected, 1, true), `missing "{expected}" in: {line}`)
			end
		end,
		-- plain block parts need no mesh asset
		block_part = function()
			local Voronoi, MeshData = load()
			local block = Instance.new("Part")
			block.Size = Vector3.new(8, 6, 2)
			block.CFrame = CFrame.new(0, 40, 0) * CFrame.Angles(0, 0.5, 0)
			local sites = Voronoi.Points.generate(block, { count = 10 })
			local result = Voronoi.fracture(block, sites, { workers = 0 })
			local total = 0
			for _, piece in result.pieces do
				assert(piece.part:IsA("MeshPart"))
				total += piece.volume
			end
			assert(math.abs(total - 96) < 0.5, `volume {total}`)
			result:destroy()
		end,
		-- each piece carries its geometry, so it can be cut again without reading it back
		refracture_pieces = function()
			local Voronoi, MeshData = load()
			local first = run(suzanne, 4)
			local piece = first.pieces[1]
			assert(math.abs(MeshData.volume(piece.mesh) - piece.volume) < 1e-3)
			local low, high = MeshData.bounds(piece.mesh)
			assert(((low + high) / 2).Magnitude < 1e-3, "piece geometry must be centred on its part")
			assert((high - low - piece.part.Size).Magnitude < 0.01)
			local sites = Voronoi.Points.generate(piece.part, { count = 4 })
			local second = Voronoi.fracture(piece.part, sites, { workers = 0, splitIslands = false }, piece.mesh)
			local total = 0
			for _, small in second.pieces do
				total += small.volume
			end
			assert(math.abs(total - piece.volume) <= piece.volume * 0.005, `{total} vs {piece.volume}`)
			second:destroy()
			first:destroy()
		end,
		destroy_single_piece = function()
			local result = run(suzanne, 4)
			local kept, gone = result.pieces[1], result.pieces[2]
			local editable = gone.part.MeshContent.Object
			if editable then
				assert(#(editable :: EditableMesh):GetFaces() > 0)
			end
			gone.destroy()
			gone.destroy()
			assert(not pcall(function()
				gone.part.Parent = workspace
			end), "piece survived")
			if editable then
				-- a destroyed EditableMesh reads as empty
				assert(#(editable :: EditableMesh):GetFaces() == 0, "its editable mesh was not freed")
			end
			kept.part.Parent = workspace
			kept.part.Parent = nil
			result:destroy()
		end,
		-- other code holding most of a client's editable memory slows a fracture down
		-- but does not break it
		tight_budget = function()
			local RunService = game:GetService("RunService")
			if not (RunService:IsRunning() and RunService:IsClient()) then
				return
			end
			local AssetService = game:GetService("AssetService")
			local held = {}
			for _ = 1, 50 do
				local mesh = AssetService:CreateEditableMesh()
				if not mesh then
					break
				end
				table.insert(held, mesh)
			end
			assert(#held >= 2, "no budget to start with")
			-- leave room for one resizable mesh plus the small copies
			for _ = 1, 2 do
				(table.remove(held) :: EditableMesh):Destroy()
			end
			local ok, result = pcall(run, suzanne, 8)
			for _, mesh in held do
				mesh:Destroy()
			end
			assert(ok, tostring(result))
			assert(#result.pieces >= 2)
			result:destroy()
		end,
		-- opaque pieces hold no editable memory
		opaque_content = function()
			local result = run(suzanne, 6, { meshContent = "opaque" })
			assert(#result.pieces >= 2)
			for _, piece in result.pieces do
				assert(piece.part.MeshContent.SourceType == Enum.ContentSourceType.Opaque, piece.part.MeshContent.SourceType.Name)
			end
			result:destroy()
		end,
		-- with room for only the working mesh, pieces fall back to opaque content
		budget_exhausted_falls_back = function()
			local RunService = game:GetService("RunService")
			if not (RunService:IsRunning() and RunService:IsClient()) then
				return
			end
			require(lib.MeshReader).read(suzanne, true) -- reading needs room too
			local held = {}
			for _ = 1, 50 do
				local mesh = game:GetService("AssetService"):CreateEditableMesh()
				if not mesh then
					break
				end
				table.insert(held, mesh)
			end
			assert(#held >= 1, "no budget to start with")
			;(table.remove(held) :: EditableMesh):Destroy()
			local ok, result = pcall(run, suzanne, 8)
			for _, mesh in held do
				mesh:Destroy()
			end
			assert(ok, tostring(result))
			assert(#result.pieces >= 2)
			result:destroy()
		end,
		simplify_option = function()
			local plain = run(suzanne, 12)
			local simple = run(suzanne, 12, { simplify = true })
			assert(simple.stats.pieceTriangles < plain.stats.pieceTriangles, `{simple.stats.pieceTriangles} vs {plain.stats.pieceTriangles}`)
			plain:destroy()
			simple:destroy()
		end,
		split_islands = function()
			local Voronoi, MeshData = load()
			-- two separate boxes read as one cell become two pieces
			local PartBuilder = require(lib.PartBuilder)
			local corners = Fixtures.boxCorners(Vector3.zero, Vector3.one)
			for _, p in Fixtures.boxCorners(Vector3.new(5, 0, 0), Vector3.one) do
				table.insert(corners, p)
			end
			local cell = { siteIndex = 1, site = Vector3.zero, mesh = MeshData.fromSoup(corners) }
			assert(#Voronoi.splitCells({ cell }) == 2)
			assert(PartBuilder ~= nil)
		end,
	}
end
