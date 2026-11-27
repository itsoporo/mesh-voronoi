local AssetService = game:GetService("AssetService")

local MeshSplitter = {}

local function isInPlane(point: Vector3, plane: CFrame): boolean
	--print(math.abs((plane.Position - point).Unit:Dot(plane.UpVector)))
	return math.abs((plane.Position - point):Dot(plane.UpVector)) <= 0.1
end

local function posKey(pos: Vector3): string
	return string.format("%.4f,%.4f,%.4f", pos.X, pos.Y, pos.Z)
end

local function addOrGetVertex(mesh: EditableMesh, posMap: {[string]: number}, pos: Vector3): number
	local key = posKey(pos)
	local existingId = posMap[key]
	if existingId then
		return existingId
	end
	local id = mesh:AddVertex(pos)
	posMap[key] = id
	return id
end

function MeshSplitter:SplitMesh(MeshPart: MeshPart, PlaneCFrame: CFrame)
	local target_mesh = AssetService:CreateEditableMeshAsync(MeshPart.MeshContent, {FixedSize = true}) :: EditableMesh
	local positive_mesh = AssetService:CreateEditableMesh({FixedSize = false}) :: EditableMesh
	local negative_mesh = AssetService:CreateEditableMesh({FixedSize = false}) :: EditableMesh

	local positive_meshpart = nil :: nil | MeshPart
	local negative_meshpart = nil :: nil | MeshPart

	local tris = {}
	local verts = {}
	local tri_verts = {}
	local vert_positions = {}

	local vert_uvs = {}

	local vert_uvs = {}
	for _, vertID in verts do
		vert_uvs[vertID] = target_mesh:GetUV(vertID) -- returns Vector2
	end


	for index: number, vertID: number in target_mesh:GetVertices() do
		verts[index] = vertID
	end

	for _, vertID: number in verts do
		vert_positions[vertID] = target_mesh:GetPosition(vertID)
	end

	for index: number, triID: number in target_mesh:GetFaces() do
		tris[index] = triID
	end

	for _, triID: number in tris do
		tri_verts[triID] = target_mesh:GetFaceVertices(triID)
	end

	for _, vertID in verts do
		vert_uvs[vertID] = target_mesh:GetVertexUVs(vertID)
	end

	local has_positive = false
	local has_negative = false

	local planeLocal = MeshPart.CFrame:ToObjectSpace(PlaneCFrame)
	local planePoint = planeLocal.Position
	local planeNormal = planeLocal.UpVector
	
	local outerRimPos, outerRimNeg = { }, { }
	local adjacentPos, adjacentNeg = { }, { }
	local posMapPos, posMapNeg = { }, { }
	local length = 0
	local averagePos = Vector3.zero

	local function filterAdd(tableGiven: { }, vertexId: number, vertexPos: Vector3): boolean
		if isInPlane(vertexPos, planeLocal) and not tableGiven[vertexId] then
			tableGiven[vertexId] = true
			averagePos += vertexPos
			length += 1
		end
		
		if isInPlane(vertexPos, planeLocal) then
			return true
		end
	end
	
	for _, vertices: {} in tri_verts do

		local trix = {
			vert_positions[vertices[1]],
			vert_positions[vertices[2]],
			vert_positions[vertices[3]],
		}
		
		local positive = splitTriangle(trix, planePoint, planeNormal, true)
		local negative = splitTriangle(trix, planePoint, planeNormal, false)


		if positive then
			for _, new_vert_positions: {} in positive do
				has_positive = true

				local new_vert_1 = addOrGetVertex(positive_mesh, posMapPos, new_vert_positions[1])
				local new_vert_2 = addOrGetVertex(positive_mesh, posMapPos, new_vert_positions[2])
				local new_vert_3 = addOrGetVertex(positive_mesh, posMapPos, new_vert_positions[3])

				local new_tri = positive_mesh:AddTriangle(new_vert_1, new_vert_2, new_vert_3) :: number
				
				filterAdd(outerRimPos, new_vert_1, new_vert_positions[1])
				filterAdd(outerRimPos, new_vert_2, new_vert_positions[2])
				filterAdd(outerRimPos, new_vert_3, new_vert_positions[3])
			end
		end

		if negative then
			for _, new_vert_positions: {} in negative do

				has_negative = true
				local new_vert_1 = addOrGetVertex(negative_mesh, posMapNeg, new_vert_positions[1])
				local new_vert_2 = addOrGetVertex(negative_mesh, posMapNeg, new_vert_positions[2])
				local new_vert_3 = addOrGetVertex(negative_mesh, posMapNeg, new_vert_positions[3])

				local new_tri = negative_mesh:AddTriangle(new_vert_1, new_vert_2, new_vert_3) :: number

				filterAdd(outerRimNeg, new_vert_1, new_vert_positions[1])
				filterAdd(outerRimNeg, new_vert_2, new_vert_positions[2])
				filterAdd(outerRimNeg, new_vert_3, new_vert_positions[3])

			end
		end
	end
	
	averagePos /= length
	local centerPosVertex = positive_mesh:AddVertex(averagePos) :: number
	local centerNegVertex = negative_mesh:AddVertex(averagePos) :: number
	
	local filledIn = { }
	
	local function addCorrectNormalTriangle(meshSide: EditableMesh, id1: number, id2: number, id3: number, positiveSide: boolean)
		local p1, p2, p3 = meshSide:GetPosition(id1), meshSide:GetPosition(id2), meshSide:GetPosition(id3)
		
		local d1 = (p2 - p1).Unit
		local d2 = (p3 - p2).Unit
		
		-- the upvector of the plane points to the positiveMesh so we have to flip it
		if d1:Cross(d2):Dot(if positiveSide then -planeLocal.UpVector else planeLocal.UpVector) > 0 then
			meshSide:AddTriangle(id1, id2, id3)
		else
			meshSide:AddTriangle(id3, id2, id1)
		end
	end
	
	local function fillIn(meshSide: EditableMesh, rimTable: { }, centerVertex: number, positiveSide: boolean)
		local startingId, _ = next(rimTable) -- id, bool
		if not startingId then return end
		
		local visited = { [startingId] = true, [centerVertex] = true }
		local visitedLength = 1
		
		
		local function getNextId(id: number): number?
			if not id then return end
			
			local adjacents = meshSide:GetAdjacentVertices(id)
			for _, possible in adjacents do
				
				if rimTable[possible] and not visited[possible] then
					visited[possible] = true
					visitedLength += 1
					return possible
				end
			end
		end

		local currentId = startingId
		-- find all loops
		while visitedLength < length do
			-- finish loop
			local unusedId
			for id, _ in rimTable do
				if not visited[id] then
					unusedId = id
					break
				end
			end
			
			if not unusedId then break end

			addCorrectNormalTriangle(meshSide, centerVertex, currentId, unusedId, positiveSide) 
			currentId = unusedId
			visited[currentId] = true
			visitedLength += 1
			
			while currentId do
				local nextId = getNextId(currentId)
				if not nextId then break end
				
				addCorrectNormalTriangle(meshSide, centerVertex, currentId, nextId, positiveSide)
				currentId = nextId
			end
			
			-- finishing the loop back to the start
			addCorrectNormalTriangle(meshSide, centerVertex, currentId, startingId, positiveSide) 
		end
	end
	
	fillIn(positive_mesh, outerRimPos, centerPosVertex, true)
	fillIn(negative_mesh, outerRimNeg, centerNegVertex, false)
	
	local positive_fixed_meshpart = AssetService:CreateEditableMeshAsync(Content.fromObject(positive_mesh), {FixedSize = true}) :: EditableMesh
	local negative_fixed_meshpart = AssetService:CreateEditableMeshAsync(Content.fromObject(negative_mesh), {FixedSize = true}) :: EditableMesh

	local positive_meshpart
	local negative_meshpart

	if has_positive then
		positive_meshpart = AssetService:CreateMeshPartAsync(Content.fromObject(positive_fixed_meshpart)) :: MeshPart
		positive_meshpart.Size = positive_meshpart.MeshSize * (MeshPart.Size / MeshPart.MeshSize)
		positive_meshpart.CustomPhysicalProperties = MeshPart.CustomPhysicalProperties
		positive_meshpart.EnableFluidForces = MeshPart.EnableFluidForces
		positive_meshpart.AudioCanCollide = MeshPart.AudioCanCollide
		positive_meshpart.CollisionGroup = MeshPart.CollisionGroup
		positive_meshpart.TextureContent = MeshPart.TextureContent
		positive_meshpart.Transparency = MeshPart.Transparency
		positive_meshpart.Reflectance = MeshPart.Reflectance
		positive_meshpart.CanCollide = MeshPart.CanCollide
		positive_meshpart.Anchored = MeshPart.Anchored
		positive_meshpart.CanQuery = MeshPart.CanQuery
		positive_meshpart.Massless = MeshPart.Massless
		positive_meshpart.Material = MeshPart.Material
		positive_meshpart.Locked = MeshPart.Locked
		positive_meshpart.CFrame = MeshPart.CFrame
		positive_meshpart.Color = MeshPart.Color
		positive_meshpart:ApplyMesh(positive_meshpart)
		positive_meshpart.Name = MeshPart.Name
	end

	if has_negative then
		negative_meshpart = AssetService:CreateMeshPartAsync(Content.fromObject(negative_fixed_meshpart)) :: MeshPart
		negative_meshpart.Size = negative_meshpart.MeshSize * (MeshPart.Size / MeshPart.MeshSize)
		negative_meshpart.CustomPhysicalProperties = MeshPart.CustomPhysicalProperties
		negative_meshpart.EnableFluidForces = MeshPart.EnableFluidForces
		negative_meshpart.AudioCanCollide = MeshPart.AudioCanCollide
		negative_meshpart.CollisionGroup = MeshPart.CollisionGroup
		negative_meshpart.TextureContent = MeshPart.TextureContent
		negative_meshpart.Transparency = MeshPart.Transparency
		negative_meshpart.Reflectance = MeshPart.Reflectance
		negative_meshpart.CanCollide = MeshPart.CanCollide
		negative_meshpart.Anchored = MeshPart.Anchored
		negative_meshpart.CanQuery = MeshPart.CanQuery
		negative_meshpart.Massless = MeshPart.Massless
		negative_meshpart.Material = MeshPart.Material
		negative_meshpart.Locked = MeshPart.Locked
		negative_meshpart.CFrame = MeshPart.CFrame
		negative_meshpart.Color = MeshPart.Color
		negative_meshpart:ApplyMesh(negative_meshpart)
		negative_meshpart.Name = MeshPart.Name
	end

	positive_mesh:Destroy()
	negative_mesh:Destroy()

	return positive_meshpart, negative_meshpart
end

function splitTriangle(triVerts: {Vector3}, planePoint: Vector3, planeNormal: Vector3, Positive: boolean)
	local dist, side, points = {}, {}, {}
	for i = 1, 3 do
		dist[i] = (triVerts[i] - planePoint):Dot(planeNormal)
		side[i] = if Positive then dist[i] >= 0 else dist[i] <= 0
	end

	for i = 1, 3 do
		local j = i % 3 + 1
		local p1, p2 = triVerts[i], triVerts[j]
		local d1, d2 = dist[i], dist[j]
		local s1, s2 = side[i], side[j]

		if s1 then
			table.insert(points, p1)
		end
		if s1 ~= s2 then
			local t = d1 / (d1 - d2)
			table.insert(points, p1:Lerp(p2, t))
		end
	end

	if #points == 3 then
		return {points}
	elseif #points == 4 then
		return {
			{points[1], points[2], points[3]},
			{points[1], points[3], points[4]}
		}
	end

	return {}
end

return MeshSplitter