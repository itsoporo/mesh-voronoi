-- Hand-built closed meshes with known volumes. All faces are wound outward.
local Fixtures = {}

local function addQuad(corners, a, b, c, d)
	for _, p in { a, b, c, a, c, d } do
		table.insert(corners, p)
	end
end

local function boxCorners(center: Vector3, half: Vector3, skipTop: boolean?)
	local function p(x, y, z)
		return center + Vector3.new(x, y, z) * half
	end
	local corners = {}
	addQuad(corners, p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), p(1, -1, 1))
	addQuad(corners, p(-1, -1, -1), p(-1, -1, 1), p(-1, 1, 1), p(-1, 1, -1))
	if not skipTop then
		addQuad(corners, p(-1, 1, -1), p(-1, 1, 1), p(1, 1, 1), p(1, 1, -1))
	end
	addQuad(corners, p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1))
	addQuad(corners, p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1))
	addQuad(corners, p(-1, -1, -1), p(-1, 1, -1), p(1, 1, -1), p(1, -1, -1))
	return corners
end

Fixtures.boxCorners = boxCorners

function Fixtures.box(MeshData, center: Vector3, half: Vector3)
	return MeshData.fromSoup(boxCorners(center, half))
end

-- side 2, +Y face missing
function Fixtures.openBox(MeshData)
	return MeshData.fromSoup(boxCorners(Vector3.zero, Vector3.one, true))
end

-- 4 x 4 x 2 box with a 2 x 2 square tunnel along Z; volume 24
function Fixtures.tunnel(MeshData)
	local square = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
	local function outer(i, z)
		return Vector3.new(square[i][1] * 2, square[i][2] * 2, z)
	end
	local function inner(i, z)
		return Vector3.new(square[i][1], square[i][2], z)
	end
	local corners = {}
	for i = 1, 4 do
		local j = i % 4 + 1
		addQuad(corners, outer(i, 1), outer(j, 1), inner(j, 1), inner(i, 1))
		addQuad(corners, inner(i, -1), inner(j, -1), outer(j, -1), outer(i, -1))
		addQuad(corners, outer(i, -1), outer(j, -1), outer(j, 1), outer(i, 1))
		addQuad(corners, inner(i, 1), inner(j, 1), inner(j, -1), inner(i, -1))
	end
	return MeshData.fromSoup(corners)
end

return Fixtures
