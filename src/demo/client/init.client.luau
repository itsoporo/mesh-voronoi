-- Click demo, client side: asks the server to shatter what was clicked or to shell a
-- wall, shows the effects, and does the fracture itself when Settings.demoSide is
-- "client".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Voronoi = require(ReplicatedStorage:WaitForChild("Voronoi"))
local demo = ReplicatedStorage:WaitForChild("VoronoiDemo")
local Settings = require(demo:WaitForChild("Settings"))
local Shatter = require(demo:WaitForChild("Shatter"))
local Cannon = require(demo:WaitForChild("Cannon"))
local Effects = require(demo:WaitForChild("Effects"))
local WallSettings = require(demo:WaitForChild("WallSettings"))
local Breakable = require(ReplicatedStorage.Voronoi:WaitForChild("Breakable"))
local remote = ReplicatedStorage:WaitForChild("VoronoiDemoShatter") :: RemoteEvent
local shots = ReplicatedStorage:WaitForChild("VoronoiDemoShot") :: RemoteEvent

local config = Voronoi.Config.resolve(Settings)

local function request(x: number, y: number)
	local ray = (workspace.CurrentCamera :: Camera):ScreenPointToRay(x, y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = (Players.LocalPlayer :: Player).Character
	params.FilterDescendantsInstances = if character then { character } else {}
	local hit = workspace:Raycast(ray.Origin, ray.Direction * WallSettings.maxRange, params)
	if not hit then
		return
	end
	if Shatter.isValidTarget(hit.Instance, hit.Position) then
		remote:FireServer(hit.Instance, hit.Position)
		return
	end
	-- a wall, or a fragment of one; the shell leaves from just below and right of the view
	local root = Breakable.rootOf(hit.Instance) or hit.Instance
	local muzzle = (workspace.CurrentCamera :: Camera).CFrame:PointToWorldSpace(Vector3.new(2.5, -2, -4))
	local direction = (hit.Position - muzzle).Unit
	if Cannon.isValidShot(root, hit.Position, direction, muzzle) then
		shots:FireServer(root, hit.Position, direction, muzzle)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.UserInputType == Enum.UserInputType.MouseButton1 then
		request(input.Position.X, input.Position.Y)
	end
end)
UserInputService.TouchTapInWorld:Connect(function(position, processed)
	if not processed then
		request(position.X, position.Y)
	end
end)

-- `part` is nil when it has not streamed in here
remote.OnClientEvent:Connect(function(part: MeshPart?, localPoint: Vector3, seed: number)
	if config.demoSide == "client" and part then
		Shatter.run(part, part.CFrame:PointToWorldSpace(localPoint), seed, Settings)
	end
end)

-- `root` is nil when the wall has not streamed in here
shots.OnClientEvent:Connect(function(root: BasePart?, localPosition: Vector3, localDirection: Vector3, origin: Vector3, seed: number)
	if not root then
		return
	end
	local position = root.CFrame:PointToWorldSpace(localPosition)
	local direction = root.CFrame:VectorToWorldSpace(localDirection)
	local flight = Cannon.flightTime((position - origin).Magnitude, WallSettings)
	local color = root.Color
	Effects.shell(origin, position, flight)
	task.delay(flight, Effects.impact, position, direction, color)
	if config.demoSide == "client" then
		Cannon.fire(root, position, direction, seed, WallSettings, os.clock() + flight)
	end
end)

if config.demoSide == "client" then
	task.spawn(Shatter.preload, Settings)
	Shatter.preloadWalls(WallSettings)
end
