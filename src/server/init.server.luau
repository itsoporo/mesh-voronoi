local MeshSplitter = require(script.MeshSplitter)

local plane = workspace.Plane

local items = workspace.Map.Items:GetChildren()

local function sliceObject(Object: MeshPart)

	local positiveMeshpart, negativeMeshpart = MeshSplitter:SplitMesh(Object, plane.CFrame)

	if positiveMeshpart then
		positiveMeshpart.Parent = workspace.Map.Items
		positiveMeshpart.Color = Color3.new(0.223529, 0.494118, 1)
		positiveMeshpart.Anchored = false
	end

	if negativeMeshpart then
		negativeMeshpart.Parent = workspace.Map.Items
		negativeMeshpart.Color = Color3.new(1, 0.262745, 0.262745)
		negativeMeshpart.Anchored = false
	end
	
	Object:Destroy()
end

for _, item in items do
	task.spawn(sliceObject, item)
end

--if plane then plane:Destroy() end