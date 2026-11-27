return function(lib)
	local function load()
		return require(lib.Geometry.Triangulate)
	end

	local function points(list)
		local out = {}
		for i, p in list do
			out[i] = Vector3.new(p[1], p[2], 0)
		end
		return out
	end

	local function range(first, last)
		local out = {}
		for i = first, last do
			table.insert(out, i)
		end
		return out
	end

	-- total area; every triangle must face along the normal
	local function measure(pts, tris, normal)
		local area, used = 0, {}
		for i = 1, #tris, 3 do
			local a, b, c = pts[tris[i]], pts[tris[i + 1]], pts[tris[i + 2]]
			local term = (b - a):Cross(c - a):Dot(normal) / 2
			assert(term >= -1e-6, "inverted triangle")
			area += term
			used[tris[i]], used[tris[i + 1]], used[tris[i + 2]] = true, true, true
		end
		return area, used
	end

	-- every loop edge must appear exactly once, in the loop's direction
	local function assertLoopEdges(tris, loops)
		local directed = {}
		for i = 1, #tris, 3 do
			for k = 0, 2 do
				local key = tris[i + k] .. ">" .. tris[i + (k + 1) % 3]
				directed[key] = (directed[key] or 0) + 1
			end
		end
		for _, loop in loops do
			for i, a in loop do
				local b = loop[i % #loop + 1]
				assert(directed[a .. ">" .. b] == 1, "loop edge missing: " .. a .. ">" .. b)
			end
		end
	end

	local function run(list, loops, count, area, normal)
		local pts = points(list)
		local tris = load().loops(pts, loops, normal or Vector3.zAxis)
		assert(#tris == count * 3, `expected {count} triangles, got {#tris / 3}`)
		local got, used = measure(pts, tris, normal or Vector3.zAxis)
		assert(math.abs(got - area) < 1e-4, `expected area {area}, got {got}`)
		assertLoopEdges(tris, loops)
		return used
	end

	local square = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }

	return {
		square = function()
			run(square, { range(1, 4) }, 2, 1)
		end,
		concave = function()
			run({ { 0, 0 }, { 2, 0 }, { 2, 1 }, { 1, 1 }, { 1, 2 }, { 0, 2 } }, { range(1, 6) }, 4, 3)
		end,
		hole = function()
			run(
				{ { 0, 0 }, { 2, 0 }, { 2, 2 }, { 0, 2 }, { 0.5, 0.5 }, { 0.5, 1.5 }, { 1.5, 1.5 }, { 1.5, 0.5 } },
				{ range(1, 4), range(5, 8) },
				8,
				3
			)
		end,
		two_holes_listed_first = function()
			run({
				{ 0, 0 }, { 5, 0 }, { 5, 3 }, { 0, 3 },
				{ 1, 1 }, { 1, 2 }, { 2, 2 }, { 2, 1 },
				{ 3, 1 }, { 3, 2 }, { 4, 2 }, { 4, 1 },
			}, { range(5, 8), range(9, 12), range(1, 4) }, 14, 13)
		end,
		collinear = function()
			local used = run(
				{ { 0, 0 }, { 0.5, 0 }, { 1, 0 }, { 1, 0.5 }, { 1, 1 }, { 0.5, 1 }, { 0, 1 }, { 0, 0.5 } },
				{ range(1, 8) },
				6,
				1
			)
			for i = 1, 8 do
				assert(used[i], "vertex " .. i .. " dropped")
			end
		end,
		-- points along straight edges carry single-precision noise; none of them may
		-- become the tip of a zero-area triangle
		noisy_collinear = function()
			local Triangulate = load()
			local random = Random.new(5)
			for _ = 1, 200 do
				local pts = {}
				local corners = { Vector3.new(0, 0, 0), Vector3.new(2, 0, 0), Vector3.new(2, 2, 0), Vector3.new(0, 2, 0) }
				for side = 1, 4 do
					local from, to = corners[side], corners[side % 4 + 1]
					table.insert(pts, from)
					for step = 1, 3 do
						local noise = Vector3.new(random:NextNumber(-4e-7, 4e-7), random:NextNumber(-4e-7, 4e-7), 0)
						table.insert(pts, from:Lerp(to, step / 4) + noise)
					end
				end
				local loop = range(1, #pts)
				-- start the outline somewhere else each time
				for _ = 1, random:NextInteger(0, #pts - 1) do
					table.insert(loop, table.remove(loop, 1) :: number)
				end
				local tris, warnings = Triangulate.loops(pts, { loop }, Vector3.zAxis)
				assert(warnings == 0, `{warnings} warnings`)
				assert(#tris == (#pts - 2) * 3, `{#tris / 3} triangles`)
				for i = 1, #tris, 3 do
					local a, b, c = pts[tris[i]], pts[tris[i + 1]], pts[tris[i + 2]]
					local longest = math.max((b - a).Magnitude, (c - b).Magnitude, (a - c).Magnitude)
					local height = (b - a):Cross(c - a).Z / longest
					assert(height > 1e-4, `flat triangle, height {height}`)
				end
				assertLoopEdges(tris, { loop })
			end
		end,
		-- captured from a tunnel cut: a notch whose upper edge carries many points
		captured_notch = function()
			local list = {
				{ 0, 0 }, { 0.0134279, -0.6087160 }, { 0.0559312, -0.6231581 }, { 0.0649167, -0.6262112 },
				{ 0.2070539, -0.6745073 }, { 0.4646249, -0.7620260 }, { 0.5045443, -0.7510771 }, { 0.5628077, -0.7350969 },
				{ 0.5688695, -0.7334343 }, { 0.5706225, -0.7329534 }, { 0.5708349, -0.7328952 }, { 0.5716702, -0.7326661 },
				{ 0.5739760, -0.7320337 }, { 0.5918780, -0.7271236 }, { 0.6339822, -0.4884582 }, { 0.6757535, -0.2516798 },
				{ 0.6881498, -0.1814123 }, { 0.6927441, -0.1553700 }, { 0.7501070, 0.1697881 }, { 0.8684339, 0.8405180 },
				{ 0.8804283, 0.9085069 }, { 0.9009514, 1.0248417 }, { 0.1923459, 0.8603382 }, { 0.0555611, 0.8285835 },
				{ -0.0179018, 0.8115292 }, { -0.0175346, 0.7948791 }, { -0.0129144, 0.5854375 }, { -0.0035859, 0.1625548 },
				{ 0.0240950, 0.1625548 }, { 0.0243715, 0.1625548 }, { 0.0323771, 0.1625548 }, { 0.0324830, 0.1625548 },
				{ 0.0325718, 0.1625548 }, { 0.6238233, 0.1625548 }, { -0.0022241, 0.1008243 },
			}
			local pts = points(list)
			local loop = range(1, #pts)
			local tris, warnings = load().loops(pts, { loop }, Vector3.zAxis)
			assert(warnings == 0, `{warnings} warnings`)
			assert(#tris == (#pts - 2) * 3)
			measure(pts, tris, Vector3.zAxis)
			assertLoopEdges(tris, { loop })
		end,
		two_outers = function()
			local list = table.clone(square)
			for _, p in square do
				table.insert(list, { p[1] + 3, p[2] })
			end
			run(list, { range(1, 4), range(5, 8) }, 4, 2)
		end,
		nested_outer_filled_on_its_own = function()
			run(
				{ { 0, 0 }, { 3, 0 }, { 3, 3 }, { 0, 3 }, { 1, 1 }, { 2, 1 }, { 2, 2 }, { 1, 2 } },
				{ range(1, 4), range(5, 8) },
				4,
				10
			)
		end,
		tilted = function()
			local rotation = CFrame.Angles(0.7, 0.3, 0)
			local pts = {}
			for i, p in square do
				pts[i] = rotation:VectorToWorldSpace(Vector3.new(p[1], p[2], 0))
			end
			local normal = rotation:VectorToWorldSpace(Vector3.zAxis)
			local tris = load().loops(pts, { range(1, 4) }, normal)
			local area = measure(pts, tris, normal)
			assert(math.abs(area - 1) < 1e-4)
		end,
		degenerate = function()
			load().loops(points({ { 0, 0 }, { 1, 0 }, { 2, 0 } }), { range(1, 3) }, Vector3.zAxis)
		end,
		orphan_hole_keeps_edge_direction = function()
			local pts = points(square)
			local clockwise = { { 4, 3, 2, 1 } }
			local tris, warnings = load().loops(pts, clockwise, Vector3.zAxis)
			assert(#tris == 6 and warnings > 0)
			assertLoopEdges(tris, clockwise)
		end,
	}
end
