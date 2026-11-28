-- Turns cell meshes into MeshParts. Serial only; yields.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local Budget = require(script.Parent.Budget)
local Config = require(script.Parent.Config)
local MeshData = require(script.Parent.Geometry.MeshData)

type MeshData = MeshData.MeshData
export type Cell = { siteIndex: number, site: Vector3, mesh: MeshData }
export type Piece = {
	part: MeshPart,
	siteIndex: number,
	site: Vector3,
	center: Vector3,
	mesh: MeshData, -- the part's geometry, centred on it, so it can be cut again
	volume: number, -- cubic studs
	destroy: () -> (), -- removes this piece alone and frees its editable mesh
}

local MAX_VERTICES = 60000
local MAX_TRIANGLES = 20000
local MIN_EXTENT = 0.001 -- smallest MeshPart axis
local MIN_VOLUME = 1e-6

-- A client's editable memory budget holds only a handful of resizable meshes, so
-- they are shared between every build running in this VM.
local CLIENT_DYNAMIC_LIMIT = 4
local dynamicAlive = 0

local COPIED_PROPERTIES = {
	"Color",
	"Material",
	"MaterialVariant",
	"Transparency",
	"Reflectance",
	"CanCollide",
	"CanTouch",
	"CanQuery",
	"Anchored",
	"Massless",
	"CustomPhysicalProperties",
	"CollisionGroup",
	"CastShadow",
	"TextureContent",
	"DoubleSided",
	"EnableFluidForces",
	"AudioCanCollide",
}

local PartBuilder = {}

-- The one place resizable meshes come from.
function PartBuilder.createMesh(): EditableMesh?
	return AssetService:CreateEditableMesh()
end

local function copyProperties(source: BasePart, part: MeshPart)
	for _, property in COPIED_PROPERTIES do
		-- some are not writable from every context
		pcall(function()
			(part :: any)[property] = (source :: any)[property]
		end)
	end
	for _, child in source:GetChildren() do
		if child:IsA("SurfaceAppearance") then
			child:Clone().Parent = part
		end
	end
end

-- Adds each distinct value once and returns the id for every element of `values`.
local function addAttributes(editable: EditableMesh, attribute: Enum.MeshAttribute, values: { any }, keyOf: (any) -> any): { number }
	local slots: { [any]: number } = {}
	local unique = {}
	local slot = table.create(#values, 0)
	for i, value in values do
		local key = keyOf(value)
		local found = slots[key]
		if not found then
			table.insert(unique, value)
			found = #unique
			slots[key] = found
		end
		slot[i] = found :: number
	end
	local ids = (editable :: any):BatchAdd(attribute, unique)
	local out = table.create(#values, 0)
	for i, index in slot do
		out[i] = ids[index]
	end
	return out
end

local function triples(ids: { number }): { { number } }
	local out = table.create(#ids / 3)
	for first = 1, #ids, 3 do
		table.insert(out, { ids[first], ids[first + 1], ids[first + 2] })
	end
	return out
end

local function centred(mesh: MeshData, center: Vector3): MeshData
	local positions = table.create(#mesh.positions)
	for i, p in mesh.positions do
		positions[i] = p - center
	end
	return { positions = positions, tris = mesh.tris, normals = mesh.normals, uvs = mesh.uvs, caps = mesh.caps }
end

local function fill(editable: EditableMesh, mesh: MeshData, capColor: Color3?)
	local mutable = editable :: any
	local vertexIds = mutable:BatchAdd(Enum.MeshAttribute.Vertex, mesh.positions)

	local corners = table.create(#mesh.tris, 0)
	for i, index in mesh.tris do
		corners[i] = vertexIds[index]
	end
	local faceIds = mutable:BatchAdd(Enum.MeshAttribute.Face, triples(corners))

	local normalIds = addAttributes(editable, Enum.MeshAttribute.Normal, mesh.normals, function(n)
		return n
	end)
	mutable:BatchSetFaceAttributes(faceIds, triples(normalIds))
	local uvIds = addAttributes(editable, Enum.MeshAttribute.UV, mesh.uvs, function(uv)
		return `{uv.X},{uv.Y}`
	end)
	mutable:BatchSetFaceAttributes(faceIds, triples(uvIds))

	if capColor then
		local ids = mutable:BatchAdd(Enum.MeshAttribute.Color, { Color3.new(1, 1, 1), capColor }, { 1, 1 })
		local faceColors = table.create(#faceIds)
		for i, isCap in mesh.caps do
			local id = ids[if isCap then 2 else 1]
			faceColors[i] = { id, id, id }
		end
		mutable:BatchSetFaceAttributes(faceIds, faceColors)
	end
	mutable:RemoveUnused()
end

function PartBuilder.build(source: BasePart, cells: { Cell }, config: Config.Config): ({ Piece }, () -> (), { string })
	-- server content must be opaque to reach clients; clients link fixed-size copies,
	-- which are several times quicker to make
	local onServer = RunService:IsRunning() and RunService:IsServer()
	local limit = if onServer or not RunService:IsRunning() then math.huge else CLIENT_DYNAMIC_LIMIT

	local warnings: { string } = {}
	local jobs = {}
	for _, cell in cells do
		local low, high = MeshData.bounds(cell.mesh)
		local extent = high - low
		if math.min(extent.X, extent.Y, extent.Z) < MIN_EXTENT or math.abs(MeshData.volume(cell.mesh)) < MIN_VOLUME then
			table.insert(warnings, `skipped a sliver piece of cell {cell.siteIndex}`)
			continue
		end
		local triangles = #cell.mesh.tris / 3
		if triangles > MAX_TRIANGLES or #cell.mesh.positions > MAX_VERTICES then
			error(`Voronoi: cell {cell.siteIndex} has {triangles} triangles; the limit is {MAX_TRIANGLES} triangles and {MAX_VERTICES} vertices`, 0)
		end
		local center = (low + high) / 2
		table.insert(jobs, { cell = cell, center = center, mesh = centred(cell.mesh, center) })
	end

	local parts: { [number]: MeshPart } = {}
	local linked: { [any]: EditableMesh } = {} -- fixed-size mesh each part displays, by job
	local failure: string? = nil
	local finished = 0
	local destroyed = false

	local function destroy()
		destroyed = true
		for _, part in parts do
			part:Destroy()
		end
		for _, editable in linked do
			editable:Destroy()
		end
		table.clear(linked)
	end

	local function opaqueContent(dynamic: EditableMesh): Content
		local status, content = AssetService:CreateDataModelContentAsync(Content.fromObject(dynamic))
		assert(status == Enum.CreateContentResult.Success, `could not store mesh content: {status}`)
		return content
	end

	-- A resizable mesh to fill, waiting while other builds are using the budget.
	local function acquire(): EditableMesh
		while true do
			while dynamicAlive >= limit and not failure do
				task.wait()
			end
			if failure then
				error(failure, 0)
			end
			dynamicAlive += 1
			-- the slot must be returned even if creation raises, or later builds wait forever
			local ok, dynamic = pcall(PartBuilder.createMesh)
			if ok and dynamic then
				return dynamic
			end
			dynamicAlive -= 1
			if not ok then
				error(dynamic, 0)
			end
			if dynamicAlive == 0 then
				error("out of editable mesh memory", 0)
			end
			task.wait()
		end
	end

	local function makeContent(job): Content
		-- spread the filling work over frames
		Budget.checkpoint(config.frameBudgetMs)
		local dynamic = acquire()
		local ok, result = pcall(function(): Content
			fill(dynamic, job.mesh, config.capColor)
			if onServer or config.meshContent == "opaque" then
				return opaqueContent(dynamic)
			end
			local copied, fixed = pcall(function()
				return AssetService:CreateEditableMeshAsync(Content.fromObject(dynamic), { FixedSize = true })
			end)
			if copied and fixed then
				linked[job] = fixed
				return Content.fromObject(fixed)
			end
			-- no room for another editable copy: opaque content needs none
			return opaqueContent(dynamic)
		end)
		dynamic:Destroy()
		dynamicAlive -= 1
		if not ok then
			error(result, 0)
		end
		return result
	end

	for i, job in jobs do
		task.spawn(function()
			local ok, err = pcall(function()
				local part = AssetService:CreateMeshPartAsync(makeContent(job), {
					CollisionFidelity = config.collisionFidelity,
					RenderFidelity = config.renderFidelity,
				})
				copyProperties(source, part)
				part.CFrame = source.CFrame * CFrame.new(job.center)
				parts[i] = part
			end)
			if not ok then
				failure = failure or tostring(err)
			end
			finished += 1
		end)
	end
	while finished < #jobs do
		task.wait()
	end

	if failure then
		destroy()
		error(`Voronoi: building pieces failed: {failure}`, 0)
	end

	local pieces: { Piece } = {}
	for i, job in jobs do
		local part = parts[i]
		part.Name = `{source.Name}_{i}`
		local released = false
		table.insert(pieces, {
			part = part,
			siteIndex = job.cell.siteIndex,
			site = job.cell.site,
			center = job.center,
			mesh = job.mesh,
			volume = math.abs(MeshData.volume(job.mesh)),
			destroy = function()
				if released or destroyed then
					return
				end
				released = true
				parts[i] = nil
				part:Destroy()
				if linked[job] then
					linked[job]:Destroy()
					linked[job] = nil
				end
			end,
		})
	end

	return pieces, function()
		if not destroyed then
			destroy()
		end
	end, warnings
end

return PartBuilder
