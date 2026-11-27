-- The demo's shared logic: which requests are accepted, and what shattering does.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(lib)
	-- a copy of the demo beside the fresh library copy, so neither is a stale cache
	local demo = ReplicatedStorage.VoronoiDemo:Clone()
	demo.Parent = lib.Parent

	local function load()
		return require(demo.Shatter), require(demo.Settings)
	end

	local items = workspace.Map.Items
	local settings = { workers = 0, count = 6, resetAfter = 60 }

	-- a throwaway target beside the real one
	local function target(): MeshPart
		local part = items.default:Clone()
		part.Name = "zzDemoTarget"
		part.Archivable = false
		part.CFrame += Vector3.new(0, 60, 0)
		part.Parent = items
		return part
	end

	local function debris(): number
		local folder = workspace:FindFirstChild("VoronoiDebris")
		return if folder then #folder:GetChildren() else 0
	end

	local function withTarget(body)
		local part = target()
		local ok, err = pcall(body, part)
		part:Destroy()
		local folder = workspace:FindFirstChild("VoronoiDebris")
		if folder and #folder:GetChildren() == 0 then
			folder:Destroy()
		end
		assert(ok, err)
	end

	local function cannon()
		return require(demo.Cannon), require(demo.WallSettings)
	end

	local function withWall(body)
		local walls = workspace.Map:FindFirstChild("Walls")
		local part = Instance.new("Part")
		part.Name = "zzDemoWall"
		part.Archivable = false
		part.Anchored = true
		part.Size = Vector3.new(20, 10, 2)
		part.CFrame = CFrame.new(150, 5, 100) * CFrame.Angles(0, 0.7, 0)
		part.Parent = walls
		local ok, err = pcall(body, part)
		part:Destroy()
		for _, name in { "VoronoiWalls", "VoronoiDebris" } do
			local folder = workspace:FindFirstChild(name)
			if folder and #folder:GetChildren() == 0 then
				folder:Destroy()
			end
		end
		assert(ok, err)
	end

	return {
		accepts_only_sensible_shots = function()
			local Cannon = cannon()
			withWall(function(wall)
				local position = wall.CFrame:PointToWorldSpace(Vector3.new(3, 1, -1))
				local direction = wall.CFrame:VectorToWorldSpace(Vector3.zAxis)
				local origin = position - direction * 60
				assert(Cannon.isValidShot(wall, position, direction, origin))
				local nan = Vector3.new(0 / 0, 0, 0)
				assert(not Cannon.isValidShot(wall, position + Vector3.new(0, 30, 0), direction, origin), "off the wall")
				assert(not Cannon.isValidShot(wall, nan, direction, origin))
				assert(not Cannon.isValidShot(wall, position, nan, origin))
				assert(not Cannon.isValidShot(wall, position, Vector3.zero, origin))
				assert(not Cannon.isValidShot(wall, position, direction * 50, origin))
				assert(not Cannon.isValidShot(wall, position, direction, nan))
				assert(not Cannon.isValidShot(wall, position, direction, position + Vector3.new(1e6, 0, 0)))
				assert(not Cannon.isValidShot(nil, position, direction, origin))
				assert(not Cannon.isValidShot("wall", position, direction, origin))
				assert(not Cannon.isValidShot(items.default, items.default.Position, direction, origin), "not a wall")
				assert(not Cannon.isValidShot(wall, 5, direction, origin))
			end)
		end,
		flight_time_is_bounded = function()
			local Cannon, Settings = cannon()
			assert(Cannon.flightTime(0, Settings) >= 0.04)
			assert(Cannon.flightTime(1e6, Settings) <= 0.5)
			assert(Cannon.flightTime(90, Settings) < Cannon.flightTime(150, Settings))
		end,
		wall_settings_are_valid = function()
			local _, Settings = cannon()
			local Breakable = require(lib.Breakable)
			local part = Instance.new("Part")
			Breakable.new(part, Settings.breakable):destroy()
			require(lib.Config).resolve(Settings.breakable.fracture)
		end,
		firing_damages_the_wall = function()
			local Cannon, Settings = cannon()
			withWall(function(wall)
				local quiet = table.clone(Settings)
				quiet.breakable = table.clone(Settings.breakable)
				quiet.breakable.fracture = { workers = 0 }
				quiet.breakable.rebuildAfter = false
				local position = wall.CFrame:PointToWorldSpace(Vector3.new(0, 0, -1))
				local report = Cannon.fire(wall, position, wall.CFrame.LookVector * -1, 4, quiet)
				assert(report and report.flying > 0 and wall.Transparency == 1)
				require(lib.Breakable).get(wall):destroy()
				assert(wall.Transparency == 0)
			end)
		end,
		settings_are_valid_config = function()
			local _, Settings = load()
			require(lib.Config).resolve(Settings)
		end,
		accepts_only_nearby_clicks_on_targets = function()
			local Shatter = load()
			withTarget(function(part)
				assert(Shatter.isValidTarget(part, part.Position))
				assert(not Shatter.isValidTarget(part, part.Position + Vector3.new(500, 0, 0)))
				assert(not Shatter.isValidTarget(part, Vector3.new(0 / 0, 0, 0)))
				assert(not Shatter.isValidTarget(part, "here"))
				assert(not Shatter.isValidTarget(nil, part.Position))
				assert(not Shatter.isValidTarget("part", part.Position))
				assert(not Shatter.isValidTarget(workspace.Map.Environment.Ground, Vector3.zero))
				local outside = items.default:Clone() -- the throwaway target cannot be cloned
				outside.Parent = workspace
				local accepted = Shatter.isValidTarget(outside, outside.Position)
				outside:Destroy()
				assert(not accepted, "mesh outside Map.Items accepted")
			end)
		end,
		shatters_then_restores = function()
			local Shatter = load()
			withTarget(function(part)
				part.Transparency = 0.2
				local before = debris()
				local handle = Shatter.run(part, part.Position, 5, settings)
				assert(handle, "did not shatter")
				assert(part.Transparency == 1 and not part.CanCollide and not part.CanQuery, "original still there")
				assert(debris() > before, "no debris")
				for _, piece in handle.result.pieces do
					assert(not piece.part.Anchored and piece.part.Parent == workspace.VoronoiDebris)
				end
				assert(Shatter.run(part, part.Position, 6, settings) == nil, "shattered twice")
				handle.restore()
				handle.restore()
				assert(math.abs(part.Transparency - 0.2) < 1e-5 and part.CanCollide and part.CanQuery, "not restored")
				assert(debris() == before, "debris left")
				local again = Shatter.run(part, part.Position, 7, settings)
				assert(again, "cannot shatter after reset")
				again.restore()
			end)
		end,
		failure_leaves_part_alone = function()
			local Shatter = load()
			withTarget(function(part)
				local before = debris()
				local handle = Shatter.run(part, part.Position, 1, { workers = 0, count = 0 })
				assert(handle == nil)
				assert(part.Transparency == 0 and part.CanCollide and part.CanQuery and debris() == before)
				local retry = Shatter.run(part, part.Position, 1, settings)
				assert(retry, "stayed locked after a failure")
				retry.restore()
			end)
		end,
		part_removed_during_fracture = function()
			local Shatter = load()
			require(lib.MeshReader).clearCache() -- force the read to yield
			withTarget(function(part)
				local before = debris()
				local finished, handle = false, nil
				task.spawn(function()
					handle = Shatter.run(part, part.Position, 1, settings)
					finished = true
				end)
				assert(not finished, "fracture did not yield; the test proves nothing")
				part.Parent = nil
				local started = os.clock()
				while not finished and os.clock() - started < 10 do
					task.wait()
				end
				assert(finished and handle == nil and debris() == before)
			end)
		end,
	}
end
