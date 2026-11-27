--!optimize 2
-- No --!native: compiled maths rounds differently from interpreted maths, and the same
-- inputs must always give the same pieces.
-- Cuts one Voronoi cell out of a closed mesh. Pure: safe to call in parallel.
--
-- The cell is the mesh clipped by the bisector plane of every neighbouring site that
-- can reach it, nearest first. Each cut is capped immediately, so the working mesh
-- stays closed and later planes cut earlier caps like any other surface.

local MeshData = require(script.Parent.MeshData)
local Triangulate = require(script.Parent.Triangulate)

type MeshData = MeshData.MeshData
export type Stats = { tested: number, cut: number, warnings: number }

local DEFAULT_EPSILON = 1e-5

local CellCutter = {}

-- Keeps the side of the plane where (p - point):Dot(normal) <= 0.
-- Returns the clipped mesh, or `unchanged = true` if the plane misses it.
-- A nil mesh with unchanged = false means nothing is left.
local function clip(m: MeshData, point: Vector3, normal: Vector3, epsilon: number, stats: Stats): (MeshData?, boolean)
	local source = m.positions
	local distance = table.create(#source, 0)
	local anyInside, anyOutside = false, false
	for i, p in source do
		local d = (p - point):Dot(normal)
		if math.abs(d) <= epsilon then
			d = 0 -- on the plane: kept, and used as its own cut point
		end
		distance[i] = d
		if d > 0 then
			anyOutside = true
		elseif d < 0 then
			anyInside = true
		end
	end
	if not anyOutside then
		return nil, true
	end
	if not anyInside then
		return nil, false
	end

	local positions = table.clone(source)
	local tris, normals, uvs, caps = {}, {}, {}, {}
	local oldTris, oldNormals, oldUvs, oldCaps = m.tris, m.normals, m.uvs, m.caps
	local edgeVertex: { [number]: number } = {}
	local segments: { { number } } = {}

	-- cut points that land on each other (or on a vertex already on the plane) merge,
	-- so thin triangles cannot pile up stacked vertices over successive cuts
	local welder = MeshData.welder(epsilon)
	for i, d in distance do
		if d == 0 then
			welder.register(source[i], i)
		end
	end

	-- polygon of the current triangle after clipping (at most 4 corners)
	local polyIndex, polyNormal, polyUv = table.create(4, 0), table.create(4, Vector3.zero), table.create(4, Vector2.zero)

	local count = 0

	-- on-plane vertices are reached both as corners and as cut points: add them once
	local function push(vertex: number, normal: Vector3, uv: Vector2)
		if count > 0 and polyIndex[count] == vertex then
			return
		end
		count += 1
		polyIndex[count], polyNormal[count], polyUv[count] = vertex, normal, uv
	end

	local function emit(a: number, b: number, c: number)
		for _, k in { a, b, c } do
			table.insert(tris, polyIndex[k])
			table.insert(normals, polyNormal[k])
			table.insert(uvs, polyUv[k])
		end
	end

	for first = 1, #oldTris, 3 do
		local cap = oldCaps[(first + 2) / 3]
		local a, b, c = oldTris[first], oldTris[first + 1], oldTris[first + 2]
		local inA, inB, inC = distance[a] <= 0, distance[b] <= 0, distance[c] <= 0

		if inA and inB and inC then
			for k = 0, 2 do
				table.insert(tris, oldTris[first + k])
				table.insert(normals, oldNormals[first + k])
				table.insert(uvs, oldUvs[first + k])
			end
			table.insert(caps, cap)
		elseif inA or inB or inC then
			count = 0
			local entry, exit = 0, 0
			for k = 0, 2 do
				local corner, nextCorner = first + k, first + (k + 1) % 3
				local i, j = oldTris[corner], oldTris[nextCorner]
				local inI, inJ = distance[i] <= 0, distance[j] <= 0
				if inI then
					push(i, oldNormals[corner], oldUvs[corner])
				end
				if inI ~= inJ then
					-- interpolate from the inside end, so both triangles sharing this edge
					-- compute the same point
					local insideIndex, outsideIndex = i, j
					local insideCorner, outsideCorner = corner, nextCorner
					if not inI then
						insideIndex, outsideIndex = j, i
						insideCorner, outsideCorner = nextCorner, corner
					end
					local vertex: number
					if distance[insideIndex] == 0 then
						vertex = insideIndex
						push(vertex, oldNormals[insideCorner], oldUvs[insideCorner])
					else
						local t = distance[insideIndex] / (distance[insideIndex] - distance[outsideIndex])
						local key = MeshData.edgeKey(i, j)
						local existing = edgeVertex[key]
						if not existing then
							local p = source[insideIndex]:Lerp(source[outsideIndex], t)
							existing = welder.find(p)
							if not existing then
								table.insert(positions, p)
								existing = #positions
								welder.register(p, existing :: number)
							end
							edgeVertex[key] = existing :: number
						end
						vertex = existing :: number
						local blended = oldNormals[insideCorner]:Lerp(oldNormals[outsideCorner], t)
						push(
							vertex,
							if blended.Magnitude > 1e-6 then blended.Unit else oldNormals[insideCorner],
							oldUvs[insideCorner]:Lerp(oldUvs[outsideCorner], t)
						)
					end
					if inI then
						exit = vertex
					else
						entry = vertex
					end
				end
			end
			if count > 1 and polyIndex[count] == polyIndex[1] then
				count -= 1
			end
			for k = 2, count - 1 do
				emit(1, k, k + 1)
				table.insert(caps, cap)
			end
			-- the surface runs exit -> entry along the plane, so the cap runs back
			if entry ~= exit then
				table.insert(segments, { entry, exit })
			end
		end
	end

	local loops, open = MeshData.chainLoops(segments)
	stats.warnings += open
	if #loops > 0 then
		local triangles, warnings = Triangulate.loops(positions, loops, normal)
		stats.warnings += warnings
		local helper = if math.abs(normal.X) < 0.9 then Vector3.xAxis else Vector3.yAxis
		local u = helper:Cross(normal).Unit
		local v = normal:Cross(u)
		for i = 1, #triangles, 3 do
			for k = 0, 2 do
				local index = triangles[i + k]
				local offset = positions[index] - point
				table.insert(tris, index)
				table.insert(normals, normal)
				table.insert(uvs, Vector2.new(offset:Dot(u), offset:Dot(v)))
			end
			table.insert(caps, true)
		end
	end

	if #tris == 0 then
		return nil, false
	end
	return MeshData.compact({ positions = positions, tris = tris, normals = normals, uvs = uvs, caps = caps }), false
end

local function farthest(m: MeshData, from: Vector3): number
	local best = 0
	for _, p in m.positions do
		best = math.max(best, (p - from).Magnitude)
	end
	return best
end

function CellCutter.cut(source: MeshData, sites: { Vector3 }, index: number, epsilon: number?): (MeshData?, Stats)
	local tolerance = epsilon or DEFAULT_EPSILON
	local stats: Stats = { tested = 0, cut = 0, warnings = 0 }
	local site = sites[index]

	local neighbours: { number } = {}
	local distances: { [number]: number } = {}
	for i, other in sites do
		if i ~= index then
			local d = (other - site).Magnitude
			if d <= tolerance then
				if i < index then
					return nil, stats -- the earlier of two identical sites owns the cell
				end
			else
				distances[i] = d
				table.insert(neighbours, i)
			end
		end
	end
	table.sort(neighbours, function(a, b)
		if distances[a] ~= distances[b] then
			return distances[a] < distances[b]
		end
		return a < b
	end)

	if #source.tris == 0 then
		return nil, stats
	end
	local current = source
	local radius = farthest(current, site)
	local low, high = MeshData.bounds(current)

	for _, i in neighbours do
		local d = distances[i]
		if d / 2 >= radius then
			break -- this bisector and every farther one miss the cell
		end
		stats.tested += 1
		local normal = (sites[i] - site) / d
		local point = (sites[i] + site) / 2
		local corner = Vector3.new(
			if normal.X >= 0 then high.X else low.X,
			if normal.Y >= 0 then high.Y else low.Y,
			if normal.Z >= 0 then high.Z else low.Z
		)
		if (corner - point):Dot(normal) <= tolerance then
			continue
		end
		local clipped, unchanged = clip(current, point, normal, tolerance, stats)
		if unchanged then
			continue
		end
		if not clipped then
			return nil, stats
		end
		current = clipped
		stats.cut += 1
		radius = farthest(current, site)
		low, high = MeshData.bounds(current)
	end

	if current == source then
		current = table.clone(source)
	end
	return current, stats
end

return CellCutter
