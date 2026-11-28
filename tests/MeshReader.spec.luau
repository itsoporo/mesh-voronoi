return function(lib)
	local function load()
		return require(lib.MeshReader), require(lib.Geometry.MeshData)
	end

	local suzanne = workspace.Map.Items.default :: MeshPart

	local function extentMatches(part: MeshPart, mesh, MeshData)
		local low, high = MeshData.bounds(mesh)
		local extent = high - low
		assert((extent - part.Size).Magnitude < 0.01, `extent {extent}, size {part.Size}`)
	end

	local function transformed(): MeshPart
		local clone = suzanne:Clone()
		clone.Size = suzanne.Size * Vector3.new(2, 1, 0.5)
		clone.CFrame = CFrame.new(0, 20, 0) * CFrame.Angles(0.5, 1, 0.2)
		return clone
	end

	local function checkCells(part: MeshPart)
		local MeshReader, MeshData = load()
		local CellCutter = require(lib.Geometry.CellCutter)
		local Points = require(lib.Points)
		local source = MeshReader.read(part, true)
		local expected = MeshData.volume(source)
		local failures = {}
		for seed = 1, 5 do
			local sites = Points.generate(part, { count = 16, seed = seed })
			local total = 0
			for i in sites do
				local cell = CellCutter.cut(source, sites, i)
				if cell then
					local open = MeshData.boundaryEdges(cell)
					if open > 0 then
						table.insert(failures, `seed {seed} cell {i}: {open} open edges`)
					end
					total += MeshData.volume(cell)
				end
			end
			if math.abs(total - expected) > expected * 0.005 then
				table.insert(failures, `seed {seed}: cells sum to {total}, source {expected}`)
			end
		end
		assert(#failures == 0, table.concat(failures, "; "))
	end

	return {
		scaled_bounds = function()
			local MeshReader, MeshData = load()
			extentMatches(suzanne, MeshReader.read(suzanne, true), MeshData)
		end,
		closed = function()
			local MeshReader, MeshData = load()
			local mesh, info = MeshReader.read(suzanne, true)
			assert(info.holes == 4, `holes {info.holes}`)
			assert(MeshData.boundaryEdges(mesh) == 0, `open edges {MeshData.boundaryEdges(mesh)}`)
			assert(MeshData.volume(mesh) > 0)
		end,
		raw = function()
			local MeshReader, MeshData = load()
			local mesh, info = MeshReader.read(suzanne, false)
			assert(info.holes == 0)
			assert(MeshData.boundaryEdges(mesh) == 42, `open edges {MeshData.boundaryEdges(mesh)}`)
		end,
		non_uniform = function()
			local MeshReader, MeshData = load()
			local part = transformed()
			extentMatches(part, MeshReader.read(part, true), MeshData)
		end,
		cached = function()
			local MeshReader = load()
			assert(MeshReader.read(suzanne, true) == MeshReader.read(suzanne, true))
			assert(MeshReader.read(suzanne, true) ~= MeshReader.read(suzanne, false))
			local first = MeshReader.read(suzanne, true)
			MeshReader.clearCache()
			assert(MeshReader.read(suzanne, true) ~= first)
		end,
		one_read_per_asset = function()
			local MeshReader, MeshData = load()
			local part = transformed()
			local real, reads = MeshReader.createEditable, 0
			MeshReader.createEditable = function(content)
				reads += 1
				return real(content)
			end
			MeshReader.clearCache()
			MeshReader.read(suzanne, true)
			local scaled = MeshReader.read(part, true)
			MeshReader.read(part, false)
			MeshReader.createEditable = real
			assert(reads == 1, `{reads} reads of one asset`)
			extentMatches(part, scaled, MeshData)
			-- the same geometry as reading it at that size in the first place
			MeshReader.clearCache()
			local fresh = MeshReader.read(part, true)
			assert(#fresh.positions == #scaled.positions and #fresh.tris == #scaled.tris)
			assert(math.abs(MeshData.volume(fresh) - MeshData.volume(scaled)) < 1e-4)
		end,
		-- the same inputs must give the same bytes however long the session has run
		repeatable = function()
			local MeshReader, MeshData = load()
			local CellCutter = require(lib.Geometry.CellCutter)
			local sites = require(lib.Points).generate(suzanne, { count = 12 })
			local source = MeshReader.read(suzanne, true)
			for i in sites do
				local first: string? = nil
				for run = 1, 40 do
					local cell = CellCutter.cut(source, sites, i)
					if cell then
						local bytes = buffer.tostring(MeshData.pack(cell))
						first = first or bytes
						assert(bytes == first, `cell {i} changed on run {run}`)
					end
				end
				task.wait()
			end
		end,
		suzanne_cells = function()
			checkCells(suzanne)
		end,
		suzanne_cells_transformed = function()
			checkCells(transformed())
		end,
	}
end
