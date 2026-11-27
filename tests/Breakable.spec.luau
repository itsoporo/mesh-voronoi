-- Walls that take repeated hits.
return function(lib)
	local function load()
		return require(lib.Breakable)
	end

	local function newWall(): Part
		local part = Instance.new("Part")
		part.Name = "zzWall"
		part.Anchored = true
		part.Archivable = false
		part.Size = Vector3.new(30, 14, 2)
		part.CFrame = CFrame.new(200, 7, 0) * CFrame.Angles(0, math.rad(30), 0)
		part.Parent = workspace
		return part
	end

	local quiet = {
		holeRadius = 2.5,
		maxHits = 20,
		collapseBelow = 0.05,
		maxFragments = 1000,
		minFragmentVolume = 0.4,
		debrisLifetime = 60,
		maxDebris = 1000,
		rebuildAfter = false,
		fracture = { workers = 0 },
	}

	local function with(extra)
		local settings = table.clone(quiet)
		for key, value in extra or {} do
			settings[key] = value
		end
		return settings
	end

	local function test(extra, body)
		return function()
			local Breakable = load()
			local part = newWall()
			local wall = Breakable.new(part, with(extra))
			local ok, err = pcall(body, wall, part, Breakable)
			wall:destroy()
			part:Destroy()
			assert(ok, err)
		end
	end

	-- a point on the front face, in wall-local studs
	local function face(part: BasePart, x: number, y: number): (Vector3, Vector3)
		return part.CFrame:PointToWorldSpace(Vector3.new(x, y, -1)), part.CFrame:VectorToWorldSpace(Vector3.zAxis)
	end

	local function solidAt(wall, part: BasePart, x: number, y: number): boolean
		local point, direction = face(part, x, y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		local standing = {}
		for _, fragment in wall:fragments() do
			table.insert(standing, fragment)
		end
		params.FilterDescendantsInstances = standing
		return workspace:Raycast(point - direction * 3, direction * 8, params) ~= nil
	end

	local function volumes(wall): (number, number)
		local total, smallest = 0, math.huge
		for _, part in wall:fragments() do
			local volume = wall:volumeOf(part)
			total += volume
			smallest = math.min(smallest, volume)
		end
		return total, smallest
	end

	return {
		hole_sites = function()
			local Breakable = load()
			local part = newWall()
			local impact = face(part, 4, 1)
			local sites, flies = Breakable.holeSites(part.CFrame, part.Size, impact, 3, 11)
			local again = Breakable.holeSites(part.CFrame, part.Size, impact, 3, 11)
			local flying, staying = 0, 0
			for i, site in sites do
				local localSite = part.CFrame:PointToObjectSpace(site)
				local planar = Vector2.new(localSite.X - 4, localSite.Y - 1).Magnitude
				assert(math.abs(localSite.Z) <= 0.7, `site off the wall: {localSite}`)
				assert(flies[i] == (planar < 3), `site {i} at {planar}`)
				assert(again[i] == site, "not deterministic")
				if flies[i] then
					flying += 1
				else
					staying += 1
				end
			end
			part:Destroy()
			assert(flying >= 6 and staying >= 8, `{flying} flying, {staying} staying`)
		end,

		supported_pieces = function()
			local Breakable = load()
			local function box(x0, y0, x1, y1)
				return { min = Vector3.new(x0, y0, -1), max = Vector3.new(x1, y1, 1) }
			end
			local standing = Breakable.supported({
				box(0, 0, 2, 2), -- on the ground
				box(0, 2, 2, 4), -- on top of 1
				box(5, 3, 7, 5), -- floating
				box(5, 5, 7, 6), -- resting only on the floating one
			}, 0)
			assert(standing[1] and standing[2] and not standing[3] and not standing[4])
		end,

		first_hit_makes_a_hole = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			local report = wall:hit(point, direction, 3)
			assert(report and report.flying > 0 and not report.collapsed)
			assert(report.seconds > 0 and report.seconds < 30, `seconds {report.seconds}`)
			assert(part.Transparency == 1 and not part.CanCollide and not part.CanQuery)
			assert(not solidAt(wall, part, 0, 0), "no hole")
			assert(solidAt(wall, part, 12, 0) and solidAt(wall, part, -12, -4), "the rest should stand")
			for _, fragment in wall:fragments() do
				assert(fragment.Anchored and wall.rootOf(fragment) == part)
			end
			local standing = volumes(wall)
			assert(standing < 840 and standing > 840 * 0.6, `standing volume {standing}`)
		end),

		holes_stack = test(nil, function(wall, part)
			for i, x in { -8, 8, 0 } do
				local point, direction = face(part, x, 0)
				assert(wall:hit(point, direction, i))
			end
			assert(wall.hits == 3)
			for _, x in { -8, 8, 0 } do
				assert(not solidAt(wall, part, x, 0), `hole at {x} missing`)
			end
		end),

		shot_through_a_hole_does_nothing = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local before = #wall:fragments()
			assert(wall:hit(point, direction, 1) == nil or #wall:fragments() <= before)
		end),

		no_slivers_left_standing = test(nil, function(wall, part)
			for i = 1, 6 do
				local point, direction = face(part, -9 + i * 2.5, (i % 3) - 1)
				wall:hit(point, direction, i)
			end
			local _, smallest = volumes(wall)
			assert(smallest >= 0.4, `a fragment of {smallest} studs³ was left`)
		end),

		-- a hit that touches many fragments cuts them side by side, not a frame apiece
		many_fragments_cut_together = test({ fracture = { workers = 0, frameBudgetMs = 1000 } }, function(wall, part)
			for i, x in { -6, 6 } do
				local point, direction = face(part, x, 0)
				wall:hit(point, direction, i)
			end
			local frames = 0
			local connection = game:GetService("RunService").Heartbeat:Connect(function()
				frames += 1
			end)
			wall.settings.holeRadius = 5 -- reach the rubble around both holes
			local point, direction = face(part, 0, -4)
			local report = wall:hit(point, direction, 3)
			connection:Disconnect()
			assert(report and report.targets >= 5, `only {report and report.targets} fragments touched`)
			assert(frames <= 3, `{frames} frames for {report.targets} fragments`)
		end),

		-- repeated damage must not pile up fragments or triangles
		repeat_hits_stay_light = test({ fracture = { workers = 0, simplify = true, frameBudgetMs = 1000 } }, function(wall, part)
			for i, x in { -6, -2, 2, 6, -4, 0, 4 } do
				local point, direction = face(part, x, if i % 2 == 0 then 2 else -2)
				wall:hit(point, direction, i)
			end
			local standing = wall:fragments()
			local triangles = 0
			for _, fragment in standing do
				triangles += wall:trianglesOf(fragment)
			end
			assert(#standing > 0 and #standing <= 50, `{#standing} fragments standing`)
			assert(triangles / #standing <= 60, `{triangles / #standing} triangles per fragment`)
		end),

		collapses_after_max_hits = test({ maxHits = 3 }, function(wall, part)
			local reports = {}
			for i, x in { -9, 0, 9 } do
				local point, direction = face(part, x, 0)
				reports[i] = wall:hit(point, direction, i)
			end
			assert(not reports[1].collapsed and not reports[2].collapsed and reports[3].collapsed)
			assert(wall.collapsed and #wall:fragments() == 0, "fragments left standing")
			assert(part.Transparency == 1)
			local point, direction = face(part, 4, 0)
			assert(wall:hit(point, direction, 9) == nil)
		end),

		collapses_when_little_remains = test({ collapseBelow = 0.9, holeRadius = 4 }, function(wall, part)
			local point, direction = face(part, 0, 0)
			assert(wall:hit(point, direction, 1).collapsed)
			assert(#wall:fragments() == 0)
		end),

		collapses_when_too_fragmented = test({ maxFragments = 5 }, function(wall, part)
			local point, direction = face(part, 0, 0)
			assert(wall:hit(point, direction, 1).collapsed)
		end),

		reset_rebuilds = test({ maxHits = 1 }, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			wall:reset()
			assert(part.Transparency == 0 and part.CanCollide and part.CanQuery)
			assert(wall.hits == 0 and not wall.collapsed and #wall:fragments() == 0 and wall:debrisCount() == 0)
			assert(wall:hit(point, direction, 2), "cannot be hit after reset")
		end),

		rebuilds_after_quiet = test({ rebuildAfter = 0.3 }, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			assert(part.Transparency == 1)
			task.wait(0.8)
			assert(part.Transparency == 0 and wall.hits == 0)
		end),

		debris_is_capped = test({ maxDebris = 5 }, function(wall, part, Breakable)
			for i, x in { -8, 0, 8 } do
				local point, direction = face(part, x, 0)
				wall:hit(point, direction, i)
				assert(Breakable.debrisCount() <= 5, `{Breakable.debrisCount()} debris pieces`)
			end
		end),

		debris_despawns = test({ debrisLifetime = 0.2 }, function(wall, part, Breakable)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			assert(wall:debrisCount() > 0)
			task.wait(1)
			assert(wall:debrisCount() == 0, `{wall:debrisCount()} left`)
		end),

		overlapping_hits_both_apply = test(nil, function(wall, part)
			local finished = 0
			for i, x in { -7, 7 } do
				task.spawn(function()
					local point, direction = face(part, x, 0)
					wall:hit(point, direction, i)
					finished += 1
				end)
			end
			local started = os.clock()
			while finished < 2 and os.clock() - started < 15 do
				task.wait()
			end
			assert(wall.hits == 2)
			assert(not solidAt(wall, part, -7, 0) and not solidAt(wall, part, 7, 0))
		end),

		reset_during_a_hit_is_safe = test(nil, function(wall, part)
			local done = false
			task.spawn(function()
				local point, direction = face(part, 0, 0)
				wall:hit(point, direction, 1, os.clock() + 0.5)
				done = true
			end)
			wall:reset()
			local started = os.clock()
			while not done and os.clock() - started < 10 do
				task.wait()
			end
			assert(done and part.Transparency == 0 and #wall:fragments() == 0 and wall:debrisCount() == 0)
		end),
	}
end
