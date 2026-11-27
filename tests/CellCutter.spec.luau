return function(lib)
	local function load()
		return require(lib.Geometry.CellCutter), require(lib.Geometry.MeshData)
	end
	local Fixtures = require(game:GetService("ReplicatedStorage").VoronoiTests.Fixtures:Clone())

	local function near(a: number, b: number, tolerance: number?): boolean
		return math.abs(a - b) <= (tolerance or 1e-3)
	end

	local function cells(source, sites)
		local CellCutter = load()
		local out = {}
		for i in sites do
			out[i] = (CellCutter.cut(source, sites, i))
		end
		return out
	end

	local function check(result, sites, volume: number)
		local _, MeshData = load()
		local total = 0
		for i in sites do
			local cell = result[i]
			if cell then
				assert(MeshData.boundaryEdges(cell) == 0, `cell {i} has {MeshData.boundaryEdges(cell)} open edges`)
				for _, p in cell.positions do
					assert(p.X == p.X and p.Y == p.Y and p.Z == p.Z, "NaN position")
				end
				assert(#cell.normals == #cell.tris and #cell.uvs == #cell.tris and #cell.caps * 3 == #cell.tris)
				total += MeshData.volume(cell)
			end
		end
		assert(near(total, volume, volume * 0.005), `cells sum to {total}, expected {volume}`)
	end

	local function eachVolume(result, sites, volume: number)
		local _, MeshData = load()
		for i in sites do
			assert(result[i], `cell {i} is empty`)
			local got = MeshData.volume(result[i])
			assert(near(got, volume), `cell {i} volume {got}, expected {volume}`)
		end
	end

	local function box(half: number)
		local _, MeshData = load()
		return Fixtures.box(MeshData, Vector3.zero, Vector3.one * half)
	end

	local function grid(values)
		local out = {}
		for _, x in values do
			for _, y in values do
				for _, z in values do
					table.insert(out, Vector3.new(x, y, z))
				end
			end
		end
		return out
	end

	return {
		halves = function()
			local _, MeshData = load()
			local sites = { Vector3.new(-0.5, 0, 0), Vector3.new(0.5, 0, 0) }
			local result = cells(box(1), sites)
			eachVolume(result, sites, 4)
			check(result, sites, 8)
			local _, high = MeshData.bounds(result[1])
			assert(near(high.X, 0), `max x {high.X}`)
			local caps = 0
			for t, isCap in result[1].caps do
				if isCap then
					caps += 1
					for k = 1, 3 do
						assert(result[1].normals[(t - 1) * 3 + k]:FuzzyEq(Vector3.xAxis, 1e-4), "cap normal")
					end
				end
			end
			assert(caps >= 2, "no cap")
		end,
		attributes_interpolated = function()
			local source = box(1)
			for i, index in source.tris do
				local p = source.positions[index]
				source.uvs[i] = Vector2.new(p.X, p.Y)
			end
			local result = cells(source, { Vector3.new(-0.5, 0, 0), Vector3.new(0.5, 0, 0) })
			local cell = result[1]
			for i, index in cell.tris do
				if not cell.caps[math.ceil(i / 3)] then
					local p = cell.positions[index]
					assert((cell.uvs[i] - Vector2.new(p.X, p.Y)).Magnitude < 1e-3, "uv not interpolated")
					assert(near(cell.normals[i].Magnitude, 1), "normal not unit")
				end
			end
		end,
		octants_on_edges = function()
			local sites = grid({ -0.5, 0.5 })
			local result = cells(box(1), sites)
			eachVolume(result, sites, 1)
			check(result, sites, 8)
		end,
		diagonal_through_vertices = function()
			local sites = { Vector3.new(0.5, 0.5, 0), Vector3.new(-0.5, -0.5, 0) }
			local result = cells(box(1), sites)
			eachVolume(result, sites, 4)
			check(result, sites, 8)
		end,
		buried = function()
			local _, MeshData = load()
			local sites = grid({ -2, 0, 2 })
			local result = cells(box(3), sites)
			check(result, sites, 216)
			local centre = table.find(sites, Vector3.zero) :: number
			assert(near(MeshData.volume(result[centre]), 8), `centre volume {MeshData.volume(result[centre])}`)
			for _, isCap in result[centre].caps do
				assert(isCap, "buried cell has a surface triangle")
			end
		end,
		tunnel_hole_cap = function()
			local _, MeshData = load()
			local sites = { Vector3.new(0, 0, -0.5), Vector3.new(0, 0, 0.5) }
			local result = cells(Fixtures.tunnel(MeshData), sites)
			eachVolume(result, sites, 12)
			check(result, sites, 24)
		end,
		random_conserves = function()
			local _, MeshData = load()
			for seed = 7, 16 do
				local random = Random.new(seed)
				local sites = {}
				for i = 1, 20 do
					sites[i] = Vector3.new(random:NextNumber(-2, 2), random:NextNumber(-2, 2), random:NextNumber(-1, 1))
				end
				check(cells(Fixtures.tunnel(MeshData), sites), sites, 24)
			end
		end,
		single_site = function()
			local sites = { Vector3.new(0.3, 0.2, 0.1) }
			eachVolume(cells(box(1), sites), sites, 8)
		end,
		duplicate_sites = function()
			local sites = { Vector3.zero, Vector3.zero, Vector3.new(0.5, 0, 0) }
			local result = cells(box(1), sites)
			assert(result[2] == nil, "duplicate not empty")
			check(result, sites, 8)
		end,
		far_site = function()
			local _, MeshData = load()
			local sites = { Vector3.zero, Vector3.new(100, 0, 0) }
			local result = cells(box(1), sites)
			assert(result[2] == nil)
			assert(near(MeshData.volume(result[1]), 8))
		end,
		early_exit = function()
			local CellCutter = load()
			local sites = grid({ -0.75, -0.25, 0.25, 0.75 })
			local source = box(1)
			local skipped = false
			for i in sites do
				local _, stats = CellCutter.cut(source, sites, i)
				skipped = skipped or stats.tested < #sites - 1
			end
			assert(skipped, "every cell tested every neighbour")
		end,
		-- a cut through existing vertices must reuse them, not stack new points on top
		no_stacked_vertices = function()
			local result = cells(box(1), grid({ -0.5, 0.5 }))
			for i, cell in result do
				for a = 1, #cell.positions do
					for b = a + 1, #cell.positions do
						local gap = (cell.positions[a] - cell.positions[b]).Magnitude
						assert(gap > 1e-4, `cell {i}: two vertices {gap} apart at {cell.positions[a]}`)
					end
				end
			end
		end,
		-- every outline must triangulate cleanly, with no cap triangle facing backwards
		clean_cuts = function()
			local CellCutter, MeshData = load()
			local problems, warnings, inverted = {}, 0, 0
			local function inspect(source, sites, label)
				for i in sites do
					local cell, stats = CellCutter.cut(source, sites, i)
					if stats.warnings > 0 then
						warnings += stats.warnings
						table.insert(problems, `{label} cell {i}`)
					end
					if cell then
						for t, isCap in cell.caps do
							if isCap then
								local first = (t - 1) * 3
								local a = cell.positions[cell.tris[first + 1]]
								local b = cell.positions[cell.tris[first + 2]]
								local c = cell.positions[cell.tris[first + 3]]
								if (b - a):Cross(c - a):Dot(cell.normals[first + 1]) < -1e-5 then
									inverted += 1
								end
							end
						end
					end
				end
			end
			inspect(box(1), grid({ -0.5, 0.5 }), "octants")
			inspect(box(3), grid({ -2, 0, 2 }), "buried")
			for seed = 1, 10 do
				local random = Random.new(seed)
				local sites = {}
				for i = 1, 16 do
					sites[i] = Vector3.new(random:NextNumber(-2, 2), random:NextNumber(-2, 2), random:NextNumber(-1, 1))
				end
				inspect(Fixtures.tunnel(MeshData), sites, `tunnel seed {seed}`)
			end
			assert(warnings == 0 and inverted == 0, `{warnings} warnings, {inverted} inverted cap triangles; first: {problems[1]}`)
		end,
		source_untouched = function()
			local _, MeshData = load()
			local source = Fixtures.tunnel(MeshData)
			local before = buffer.tostring(MeshData.pack(source))
			cells(source, { Vector3.new(0, 0, -0.5), Vector3.new(0, 0, 0.5) })
			assert(buffer.tostring(MeshData.pack(source)) == before)
		end,
	}
end
