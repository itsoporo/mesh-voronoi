-- Click demo, server side: checks click requests, then either fractures for everyone
-- or tells every client to fracture, depending on Settings.demoSide. Handles both the
-- Suzannes (shatter) and the walls (shells punch holes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Voronoi = require(ReplicatedStorage:WaitForChild("Voronoi"))
local demo = ReplicatedStorage:WaitForChild("VoronoiDemo")
local Settings = require(demo:WaitForChild("Settings"))
local Shatter = require(demo:WaitForChild("Shatter"))
local Cannon = require(demo:WaitForChild("Cannon"))
local WallSettings = require(demo:WaitForChild("WallSettings"))

local config = Voronoi.Config.resolve(Settings)

local remote = Instance.new("RemoteEvent")
remote.Name = "VoronoiDemoShatter"
remote.Parent = ReplicatedStorage

local shots = Instance.new("RemoteEvent")
shots.Name = "VoronoiDemoShot"
shots.Parent = ReplicatedStorage

local SHOT_INTERVAL = 0.15 -- seconds between one player's shots

local locked: { [Instance]: boolean } = {}
local lastShot: { [Player]: number } = {}
local random = Random.new()

game:GetService("Players").PlayerRemoving:Connect(function(player)
	lastShot[player] = nil
end)

shots.OnServerEvent:Connect(function(player: Player, root: any, position: any, direction: any, origin: any)
	if not Cannon.isValidShot(root, position, direction, origin) then
		return
	end
	local now = os.clock()
	if now - (lastShot[player] or 0) < SHOT_INTERVAL then
		return
	end
	lastShot[player] = now

	local seed = random:NextInteger(1, 2 ^ 31 - 1)
	direction = direction.Unit
	-- positions travel relative to the wall, which may be moving on the client
	shots:FireAllClients(
		root,
		root.CFrame:PointToObjectSpace(position),
		root.CFrame:VectorToObjectSpace(direction),
		origin,
		seed
	)
	if config.demoSide == "server" then
		local flight = Cannon.flightTime((position - origin).Magnitude, WallSettings)
		Cannon.fire(root, position, direction, seed, WallSettings, now + flight)
	end
end)

remote.OnServerEvent:Connect(function(_player: Player, part: any, point: any)
	if not Shatter.isValidTarget(part, point) or locked[part] then
		return
	end
	locked[part] = true
	task.delay(config.resetAfter + 1, function()
		locked[part] = nil
	end)

	local seed = random:NextInteger(1, 2 ^ 31 - 1)
	if config.demoSide == "server" then
		Shatter.run(part, point, seed, Settings)
	else
		remote:FireAllClients(part, part.CFrame:PointToObjectSpace(point), seed)
	end
end)

if config.demoSide == "server" then
	Shatter.preload(Settings)
	Shatter.preloadWalls(WallSettings)
end
