-- Demo logic shared by the client and server scripts: validate a click, swap a part
-- for its flying pieces, and put it back later.

local RunService = game:GetService("RunService")

-- the library sits beside this script's folder
local Voronoi = require(script.Parent.Parent:WaitForChild("Voronoi"))

local DEBRIS_NAME = "VoronoiDebris"

export type Handle = { result: Voronoi.Result, restore: () -> () }

local busy: { [Instance]: boolean } = {}

local Shatter = {}

local function items(): Instance?
	local map = workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Items")
end

-- True for a MeshPart in workspace.Map.Items clicked somewhere on or near itself.
-- Safe to call with whatever a client sends.
function Shatter.isValidTarget(part: any, point: any): boolean
	local folder = items()
	if not folder or typeof(part) ~= "Instance" or typeof(point) ~= "Vector3" then
		return false
	end
	if not part:IsA("MeshPart") or not part:IsDescendantOf(folder) then
		return false
	end
	-- false for NaN as well
	return (point - part.Position).Magnitude <= part.Size.Magnitude
end

-- Does the slow one-off work for every target, including ones that appear later.
function Shatter.preload(settings: { [string]: any })
	local folder = workspace:WaitForChild("Map"):WaitForChild("Items")
	local function warm(child: Instance)
		if child:IsA("MeshPart") then
			local ok, err = pcall(Voronoi.preload, child, settings)
			if not ok then
				warn(`Voronoi demo: preload of {child.Name} failed: {err}`)
			end
		end
	end
	folder.ChildAdded:Connect(warm)
	for _, child in folder:GetChildren() do
		warm(child)
	end
end

-- Starts the workers the walls will use.
function Shatter.preloadWalls(settings: { [string]: any })
	local folder = workspace:WaitForChild("Map"):WaitForChild("Walls", 10)
	local wall = folder and folder:FindFirstChildWhichIsA("BasePart")
	if wall then
		local ok, err = pcall(Voronoi.preload, wall, settings.breakable.fracture)
		if not ok then
			warn(`Voronoi demo: preload of {wall.Name} failed: {err}`)
		end
	end
end

local function debrisFolder(): Instance
	local folder = workspace:FindFirstChild(DEBRIS_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = DEBRIS_NAME
		folder.Parent = workspace
	end
	return folder :: Instance
end

local function fracture(part: MeshPart, point: Vector3, seed: number, settings: { [string]: any })
	local options = table.clone(settings)
	options.seed = seed
	options.distribution = options.distribution or "clustered"
	options.focus = point
	options.focusRadius = options.focusRadius or part.Size.Magnitude / 2
	local config = Voronoi.Config.resolve(options)
	local sites = Voronoi.Points.generate(part, options)
	return Voronoi.fracture(part, sites, options), config
end

-- Yields. Returns nil, leaving the part as it was, if it is already shattered, the
-- fracture fails, or the part disappears while it is being cut.
function Shatter.run(part: MeshPart, point: Vector3, seed: number, settings: { [string]: any }): Handle?
	if busy[part] then
		return nil
	end
	busy[part] = true

	local ok, result, config = pcall(fracture, part, point, seed, settings)
	if not ok then
		busy[part] = nil
		warn(`Voronoi demo: {result}`)
		return nil
	end
	if not part:IsDescendantOf(game) then
		busy[part] = nil
		result:destroy()
		return nil
	end

	local transparency, canCollide, canQuery = part.Transparency, part.CanCollide, part.CanQuery
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false

	local folder = debrisFolder()
	local serverSimulates = RunService:IsRunning() and RunService:IsServer()
	for _, piece in result.pieces do
		local body = piece.part
		body.Anchored = false
		body.Parent = folder
		if serverSimulates then
			-- keep the server in charge so ownership does not change mid-flight
			body:SetNetworkOwner(nil)
		end
		local away = body.Position - point
		local direction = (if away.Magnitude > 1e-3 then away.Unit else Vector3.yAxis) + Vector3.yAxis * config.upwardBias
		body:ApplyImpulse(direction * config.force * body.AssemblyMass)
	end

	local restored = false
	local function restore()
		if restored then
			return
		end
		restored = true
		result:destroy()
		part.Transparency = transparency
		part.CanCollide = canCollide
		part.CanQuery = canQuery
		busy[part] = nil
	end
	task.delay(config.resetAfter, restore)

	return { result = result, restore = restore }
end

return Shatter
