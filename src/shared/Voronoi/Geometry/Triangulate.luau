--!optimize 2
-- Triangulates planar loops with holes. Pure: safe to call in parallel.
--
-- Every loop edge appears in the output in the loop's own direction, and no vertex is
-- dropped, so a cap built from these triangles stays watertight against its surface.

local Triangulate = {}

local FLAT = 1e-12 -- signed areas this small have no orientation
-- studs; about the noise in single-precision positions, so anything closer than this
-- to a side or a point is on it
local TOLERANCE = 1e-6
-- corners flatter than this are checked as possible blockers; it only has to be
-- comfortably above the noise
local BENT_TOLERANCE = 1e-5

type Plane = { x: { number }, y: { number } }

local function cross(p: Plane, a: number, b: number, c: number): number
	return (p.x[b] - p.x[a]) * (p.y[c] - p.y[a]) - (p.y[b] - p.y[a]) * (p.x[c] - p.x[a])
end

local function signedArea(p: Plane, loop: { number }): number
	local first = loop[1]
	local sum = 0
	for i = 2, #loop - 1 do
		sum += cross(p, first, loop[i], loop[i + 1])
	end
	return sum / 2
end

local function length(p: Plane, a: number, b: number): number
	local dx, dy = p.x[b] - p.x[a], p.y[b] - p.y[a]
	return math.sqrt(dx * dx + dy * dy)
end

local function samePosition(p: Plane, a: number, b: number): boolean
	local dx, dy = p.x[b] - p.x[a], p.y[b] - p.y[a]
	return dx * dx + dy * dy <= TOLERANCE * TOLERANCE
end

local function containsPoint(p: Plane, loop: { number }, px: number, py: number): boolean
	local inside = false
	local previous = loop[#loop]
	for _, current in loop do
		local ax, ay, bx, by = p.x[previous], p.y[previous], p.x[current], p.y[current]
		if (ay > py) ~= (by > py) and px < ax + (py - ay) / (by - ay) * (bx - ax) then
			inside = not inside
		end
		previous = current
	end
	return inside
end

local function nearSegment(p: Plane, a: number, b: number, q: number): boolean
	local abx, aby = p.x[b] - p.x[a], p.y[b] - p.y[a]
	local aqx, aqy = p.x[q] - p.x[a], p.y[q] - p.y[a]
	local squared = abx * abx + aby * aby
	local t = if squared > 0 then math.clamp((aqx * abx + aqy * aby) / squared, 0, 1) else 0
	local dx, dy = aqx - abx * t, aqy - aby * t
	return dx * dx + dy * dy <= TOLERANCE * TOLERANCE
end

-- strictly inside a counter-clockwise triangle, or touching one of its sides. The
-- sides are segments: slack around endless lines would reach far past sharp corners.
local function inTriangle(p: Plane, a: number, b: number, c: number, q: number): boolean
	if cross(p, a, b, q) > 0 and cross(p, b, c, q) > 0 and cross(p, c, a, q) > 0 then
		return true
	end
	return nearSegment(p, a, b, q) or nearSegment(p, b, c, q) or nearSegment(p, c, a, q)
end

-- is the direction cur -> target inside the polygon's corner at cur?
local function inCorner(p: Plane, previous: number, current: number, after: number, target: number): boolean
	local first = cross(p, previous, current, target) > 0
	local second = cross(p, current, after, target) > 0
	if cross(p, previous, current, after) > 0 then
		return first and second
	end
	return first or second
end

local function rightmost(p: Plane, loop: { number }): number
	local best = 1
	for i = 2, #loop do
		if p.x[loop[i]] > p.x[loop[best]] then
			best = i
		end
	end
	return best
end

-- Index into `polygon` of a vertex visible from the hole vertex `m`.
local function findBridge(p: Plane, polygon: { number }, m: number): number?
	local mx, my = p.x[m], p.y[m]
	local hitX = math.huge
	local candidate: number? = nil
	local count = #polygon

	-- nearest edge hit by a ray from m towards +x
	for i = 1, count do
		local a, b = polygon[i], polygon[i % count + 1]
		local ay, by = p.y[a], p.y[b]
		if ay <= my and my <= by and ay ~= by then
			local x = p.x[a] + (my - ay) / (by - ay) * (p.x[b] - p.x[a])
			if x >= mx - 1e-9 and x < hitX then
				hitX = x
				candidate = if p.x[a] > p.x[b] then i else i % count + 1
				if my == ay then
					candidate = i
				elseif my == by then
					candidate = i % count + 1
				end
			end
		end
	end
	if not candidate then
		return nil
	end

	-- a vertex inside the triangle (m, hit, candidate) blocks the view: take the one
	-- closest in angle to the ray
	local target = polygon[candidate]
	local tx, ty = p.x[target], p.y[target]
	local bestSlope, bestDistance = math.huge, math.huge
	local chosen = candidate
	for i = 1, count do
		local v = polygon[i]
		local vx, vy = p.x[v], p.y[v]
		if vx >= mx and not (vx == tx and vy == ty) then
			local d1 = (hitX - mx) * (vy - my)
			local d2 = (tx - hitX) * (vy - my) - (ty - my) * (vx - hitX)
			local d3 = (mx - tx) * (vy - ty) - (my - ty) * (vx - tx)
			local negative = d1 < 0 or d2 < 0 or d3 < 0
			local positive = d1 > 0 or d2 > 0 or d3 > 0
			if not (negative and positive) and vx > mx then
				local slope = math.abs(vy - my) / (vx - mx)
				local distance = vx - mx
				if slope < bestSlope or (slope == bestSlope and distance < bestDistance) then
					bestSlope, bestDistance = slope, distance
					chosen = i
				end
			end
		end
	end

	-- earlier bridges can repeat a vertex: pick the occurrence whose corner faces m
	local vertex = polygon[chosen]
	for i = 1, count do
		if polygon[i] == vertex and inCorner(p, polygon[(i - 2) % count + 1], vertex, polygon[i % count + 1], m) then
			return i
		end
	end
	return chosen
end

local function spliceHole(p: Plane, polygon: { number }, hole: { number }): ({ number }, number)
	local start = rightmost(p, hole)
	local m = hole[start]
	local bridge = findBridge(p, polygon, m)
	local warnings = 0
	if not bridge then
		warnings = 1
		local best = math.huge
		for i, v in polygon do
			local distance = (p.x[v] - p.x[m]) ^ 2 + (p.y[v] - p.y[m]) ^ 2
			if distance < best then
				best = distance
				bridge = i
			end
		end
	end

	local merged = table.create(#polygon + #hole + 2)
	for i = 1, bridge :: number do
		table.insert(merged, polygon[i])
	end
	for k = 0, #hole do
		table.insert(merged, hole[(start - 1 + k) % #hole + 1])
	end
	for i = bridge :: number, #polygon do
		table.insert(merged, polygon[i])
	end
	return merged, warnings
end

local function clipEars(p: Plane, polygon: { number }, out: { number }): number
	local count = #polygon
	if count < 3 then
		return 0
	end
	local nextOf, previousOf = table.create(count, 0), table.create(count, 0)
	for i = 1, count do
		nextOf[i] = i % count + 1
		previousOf[i] = (i - 2) % count + 1
	end

	local function emit(i: number)
		local a, b, c = previousOf[i], i, nextOf[i]
		table.insert(out, polygon[a])
		table.insert(out, polygon[b])
		table.insert(out, polygon[c])
		nextOf[a] = c
		previousOf[c] = a
	end

	local bent: { boolean } = table.create(count, false)

	-- shape quality of the ear at i (higher is rounder), or nil if i is not an ear
	local function earQuality(i: number): number?
		local a, b, c = polygon[previousOf[i]], polygon[i], polygon[nextOf[i]]
		local area = cross(p, a, b, c)
		if area <= FLAT then
			return nil
		end
		local x, y = p.x, p.y
		local minX = math.min(x[a], x[b], x[c]) - TOLERANCE
		local maxX = math.max(x[a], x[b], x[c]) + TOLERANCE
		local minY = math.min(y[a], y[b], y[c]) - TOLERANCE
		local maxY = math.max(y[a], y[b], y[c]) + TOLERANCE
		local last = previousOf[i]
		local j = nextOf[nextOf[i]]
		while j ~= last do
			-- only a straight or inward corner can block an ear
			if bent[j] then
				local q = polygon[j]
				local qx, qy = x[q], y[q]
				if qx >= minX and qx <= maxX and qy >= minY and qy <= maxY then
					if not samePosition(p, q, a) and not samePosition(p, q, b) and not samePosition(p, q, c) and inTriangle(p, a, b, c, q) then
						return nil
					end
				end
			end
			j = nextOf[j]
		end
		local abx, aby = x[b] - x[a], y[b] - y[a]
		local bcx, bcy = x[c] - x[b], y[c] - y[b]
		local cax, cay = x[a] - x[c], y[a] - y[c]
		return area / (abx * abx + aby * aby + bcx * bcx + bcy * bcy + cax * cax + cay * cay)
	end

	-- Clipping the roundest ear first leaves points on straight edges to be joined to
	-- far corners, instead of stranding them in a flat remainder.
	local quality: { [number]: number } = {}
	local function refresh(i: number)
		quality[i] = earQuality(i) :: any
	end
	local function bend(i: number)
		local a, b, c = polygon[previousOf[i]], polygon[i], polygon[nextOf[i]]
		bent[i] = cross(p, a, b, c) <= BENT_TOLERANCE * math.max(length(p, a, b), length(p, b, c))
	end
	for i = 1, count do
		bend(i)
	end
	for i = 1, count do
		refresh(i)
	end

	local remaining = count
	local current = 1
	local warnings = 0
	local function roundest(): number?
		local best: number? = nil
		local j = current
		for _ = 1, remaining do
			if quality[j] and (not best or quality[j] > quality[best :: number]) then
				best = j
			end
			j = nextOf[j]
		end
		return best
	end

	while remaining > 3 do
		local best = roundest()
		if not best then
			-- removing a vertex can unblock others: look again before giving up
			local j = current
			for _ = 1, remaining do
				refresh(j)
				j = nextOf[j]
			end
			best = roundest()
		end
		if not best then
			-- no clean ear: clip the flattest corner that does not face backwards
			local bestScore = math.huge
			local j = current
			for _ = 1, remaining do
				local area = cross(p, polygon[previousOf[j]], polygon[j], polygon[nextOf[j]])
				local score = if area >= -FLAT then math.abs(area) else 1e30 + math.abs(area)
				if score < bestScore then
					best, bestScore = j, score
				end
				j = nextOf[j]
			end
			warnings += 1
		end
		local tip = best :: number
		local before, after = previousOf[tip], nextOf[tip]
		emit(tip)
		remaining -= 1
		quality[tip] = nil
		current = after
		bend(before)
		bend(after)
		refresh(before)
		refresh(after)
	end
	emit(current)
	return warnings
end

function Triangulate.loops(points: { Vector3 }, loops: { { number } }, normal: Vector3): ({ number }, number)
	local n = normal.Unit
	local helper = if math.abs(n.X) < 0.9 then Vector3.xAxis else Vector3.yAxis
	local u = helper:Cross(n).Unit
	local v = n:Cross(u)

	local plane: Plane = { x = {}, y = {} }
	local origin: Vector3? = nil
	for _, loop in loops do
		for _, index in loop do
			origin = origin or points[index]
			local relative = points[index] - (origin :: Vector3)
			plane.x[index] = relative:Dot(u)
			plane.y[index] = relative:Dot(v)
		end
	end

	local outers, holes = {}, {}
	for _, loop in loops do
		if #loop >= 3 then
			local area = signedArea(plane, loop)
			if area < -FLAT then
				table.insert(holes, { loop = loop, area = area, right = plane.x[loop[rightmost(plane, loop)]], owner = nil :: any })
			else
				table.insert(outers, { loop = loop, area = area, holes = {} })
			end
		end
	end

	local out: { number } = {}
	local warnings = 0

	for _, hole in holes do
		local vertex = hole.loop[rightmost(plane, hole.loop)]
		for _, outer in outers do
			if (not hole.owner or outer.area < hole.owner.area) and outer.area > -hole.area - FLAT and containsPoint(plane, outer.loop, plane.x[vertex], plane.y[vertex]) then
				hole.owner = outer
			end
		end
		if hole.owner then
			table.insert(hole.owner.holes, hole)
		else
			-- a clockwise loop with nothing around it: triangulate it reversed, then flip
			-- the triangles back so its edges keep their direction
			warnings += 1
			local count = #hole.loop
			local reversed = table.create(count)
			for i = 1, count do
				reversed[i] = hole.loop[count - i + 1]
			end
			local first = #out + 1
			warnings += clipEars(plane, reversed, out)
			for i = first, #out, 3 do
				out[i], out[i + 2] = out[i + 2], out[i]
			end
		end
	end

	for _, outer in outers do
		local polygon = outer.loop
		table.sort(outer.holes, function(a, b)
			return a.right > b.right
		end)
		for _, hole in outer.holes do
			local merged, missed = spliceHole(plane, polygon, hole.loop)
			polygon = merged
			warnings += missed
		end
		warnings += clipEars(plane, polygon, out)
	end

	return out, warnings
end

return Triangulate
