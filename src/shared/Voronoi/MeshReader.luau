-- Reads a MeshPart's mesh into plain data, in part-local studs. Serial only; yields.

local AssetService = game:GetService("AssetService")

local MeshData = require(script.Parent.Geometry.MeshData)

type MeshData = MeshData.MeshData
export type Info = { holes: number }

-- an asset's triangles at its own size: downloading it is the slow part, so that happens once however many sizes of it
-- are in the world
type Soup = { corners: { Vector3 }, normals: { Vector3 }, uvs: { Vector2 } }

local cache: { [string]: { mesh: MeshData, info: Info } } = {}
local soups: { [string]: Soup } = {}

local MeshReader = {}

-- The one place source meshes are opened.
function MeshReader.createEditable(content: Content): EditableMesh?
	return AssetService:CreateEditableMeshAsync(content, { FixedSize = true })
end

local function extract(editable: EditableMesh): Soup
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
					position = editable:GetPosition(id)
					positions[id] = position
				end
				table.insert(corners, position)
				table.insert(normals, editable:GetNormal(normalIds[k]))
				table.insert(uvs, editable:GetUV(uvIds[k]) or Vector2.zero)
			end
		end
	end
	return { corners = corners, normals = normals, uvs = uvs }
end

local function scaled(soup: Soup, scale: Vector3): MeshData
	local inverse = Vector3.one / scale
	local corners = table.create(#soup.corners)
	local normals = table.create(#soup.normals)
	for i, corner in soup.corners do
		corners[i] = corner * scale
		-- normals scale by the reciprocal so they stay perpendicular
		local normal = soup.normals[i] * inverse
		normals[i] = if normal.Magnitude > 0 then normal.Unit else Vector3.yAxis
	end
	return MeshData.fromSoup(corners, normals, soup.uvs)
end

-- The returned mesh is shared and must not be mutated.
function MeshReader.read(part: MeshPart, closeHoles: boolean): (MeshData, Info)
	local content = part.MeshContent
	local scale = part.Size / part.MeshSize

	-- only asset content has a stable identity
	local key: string?, asset: string? = nil, nil
	if content.SourceType == Enum.ContentSourceType.Uri then
		asset = content.Uri :: string
		key = `{asset}|{scale}|{closeHoles}`
		local hit = cache[key :: string]
		if hit then
			return hit.mesh, hit.info
		end
	end

	local soup = if asset then soups[asset] else nil
	if not soup then
		local editable = MeshReader.createEditable(content)
		if not editable then
			error("Voronoi: out of editable mesh memory while reading the source mesh", 0)
		end
		local ok, result = pcall(extract, editable)
		editable:Destroy()
		if not ok then
			error(result, 0)
		end
		soup = result :: Soup
		if asset then
			soups[asset] = soup :: Soup
		end
	end

	local mesh = scaled(soup :: Soup, scale)
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
	table.clear(soups)
end

return MeshReader
