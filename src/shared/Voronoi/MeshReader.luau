-- Reads a MeshPart's mesh into plain data, in part-local studs. Serial only; yields.

local AssetService = game:GetService("AssetService")

local MeshData = require(script.Parent.Geometry.MeshData)

type MeshData = MeshData.MeshData
export type Info = { holes: number }

local cache: { [string]: { mesh: MeshData, info: Info } } = {}

local MeshReader = {}

local function extract(editable: EditableMesh, scale: Vector3): MeshData
	local inverse = Vector3.one / scale
	local positions: { [number]: Vector3 } = {}
	local corners, normals, uvs = {}, {}, {}

	for _, face in editable:GetFaces() do
		local vertexIds = editable:GetFaceVertices(face)
		local normalIds = editable:GetFaceNormals(face)
		local uvIds = editable:GetFaceUVs(face)
		-- fan, in case the mesh has quads
		for second = 2, #vertexIds - 1 do
			for _, k in { 1, second, second + 1 } do
				local id = vertexIds[k]
				local position = positions[id]
				if not position then
					position = editable:GetPosition(id) * scale
					positions[id] = position
				end
				-- normals scale by the reciprocal so they stay perpendicular
				local normal = editable:GetNormal(normalIds[k]) * inverse
				table.insert(corners, position)
				table.insert(normals, if normal.Magnitude > 0 then normal.Unit else Vector3.yAxis)
				table.insert(uvs, editable:GetUV(uvIds[k]) or Vector2.zero)
			end
		end
	end
	return MeshData.fromSoup(corners, normals, uvs)
end

-- The returned mesh is shared and must not be mutated.
function MeshReader.read(part: MeshPart, closeHoles: boolean): (MeshData, Info)
	local content = part.MeshContent
	local scale = part.Size / part.MeshSize

	-- only asset content has a stable identity
	local key: string? = nil
	if content.SourceType == Enum.ContentSourceType.Uri then
		key = `{content.Uri}|{scale}|{closeHoles}`
		local hit = cache[key]
		if hit then
			return hit.mesh, hit.info
		end
	end

	local editable = AssetService:CreateEditableMeshAsync(content, { FixedSize = true })
	if not editable then
		error("Voronoi: out of editable mesh memory while reading the source mesh", 0)
	end
	local ok, result = pcall(extract, editable, scale)
	editable:Destroy()
	if not ok then
		error(result, 0)
	end

	local mesh = result :: MeshData
	local holes = 0
	if closeHoles then
		mesh, holes = MeshData.closeHoles(mesh)
	end
	local info: Info = { holes = holes }
	if key then
		cache[key] = { mesh = mesh, info = info }
	end
	return mesh, info
end

function MeshReader.clearCache()
	table.clear(cache)
end

return MeshReader
