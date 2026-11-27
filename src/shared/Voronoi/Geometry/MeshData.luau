--!optimize 2
-- Plain-data triangle mesh and the operations on it. Pure: safe to call in parallel.

local Triangulate = require(script.Parent.Triangulate)

export type MeshData = {
	positions: { Vector3 }, -- welded
	tris: { number }, -- 3 position indices per triangle
	normals: { Vector3 }, -- one per corner, parallel to tris
	uvs: { Vector2 }, -- one per corner, parallel to tris
	caps: { boolean }, -- one per triangle: true on cut faces
}

local DEFAULT_WELD = 1e-5
local EDGE_STRIDE = 2 ^ 26

local MeshData = {}

local function edgeKey(a: number, b: number): number
	if a > b then
		a, b = b, a
	end
	return a * EDGE_STRIDE + b
end

MeshData.edgeKey = edgeKey

local function new(): MeshData
	return { positions = {}, tris = {}, normals = {}, uvs = {}, caps = {} }
end

-- A spatial hash for merging nearby points. `find` returns the index registered
-- within `weld` of p, if any.
function MeshData.welder(weld: number)
	local cell = weld * 4
	-- keyed by integer grid coordinates; vectors hash by value and allocate nothing
	local buckets: { [Vector3]: { { index: number, position: Vector3 } } } = {}

	-- grid cells on one axis that can hold a point within `weld` of x
	local function span(x: number): (number, number)
		return math.floor((x - weld) / cell), math.floor((x + weld) / cell)
	end

	local welder = {}

	function welder.find(p: Vector3): number?
		local x0, x1 = span(p.X)
		local y0, y1 = span(p.Y)
		local z0, z1 = span(p.Z)
		for x = x0, x1 do
			for y = y0, y1 do
				for z = z0, z1 do
					local bucket = buckets[Vector3.new(x, y, z)]
					if bucket then
						for _, entry in bucket do
							if (entry.position - p).Magnitude <= weld then
								return entry.index
							end
						end
					end
				end
			end
		end
		return nil
	end

	function welder.register(p: Vector3, index: number)
		local key = Vector3.new(math.floor(p.X / cell), math.floor(p.Y / cell), math.floor(p.Z / cell))
		local bucket = buckets[key]
		if not bucket then
			bucket = {}
			buckets[key] = bucket
		end
		table.insert(bucket, { index = index, position = p })
	end

	return welder
end

local function weldPositions(corners: { Vector3 }, weld: number): ({ Vector3 }, { number })
	local welder = MeshData.welder(weld)
	local positions: { Vector3 } = {}
	local indices = table.create(#corners, 0)
	for i, p in corners do
		local found = welder.find(p)
		if not found then
			table.insert(positions, p)
			found = #positions
			welder.register(p, found :: number)
		end
		indices[i] = found :: number
	end
	return positions, indices
end

-- Drops positions no triangle uses.
function MeshData.compact(m: MeshData): MeshData
	local remap: { [number]: number } = {}
	local positions = {}
	local tris = table.create(#m.tris, 0)
	for i, index in m.tris do
		local mapped = remap[index]
		if not mapped then
			table.insert(positions, m.positions[index])
			mapped = #positions
			remap[index] = mapped
		end
		tris[i] = mapped
	end
	return { positions = positions, tris = tris, normals = m.normals, uvs = m.uvs, caps = m.caps }
end

function MeshData.fromSoup(corners: { Vector3 }, normals: { Vector3 }?, uvs: { Vector2 }?, weld: number?): MeshData
	local positions, indices = weldPositions(corners, weld or DEFAULT_WELD)
	local m = new()
	m.positions = positions
	for first = 1, #corners - 2, 3 do
		local a, b, c = indices[first], indices[first + 1], indices[first + 2]
		if a == b or b == c or a == c then
			continue
		end
		local cross = (positions[b] - positions[a]):Cross(positions[c] - positions[a])
		local faceNormal = if cross.Magnitude > 0 then cross.Unit else Vector3.yAxis
		for k = 0, 2 do
			table.insert(m.tris, indices[first + k])
			table.insert(m.normals, if normals then normals[first + k] else faceNormal)
			table.insert(m.uvs, if uvs then uvs[first + k] else Vector2.zero)
		end
		table.insert(m.caps, false)
	end
	return MeshData.compact(m)
end

-- A closed box centred on the origin, with flat faces and planar UVs.
function MeshData.box(size: Vector3): MeshData
	local half = size / 2
	local corners, uvs = {}, {}
	-- each face: its outward axis and two in-plane axes with right x up = outward
	local faces = {
		{ Vector3.xAxis, -Vector3.zAxis, Vector3.yAxis },
		{ -Vector3.xAxis, Vector3.zAxis, Vector3.yAxis },
		{ Vector3.yAxis, Vector3.xAxis, -Vector3.zAxis },
		{ -Vector3.yAxis, Vector3.xAxis, Vector3.zAxis },
		{ Vector3.zAxis, Vector3.xAxis, Vector3.yAxis },
		{ -Vector3.zAxis, -Vector3.xAxis, Vector3.yAxis },
	}
	for _, face in faces do
		local out, right, up = face[1], face[2], face[3]
		local function corner(x: number, y: number)
			local p = (out + right * x + up * y) * half
			table.insert(corners, p)
			table.insert(uvs, Vector2.new(p:Dot(right), -p:Dot(up)) / 4)
		end
		corner(-1, -1)
		corner(1, -1)
		corner(1, 1)
		corner(-1, -1)
		corner(1, 1)
		corner(-1, 1)
	end
	return MeshData.fromSoup(corners, nil, uvs)
end

function MeshData.bounds(m: MeshData): (Vector3, Vector3)
	if #m.positions == 0 then
		return Vector3.zero, Vector3.zero
	end
	local low, high = m.positions[1], m.positions[1]
	for _, p in m.positions do
		low = low:Min(p)
		high = high:Max(p)
	end
	return low, high
end

-- Signed volume; positive for an outward-wound closed mesh.
function MeshData.volume(m: MeshData): number
	local positions, tris = m.positions, m.tris
	if #tris == 0 then
		return 0
	end
	local origin = positions[tris[1]]
	local sum = 0
	for i = 1, #tris, 3 do
		local a = positions[tris[i]] - origin
		local b = positions[tris[i + 1]] - origin
		local c = positions[tris[i + 2]] - origin
		sum += a:Dot(b:Cross(c))
	end
	return sum / 6
end

local function edgeUses(m: MeshData): { [number]: number }
	local uses: { [number]: number } = {}
	local tris = m.tris
	for i = 1, #tris, 3 do
		local a, b, c = tris[i], tris[i + 1], tris[i + 2]
		local ab, bc, ca = edgeKey(a, b), edgeKey(b, c), edgeKey(c, a)
		uses[ab] = (uses[ab] or 0) + 1
		uses[bc] = (uses[bc] or 0) + 1
		uses[ca] = (uses[ca] or 0) + 1
	end
	return uses
end

-- Edges used by exactly one triangle.
function MeshData.boundaryEdges(m: MeshData): number
	local count = 0
	for _, uses in edgeUses(m) do
		if uses == 1 then
			count += 1
		end
	end
	return count
end

-- Joins directed edges into loops. A walk that touches itself is split at the pinch.
-- A walk that dead-ends is still returned as a loop and counted as open.
function MeshData.chainLoops(edges: { { number } }): ({ { number } }, number)
	local outgoing: { [number]: { number } } = {}
	local incoming: { [number]: number } = {}
	for i, edge in edges do
		local list = outgoing[edge[1]]
		if not list then
			list = {}
			outgoing[edge[1]] = list
		end
		table.insert(list, i)
		incoming[edge[2]] = (incoming[edge[2]] or 0) + 1
	end

	local used = table.create(#edges, false)
	local loops: { { number } } = {}
	local open = 0

	local function takeFrom(vertex: number): number?
		local list = outgoing[vertex]
		if list then
			while #list > 0 do
				local i = table.remove(list) :: number
				if not used[i] then
					used[i] = true
					return edges[i][2]
				end
			end
		end
		return nil
	end

	local function walk(start: number)
		while true do
			local following = takeFrom(start)
			if not following then
				return
			end
			local path = { start }
			local at: { [number]: number } = { [start] = 1 }
			local current = following
			while true do
				local seen = at[current]
				if seen then
					-- closed a loop: cut it off the path and keep walking from the pinch
					local loop = table.move(path, seen, #path, 1, {})
					table.insert(loops, loop)
					for i = #path, seen + 1, -1 do
						at[path[i]] = nil
						path[i] = nil
					end
				else
					table.insert(path, current)
					at[current] = #path
				end
				local after = takeFrom(current)
				if not after then
					break
				end
				current = after
			end
			if #path > 1 then
				open += 1
				table.insert(loops, path)
			end
		end
	end

	-- start dead-end chains at their beginnings so they come out whole
	for _, edge in edges do
		if not incoming[edge[1]] then
			walk(edge[1])
		end
	end
	for i, edge in edges do
		if not used[i] then
			walk(edge[1])
		end
	end
	return loops, open
end

-- Newell's method: the area-weighted normal of a planar or near-planar loop.
local function loopNormal(positions: { Vector3 }, loop: { number }): Vector3
	local origin = positions[loop[1]]
	local sum = Vector3.zero
	for i, index in loop do
		local a = positions[index] - origin
		local b = positions[loop[i % #loop + 1]] - origin
		sum += a:Cross(b)
	end
	return if sum.Magnitude > 0 then sum.Unit else Vector3.yAxis
end

local function copy(m: MeshData): MeshData
	return {
		positions = table.clone(m.positions),
		tris = table.clone(m.tris),
		normals = table.clone(m.normals),
		uvs = table.clone(m.uvs),
		caps = table.clone(m.caps),
	}
end

-- Returns a closed copy and the number of loops that were filled.
function MeshData.closeHoles(m: MeshData): (MeshData, number)
	local uses = edgeUses(m)
	local edges: { { number } } = {}
	local cornerUv: { [number]: Vector2 } = {}
	local tris = m.tris
	for i = 1, #tris, 3 do
		for k = 0, 2 do
			local a, b = tris[i + k], tris[i + (k + 1) % 3]
			if uses[edgeKey(a, b)] == 1 then
				table.insert(edges, { b, a })
				cornerUv[a] = m.uvs[i + k]
				cornerUv[b] = m.uvs[i + (k + 1) % 3]
			end
		end
	end

	local result = copy(m)
	local filled = 0
	local loops = MeshData.chainLoops(edges)
	for _, loop in loops do
		if #loop < 3 then
			continue
		end
		local normal = loopNormal(m.positions, loop)
		local triangles = Triangulate.loops(m.positions, { loop }, normal)
		for i = 1, #triangles, 3 do
			for k = 0, 2 do
				local index = triangles[i + k]
				table.insert(result.tris, index)
				table.insert(result.normals, normal)
				table.insert(result.uvs, cornerUv[index] or Vector2.zero)
			end
			table.insert(result.caps, false)
		end
		filled += 1
	end
	return result, filled
end

-- One mesh per group of triangles connected through shared positions.
function MeshData.splitIslands(m: MeshData): { MeshData }
	local parent = table.create(#m.positions, 0)
	for i = 1, #m.positions do
		parent[i] = i
	end
	local function find(i: number): number
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end
	local tris = m.tris
	for i = 1, #tris, 3 do
		local root = find(tris[i])
		parent[find(tris[i + 1])] = root
		parent[find(tris[i + 2])] = root
	end

	local byRoot: { [number]: MeshData } = {}
	local islands: { MeshData } = {}
	for i = 1, #tris, 3 do
		local root = find(tris[i])
		local island = byRoot[root]
		if not island then
			island = new()
			island.positions = m.positions
			byRoot[root] = island
			table.insert(islands, island)
		end
		for k = 0, 2 do
			table.insert(island.tris, tris[i + k])
			table.insert(island.normals, m.normals[i + k])
			table.insert(island.uvs, m.uvs[i + k])
		end
		table.insert(island.caps, m.caps[(i + 2) / 3])
	end
	if #islands == 1 then
		return { m }
	end
	for i, island in islands do
		islands[i] = MeshData.compact(island)
	end
	return islands
end

local STRAIGHT = 1e-5 -- studs
local FLAT_DOT = 0.99999

-- distance from p to the segment ab
local function segmentDistance(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local squared = ab:Dot(ab)
	local t = if squared > 0 then math.clamp((p - a):Dot(ab) / squared, 0, 1) else 0
	return (p - a - ab * t).Magnitude
end

-- Merges flat faces made of many triangles and drops the points left in the middle of
-- straight edges. Smooth surfaces are untouched. Returns `m` itself if a merged face
-- could not be triangulated cleanly.
function MeshData.simplify(m: MeshData): MeshData
	local positions, tris, normals, uvs, caps = m.positions, m.tris, m.normals, m.uvs, m.caps
	local triangles = #caps

	-- a triangle is flat when its three corners share one normal that it faces
	local flat = table.create(triangles, false)
	local area = table.create(triangles, 0)
	local edgeOwners: { [number]: { number } } = {}
	for t = 1, triangles do
		local f = (t - 1) * 3
		local n = normals[f + 1]
		local a, b, c = positions[tris[f + 1]], positions[tris[f + 2]], positions[tris[f + 3]]
		local cross = (b - a):Cross(c - a)
		area[t] = cross.Magnitude
		flat[t] = n:Dot(normals[f + 2]) > FLAT_DOT
			and n:Dot(normals[f + 3]) > FLAT_DOT
			and (cross.Magnitude < 1e-8 or cross.Unit:Dot(n) > 0.999)
		for k = 1, 3 do
			local key = edgeKey(tris[f + k], tris[f + k % 3 + 1])
			local owners = edgeOwners[key]
			if not owners then
				owners = {}
				edgeOwners[key] = owners
			end
			table.insert(owners, t)
		end
	end

	-- grow regions of coplanar, same-kind triangles, starting from the largest
	local order = {}
	for t = 1, triangles do
		if flat[t] then
			table.insert(order, t)
		end
	end
	table.sort(order, function(a, b)
		if area[a] ~= area[b] then
			return area[a] > area[b]
		end
		return a < b
	end)

	local regionOf: { [number]: number } = {}
	local regions = {}
	for _, seed in order do
		if regionOf[seed] then
			continue
		end
		local f = (seed - 1) * 3
		local normal, origin = normals[f + 1], positions[tris[f + 1]]
		local region = { normal = normal, cap = caps[seed], members = { seed }, uv = {} :: { [number]: Vector2 } }
		for k = 1, 3 do
			region.uv[tris[f + k]] = uvs[f + k]
		end
		table.insert(regions, region)
		regionOf[seed] = #regions
		local head = 1
		while head <= #region.members do
			local t = region.members[head]
			head += 1
			local first = (t - 1) * 3
			for k = 1, 3 do
				for _, other in edgeOwners[edgeKey(tris[first + k], tris[first + k % 3 + 1])] do
					if regionOf[other] or not flat[other] or caps[other] ~= region.cap then
						continue
					end
					local o = (other - 1) * 3
					if normals[o + 1]:Dot(normal) <= FLAT_DOT then
						continue
					end
					local fits = true
					for j = 1, 3 do
						local index = tris[o + j]
						local known = region.uv[index]
						if math.abs((positions[index] - origin):Dot(normal)) > 1e-4 or (known and (known - uvs[o + j]).Magnitude > 1e-3) then
							fits = false
							break
						end
					end
					if fits then
						for j = 1, 3 do
							region.uv[tris[o + j]] = uvs[o + j]
						end
						regionOf[other] = #regions
						table.insert(region.members, other)
					end
				end
			end
		end
	end

	-- vertices that must stay because a curved triangle uses them
	local pinned: { [number]: boolean } = {}
	for t = 1, triangles do
		if not flat[t] then
			local f = (t - 1) * 3
			pinned[tris[f + 1]], pinned[tris[f + 2]], pinned[tris[f + 3]] = true, true, true
		end
	end

	-- the outline of every region
	local allLoops: { { number } } = {}
	local loopsOf = table.create(#regions)
	for r, region in regions do
		local inside: { [string]: number } = {}
		for _, t in region.members do
			local f = (t - 1) * 3
			for k = 1, 3 do
				local key = `{tris[f + k]}>{tris[f + k % 3 + 1]}`
				inside[key] = (inside[key] or 0) + 1
			end
		end
		local outline = {}
		for _, t in region.members do
			local f = (t - 1) * 3
			for k = 1, 3 do
				local a, b = tris[f + k], tris[f + k % 3 + 1]
				local reverse = `{b}>{a}`
				if (inside[reverse] or 0) > 0 then
					inside[reverse] -= 1
					inside[`{a}>{b}`] -= 1
				elseif inside[`{a}>{b}`] > 0 then
					table.insert(outline, { a, b })
				end
			end
		end
		local loops, open = MeshData.chainLoops(outline)
		if open > 0 then
			return m
		end
		loopsOf[r] = loops
		for _, loop in loops do
			table.insert(allLoops, loop)
		end
	end

	-- drop points on a straight edge, from both faces that share it at once
	local appears: { [number]: { { number } } } = {}
	for _, loop in allLoops do
		for _, index in loop do
			local list = appears[index]
			if not list then
				list = {}
				appears[index] = list
			end
			table.insert(list, loop)
		end
	end
	local changed = true
	while changed do
		changed = false
		for index = 1, #positions do
			local list = appears[index]
			if not list or pinned[index] or #list ~= 2 or list[1] == list[2] then
				continue
			end
			local first, second = list[1], list[2]
			if #first <= 3 or #second <= 3 then
				continue
			end
			local i, j = table.find(first, index) :: number, table.find(second, index) :: number
			local a, b = first[(i - 2) % #first + 1], first[i % #first + 1]
			local c, d = second[(j - 2) % #second + 1], second[j % #second + 1]
			if not ((a == d and b == c) or (a == c and b == d)) or a == b then
				continue
			end
			if segmentDistance(positions[index], positions[a], positions[b]) > STRAIGHT then
				continue
			end
			table.remove(first, i)
			table.remove(second, j)
			appears[index] = nil
			changed = true
		end
	end

	local result = new()
	result.positions = positions
	for t = 1, triangles do
		if not flat[t] then
			local f = (t - 1) * 3
			for k = 1, 3 do
				table.insert(result.tris, tris[f + k])
				table.insert(result.normals, normals[f + k])
				table.insert(result.uvs, uvs[f + k])
			end
			table.insert(result.caps, caps[t])
		end
	end
	for r, region in regions do
		local filled, warnings = Triangulate.loops(positions, loopsOf[r], region.normal)
		if warnings > 0 then
			return m
		end
		for i = 1, #filled, 3 do
			for k = 0, 2 do
				local index = filled[i + k]
				table.insert(result.tris, index)
				table.insert(result.normals, region.normal)
				table.insert(result.uvs, region.uv[index] or Vector2.zero)
			end
			table.insert(result.caps, region.cap)
		end
	end
	return MeshData.compact(result)
end

-- Layout: u32 positions, u32 triangles, positions (3 x f32), then per triangle
-- 3 x u32 indices, 3 x 3 x f32 normals, 3 x 2 x f32 uvs, u8 cap flag.
local TRIANGLE_BYTES = 3 * 4 + 9 * 4 + 6 * 4 + 1

function MeshData.pack(m: MeshData): buffer
	local positions, tris = m.positions, m.tris
	local triangles = #tris / 3
	local data = buffer.create(8 + #positions * 12 + triangles * TRIANGLE_BYTES)
	buffer.writeu32(data, 0, #positions)
	buffer.writeu32(data, 4, triangles)
	local offset = 8
	for _, p in positions do
		buffer.writef32(data, offset, p.X)
		buffer.writef32(data, offset + 4, p.Y)
		buffer.writef32(data, offset + 8, p.Z)
		offset += 12
	end
	for t = 1, triangles do
		local first = (t - 1) * 3
		for k = 1, 3 do
			local n, uv = m.normals[first + k], m.uvs[first + k]
			buffer.writeu32(data, offset + (k - 1) * 4, tris[first + k])
			local normalOffset = offset + 12 + (k - 1) * 12
			buffer.writef32(data, normalOffset, n.X)
			buffer.writef32(data, normalOffset + 4, n.Y)
			buffer.writef32(data, normalOffset + 8, n.Z)
			local uvOffset = offset + 48 + (k - 1) * 8
			buffer.writef32(data, uvOffset, uv.X)
			buffer.writef32(data, uvOffset + 4, uv.Y)
		end
		buffer.writeu8(data, offset + 72, if m.caps[t] then 1 else 0)
		offset += TRIANGLE_BYTES
	end
	return data
end

function MeshData.unpack(data: buffer): MeshData
	local positionCount = buffer.readu32(data, 0)
	local triangles = buffer.readu32(data, 4)
	local m: MeshData = {
		positions = table.create(positionCount),
		tris = table.create(triangles * 3),
		normals = table.create(triangles * 3),
		uvs = table.create(triangles * 3),
		caps = table.create(triangles),
	}
	local offset = 8
	for i = 1, positionCount do
		m.positions[i] = Vector3.new(buffer.readf32(data, offset), buffer.readf32(data, offset + 4), buffer.readf32(data, offset + 8))
		offset += 12
	end
	for t = 1, triangles do
		local first = (t - 1) * 3
		for k = 1, 3 do
			m.tris[first + k] = buffer.readu32(data, offset + (k - 1) * 4)
			local normalOffset = offset + 12 + (k - 1) * 12
			m.normals[first + k] = Vector3.new(buffer.readf32(data, normalOffset), buffer.readf32(data, normalOffset + 4), buffer.readf32(data, normalOffset + 8))
			local uvOffset = offset + 48 + (k - 1) * 8
			m.uvs[first + k] = Vector2.new(buffer.readf32(data, uvOffset), buffer.readf32(data, uvOffset + 4))
		end
		m.caps[t] = buffer.readu8(data, offset + 72) == 1
		offset += TRIANGLE_BYTES
	end
	return m
end

return MeshData
