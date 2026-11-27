return function(lib)
	local function load()
		return require(lib.Geometry.MeshData)
	end
	local Fixtures = require(game:GetService("ReplicatedStorage").VoronoiTests.Fixtures:Clone())

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-4
	end

	return {
		box_welds = function()
			local MeshData = load()
			local box = Fixtures.box(MeshData, Vector3.zero, Vector3.one)
			assert(#box.positions == 8, `positions {#box.positions}`)
			assert(#box.tris == 36 and #box.normals == 36 and #box.uvs == 36 and #box.caps == 12)
			assert(near(MeshData.volume(box), 8), `volume {MeshData.volume(box)}`)
			assert(MeshData.boundaryEdges(box) == 0)
			local low, high = MeshData.bounds(box)
			assert(low:FuzzyEq(-Vector3.one) and high:FuzzyEq(Vector3.one))
		end,
		weld_crosses_grid_cells = function()
			local MeshData = load()
			local a, b, c = Vector3.new(4e-5, 0, 0), Vector3.xAxis, Vector3.yAxis
			local m = MeshData.fromSoup({ a, b, c, a + Vector3.new(1e-6, 0, 0), c, -Vector3.xAxis })
			assert(#m.positions == 4, `positions {#m.positions}`)
		end,
		tunnel_closed = function()
			local MeshData = load()
			local tunnel = Fixtures.tunnel(MeshData)
			assert(near(MeshData.volume(tunnel), 24), `volume {MeshData.volume(tunnel)}`)
			assert(MeshData.boundaryEdges(tunnel) == 0)
		end,
		open_box = function()
			local MeshData = load()
			local open = Fixtures.openBox(MeshData)
			assert(MeshData.boundaryEdges(open) == 4)
			local closed, loops = MeshData.closeHoles(open)
			assert(loops == 1)
			assert(MeshData.boundaryEdges(closed) == 0)
			assert(near(MeshData.volume(closed), 8), `volume {MeshData.volume(closed)}`)
			assert(#closed.normals == #closed.tris and #closed.uvs == #closed.tris and #closed.caps * 3 == #closed.tris)
			assert(MeshData.boundaryEdges(open) == 4, "source was mutated")
		end,
		degenerate_dropped = function()
			local MeshData = load()
			local corners = Fixtures.boxCorners(Vector3.zero, Vector3.one)
			table.insert(corners, Vector3.zero)
			table.insert(corners, Vector3.zero)
			table.insert(corners, Vector3.one)
			assert(#MeshData.fromSoup(corners).caps == 12)
		end,
		chain_splits_pinched_loops = function()
			local MeshData = load()
			local loops, open = MeshData.chainLoops({ { 1, 2 }, { 2, 3 }, { 3, 1 }, { 1, 4 }, { 4, 5 }, { 5, 1 } })
			assert(#loops == 2 and #loops[1] == 3 and #loops[2] == 3 and open == 0)
		end,
		chain_reports_open_ends = function()
			local MeshData = load()
			local loops, open = MeshData.chainLoops({ { 1, 2 }, { 2, 3 }, { 3, 4 } })
			assert(#loops == 1 and #loops[1] == 4 and open == 1)
		end,
		islands = function()
			local MeshData = load()
			local corners = Fixtures.boxCorners(Vector3.zero, Vector3.one)
			for _, p in Fixtures.boxCorners(Vector3.new(5, 0, 0), Vector3.one) do
				table.insert(corners, p)
			end
			local parts = MeshData.splitIslands(MeshData.fromSoup(corners))
			assert(#parts == 2)
			for _, part in parts do
				assert(near(MeshData.volume(part), 8) and #part.positions == 8)
			end
		end,
		sized_box = function()
			local MeshData = load()
			local box = MeshData.box(Vector3.new(4, 2, 6))
			assert(near(MeshData.volume(box), 48) and MeshData.boundaryEdges(box) == 0)
			assert(#box.positions == 8 and #box.caps == 12)
			local low, high = MeshData.bounds(box)
			assert(low:FuzzyEq(Vector3.new(-2, -1, -3)) and high:FuzzyEq(Vector3.new(2, 1, 3)))
			for i = 1, #box.tris, 3 do
				local a, b, c = box.positions[box.tris[i]], box.positions[box.tris[i + 1]], box.positions[box.tris[i + 2]]
				local normal = (b - a):Cross(c - a).Unit
				assert(box.normals[i]:FuzzyEq(normal, 1e-4), "flat face normals expected")
				assert(normal:Dot(a + b + c) > 0, "faces must point outward")
			end
		end,
		-- flat faces chopped into slivers collapse to the few triangles they need
		simplify_flat_faces = function()
			local MeshData = load()
			local CellCutter = require(lib.Geometry.CellCutter)
			local box = MeshData.box(Vector3.new(8, 6, 2))
			local random = Random.new(3)
			local sites = {}
			for i = 1, 24 do
				sites[i] = Vector3.new(random:NextNumber(-4, 4), random:NextNumber(-3, 3), random:NextNumber(-0.6, 0.6))
			end
			local before, after, volume = 0, 0, 0
			for i in sites do
				local cell = CellCutter.cut(box, sites, i)
				if cell then
					local simple = MeshData.simplify(cell)
					before += #cell.caps
					after += #simple.caps
					volume += MeshData.volume(simple)
					assert(MeshData.boundaryEdges(simple) == 0, `cell {i}: open edges after simplifying`)
					assert(math.abs(MeshData.volume(simple) - MeshData.volume(cell)) < 1e-3, `cell {i}: volume changed`)
					assert(#simple.normals == #simple.tris and #simple.uvs == #simple.tris and #simple.caps * 3 == #simple.tris)
					for t = 1, #simple.caps do
						local f = (t - 1) * 3
						local a, b, c = simple.positions[simple.tris[f + 1]], simple.positions[simple.tris[f + 2]], simple.positions[simple.tris[f + 3]]
						assert((b - a):Cross(c - a):Dot(simple.normals[f + 1]) > -1e-4, `cell {i}: triangle faces backwards`)
					end
				end
			end
			assert(math.abs(volume - 96) < 0.5, `volume {volume}`)
			assert(after <= before * 0.7, `only went from {before} to {after} triangles`)
		end,
		simplify_keeps_curved_surfaces_and_cuts = function()
			local MeshData = load()
			local MeshReader = require(lib.MeshReader)
			local CellCutter = require(lib.Geometry.CellCutter)
			local suzanne = workspace.Map.Items.default :: MeshPart
			local source = MeshReader.read(suzanne, true)
			local sites = require(lib.Points).generate(suzanne, { count = 12 })
			for i in sites do
				local cell = CellCutter.cut(source, sites, i)
				if cell then
					local simple = MeshData.simplify(cell)
					assert(MeshData.boundaryEdges(simple) == 0, `cell {i}: open edges`)
					local volume = MeshData.volume(cell)
					assert(math.abs(MeshData.volume(simple) - volume) <= math.abs(volume) * 0.002 + 1e-3, `cell {i}: volume changed`)
					local caps, simpleCaps = 0, 0
					for _, c in cell.caps do caps += if c then 1 else 0 end
					for _, c in simple.caps do simpleCaps += if c then 1 else 0 end
					assert((caps > 0) == (simpleCaps > 0), "cut faces lost")
				end
			end
		end,
		roundtrip = function()
			local MeshData = load()
			local tunnel = Fixtures.tunnel(MeshData)
			tunnel.caps[3] = true
			tunnel.uvs[5] = Vector2.new(0.25, 0.75)
			local first = MeshData.pack(tunnel)
			local back = MeshData.unpack(first)
			assert(buffer.tostring(MeshData.pack(back)) == buffer.tostring(first))
			assert(back.caps[3] == true and back.caps[4] == false and back.uvs[5] == Vector2.new(0.25, 0.75))
		end,
	}
end
