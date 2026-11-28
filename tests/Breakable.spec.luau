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

	-- eleven sites: what flies, and the ring just outside that bounds the hole
	local RINGS = {
		{ distance = 0, count = 1, flies = true },
		{ distance = 0.8, count = 3, flies = true },
		{ distance = 1.3, count = 5, flies = false },
		{ distance = 2.8, count = 2, flies = false },
	}

	return {
		custom_rings = function()
			local Breakable = load()
			local sites, flies = Breakable.holeSites(CFrame.new(), Vector3.new(30, 14, 2), Vector3.new(0, 0, -1), 3.5, 7, RINGS)
			local flying = 0
			for _, f in flies do
				if f then
					flying += 1
				end
			end
			assert(#sites == 11 and flying == 4, `{#sites} sites, {flying} flying`)
		end,

		ring_setting_is_used = test({ rings = RINGS, holeRadius = 3.5 }, function(wall, part)
			local point, direction = face(part, 0, 0)
			local report = wall:hit(point, direction, 1)
			assert(report.flying + report.standing + report.dropped <= 13, "more pieces than 11 sites make")
		end),

		radius_per_hit = function()
			local left = {}
			for i, radius in { 3, 6 } do
				test(nil, function(wall, part)
					local point, direction = face(part, 0, 0)
					wall:hit(point, direction, 5, nil, radius)
					left[i] = volumes(wall)
				end)()
			end
			assert(left[2] < left[1] - 20, `{left[1]} then {left[2]}`)
		end,

		collapse_throws_everything = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local standing = #wall:fragments()
			assert(wall:collapse() == standing and #wall:fragments() == 0 and wall.collapsed)
			assert(part.Transparency == 1 and wall:hit(point, direction, 2) == nil)
			wall:reset()
			assert(part.Transparency == 0 and part.CanCollide and not wall.collapsed)
		end),

		collapse_untouched = test(nil, function(wall, part)
			assert(wall:collapse() == 0 and wall.collapsed)
			assert(part.Transparency == 1 and not part.CanCollide and not part.CanQuery)
			wall:reset()
			assert(part.Transparency == 0 and part.CanCollide and part.CanQuery)
		end),

		collapse_during_a_hit = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			local report, done = "unset", false
			task.spawn(function()
				report = wall:hit(point, direction, 1, os.clock() + 0.5)
				done = true
			end)
			wall:collapse()
			local started = os.clock()
			while not done and os.clock() - started < 10 do
				task.wait()
			end
			assert(done and report == nil and #wall:fragments() == 0 and wall.collapsed)
		end),

		-- walls one behind the other take one hole when they are cut with the same sites
		layers_share_a_layout = test(nil, function(front, part, Breakable)
			local other = newWall()
			other.CFrame = part.CFrame * CFrame.new(0, 0, 2.1) * CFrame.Angles(0, math.pi, 0)
			local back = Breakable.new(other, with())
			local ok, err = pcall(function()
				local point, direction = face(part, 1, 0.5)
				local sites, flies = Breakable.holeSites(part.CFrame, part.Size, point, 4, 9)
				-- all sites in one plane cut straight through, so both layers show the same outline
				for i, site in sites do
					local at = part.CFrame:PointToObjectSpace(site)
					sites[i] = part.CFrame:PointToWorldSpace(Vector3.new(at.X, at.Y, 0))
				end
				local layout = { sites = sites, flies = flies }
				front:hit(point, direction, 9, nil, 4, layout)
				back:hit(point + direction * 2.1, direction, 9, nil, 4, layout)
				local function open(wall, x, y): boolean
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Include
					params.FilterDescendantsInstances = wall:fragments()
					local from = part.CFrame:PointToWorldSpace(Vector3.new(x, y, -4))
					return workspace:Raycast(from, direction * 12, params) == nil
				end
				local differ, holes = 0, 0
				for x = -6, 8 do
					for y = -6, 6 do
						local a, b = open(front, x + 0.13, y + 0.17), open(back, x + 0.13, y + 0.17)
						holes += if a then 1 else 0
						differ += if a ~= b then 1 else 0
					end
				end
				assert(holes > 20 and differ <= 2, `{holes} open points, {differ} differ between the layers`)
			end)
			back:destroy()
			other:Destroy()
			assert(ok, err)
		end),

		-- a layout says where the hole is, so a part the shot line misses still loses what the hole covers
		layout_cuts_beside_the_shot = test(nil, function(wall, part, Breakable)
			wall:hit((face(part, -8, 0)), part.CFrame.LookVector * -1, 1)
			local point, direction = face(part, 16, 0) -- one stud past the end of the wall
			local sites, flies = Breakable.holeSites(part.CFrame, part.Size, point, 4, 3)
			local report = wall:hit(point, direction, 3, nil, 4, { sites = sites, flies = flies })
			assert(report and report.flying > 0, "nothing was cut")
			assert(not solidAt(wall, part, 14.2, 0.1), "the end of the wall still stands")
		end),

		attached_fragments_follow_the_root = test({ attach = true }, function(wall, part)
			part.Anchored = false
			for i, x in { -6, 6 } do
				local point, direction = face(part, x, 0)
				wall:hit(point, direction, i)
			end
			local before = {}
			for _, fragment in wall:fragments() do
				local weld = fragment:FindFirstChildOfClass("WeldConstraint")
				assert(weld and weld.Part0 == part and weld.Part1 == fragment, "not welded to the wall")
				assert(not fragment.Anchored and fragment.Massless)
				before[fragment] = fragment.Position
			end
			assert(next(before), "nothing stands")
			for _, loose in workspace.VoronoiDebris:GetChildren() do
				assert(not loose:FindFirstChildOfClass("WeldConstraint"), "debris is still welded")
			end
			part.CFrame += Vector3.new(0, 10, 0)
			for fragment, position in before do
				local moved = fragment.Position - position
				assert((moved - Vector3.new(0, 10, 0)).Magnitude < 0.01, `fragment moved {moved}`)
			end
			local standing = wall:fragments()
			wall:collapse()
			for _, fragment in standing do
				assert(not fragment:FindFirstChildOfClass("WeldConstraint"), "collapsed pieces are still welded")
			end
		end),

		wall_that_moves_during_a_cut = test({ attach = true }, function(wall, part)
			part.Anchored = false
			for hit, x in { -6, 6 } do
				local point, direction = face(part, x, 0)
				local done = false
				task.spawn(function()
					wall:hit(point, direction, hit, os.clock() + 0.4)
					done = true
				end)
				task.wait(0.1)
				part.CFrame += Vector3.new(0, 20, 0)
				local started = os.clock()
				while not done and os.clock() - started < 10 do
					task.wait()
				end
				for _, fragment in wall:fragments() do
					local at = part.CFrame:PointToObjectSpace(fragment.Position)
					assert(math.abs(at.X) <= 15 and math.abs(at.Y) <= 7 and math.abs(at.Z) <= 1, `hit {hit}: left behind at {at}`)
				end
			end
		end),

		-- whichever way the part is turned, what loses its footing is what is above the hole in the world
		support_follows_world_down = function()
			local Breakable = load()
			local turns = {
				upright = { size = Vector3.new(6, 24, 2), turn = CFrame.identity },
				upsideDown = { size = Vector3.new(6, 24, 2), turn = CFrame.Angles(0, 0, math.pi) },
				onItsSide = { size = Vector3.new(24, 6, 2), turn = CFrame.Angles(0, 0, math.pi / 2) },
			}
			local failures = {}
			for name, case in turns do
				local part = newWall()
				part.Size = case.size
				part.CFrame = CFrame.new(260, 12, 0) * case.turn
				local wall = Breakable.new(part, with({ holeRadius = 6 }))
				wall:hit(Vector3.new(260, 12, -1), Vector3.zAxis, 2)
				local above, below = 0, 0
				for _, fragment in wall:fragments() do
					if fragment.Position.Y > 12 then
						above += 1
					else
						below += 1
					end
				end
				if above > 0 or below == 0 then
					table.insert(failures, `{name}: {above} stand above the hole, {below} below`)
				end
				wall:destroy()
				part:Destroy()
			end
			assert(#failures == 0, table.concat(failures, "; "))
		end,

		-- a part held from elsewhere (a panel welded into a building) keeps what the hole leaves, wherever it hangs
		support_can_be_off = function()
			local Breakable = load()
			local part = newWall()
			part.Size = Vector3.new(6, 24, 2)
			part.CFrame = CFrame.new(260, 12, 0)
			local wall = Breakable.new(part, with({ holeRadius = 6, support = false, minFragmentVolume = 0 }))
			local report = wall:hit(Vector3.new(260, 12, -1), Vector3.zAxis, 2)
			local above = 0
			for _, fragment in wall:fragments() do
				above += if fragment.Position.Y > 12 then 1 else 0
			end
			wall:destroy()
			part:Destroy()
			assert(report.dropped == 0 and above > 0, `{report.dropped} dropped, {above} above the hole`)
		end,

		-- a client needs a moment to show new meshes: what they replace stays visible that long, but is no longer solid
		swap_delay_keeps_the_wall_visible = test({ swapDelay = 0.4 }, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			assert(#wall:fragments() > 0)
			assert(part.Transparency == 0, "the wall vanished at once")
			assert(not part.CanQuery and not part.CanCollide and not part.CanTouch, "the old wall is still solid")
			task.wait(0.6)
			assert(part.Transparency == 1, "the old wall never went")
		end),

		swap_delay_keeps_replaced_pieces_visible = test({ swapDelay = 0.4, attach = true }, function(wall, part)
			local point, direction = face(part, -4, 0)
			wall:hit(point, direction, 1)
			task.wait(0.6)
			local before = wall:fragments()
			wall:hit(face(part, 3, 0), direction, 2)
			local standing = wall:fragments()
			local lingering = {}
			for _, piece in before do
				if not table.find(standing, piece) and piece.Parent and piece.Parent.Name ~= "VoronoiDebris" then
					table.insert(lingering, piece)
				end
			end
			assert(#lingering > 0, "the replaced pieces vanished at once")
			for _, piece in lingering do
				assert(piece.Transparency == 0 and not piece.CanQuery and not piece.CanCollide, "a replaced piece is still solid")
				assert(piece:FindFirstChildOfClass("WeldConstraint"), "a replaced piece came loose")
			end
			task.wait(0.6)
			for _, piece in lingering do
				assert(piece.Parent == nil, "a replaced piece was left behind")
			end
		end),

		reset_during_the_swap = test({ swapDelay = 0.4 }, function(wall, part)
			local point, direction = face(part, -4, 0)
			wall:hit(point, direction, 1)
			task.wait(0.6)
			local before = wall:fragments()
			wall:hit(face(part, 3, 0), direction, 2)
			wall:reset()
			for _, piece in before do
				assert(piece.Parent == nil, "a piece survived the reset")
			end
			assert(part.Transparency == 0 and part.CanQuery)
			wall:hit(point, direction, 3)
			wall:reset() -- while the whole wall is still waiting to be hidden
			task.wait(0.6)
			assert(part.Transparency == 0 and part.CanQuery and part.CanCollide, "the wall was hidden after its reset")
		end),

		destroy_during_the_swap = test({ swapDelay = 0.4 }, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local pieces = wall:fragments()
			wall:destroy()
			task.wait(0.6)
			assert(part.Transparency == 0 and part.CanQuery)
			for _, piece in pieces do
				assert(piece.Parent == nil)
			end
		end),

		collapse_during_the_swap = test({ swapDelay = 0.4, debrisLifetime = 0.1 }, function(wall, part)
			local point, direction = face(part, -4, 0)
			wall:hit(point, direction, 1)
			wall:hit(face(part, 3, 0), direction, 2)
			wall:collapse()
			task.wait(0.8)
			assert(part.Transparency == 1, "the collapsed wall stayed visible")
			local folder = workspace:FindFirstChild("VoronoiWalls")
			for _, piece in if folder then folder:GetChildren() else {} do
				assert(piece:FindFirstChild("BreakableRoot").Value ~= part, "a piece was left standing")
			end
		end),

		-- an explosion goes every way, leaning the way it travelled: pieces leave both faces of the wall
		collapse_blasts_every_way = test({ launchSpeed = 15, spread = 40, lift = 0 }, function(wall, part)
			local point, direction = face(part, -4, 0)
			wall:hit(point, direction, 1)
			local standing = wall:fragments()
			local impact = face(part, 2, 1)
			wall:collapse(impact, direction)
			local back, onwards, speed, flat, outward, counted = 0, 0, 0, 0, 0, 0
			for _, piece in standing do
				local velocity = piece.AssemblyLinearVelocity
				local along = velocity:Dot(direction)
				back += if along < 0 then 1 else 0
				onwards += along
				speed += velocity.Magnitude
				flat = math.max(flat, (velocity * Vector3.new(1, 0, 1)).Magnitude)
				local away = piece.Position - impact
				away -= direction * away:Dot(direction)
				if away.Magnitude > 2 then
					counted += 1
					outward += if (velocity - direction * along):Dot(away) > 0 then 1 else 0
				end
			end
			speed /= #standing
			assert(back >= #standing * 0.15 and back <= #standing * 0.5, `{back} of {#standing} come back`)
			assert(onwards > 0, "no lean along the shot")
			assert(speed > 20 and speed < 65, `mean speed {speed}`)
			assert(flat <= 70, `a piece crosses {flat} studs a second`)
			assert(counted > 0 and outward >= counted * 0.8, `{outward} of {counted} move apart`)
		end),

		blown_out_pieces_scatter = test({ launchSpeed = 15, spread = 40, lift = 0 }, function(wall, part, Breakable)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local back, forward, onwards, fastest = 0, 0, 0, 0
			for _, piece in workspace.VoronoiDebris:GetChildren() do
				local velocity = piece.AssemblyLinearVelocity
				if Breakable.rootOf(piece) == part and velocity.Magnitude > 5 then
					local along = velocity:Dot(direction)
					back += if along < 0 then 1 else 0
					forward += if along > 0 then 1 else 0
					onwards += along
					fastest = math.max(fastest, velocity.Magnitude)
				end
			end
			assert(back >= 1 and forward >= 1 and onwards > 0, `{back} back, {forward} onwards`)
			assert(fastest <= 75, `a piece leaves at {fastest}`)
		end),

		collapse_without_an_impact_is_gentle = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local standing = wall:fragments()
			wall:collapse()
			for _, piece in standing do
				assert(piece.AssemblyLinearVelocity.Magnitude < 10, `{piece.AssemblyLinearVelocity.Magnitude}`)
			end
		end),

		lift_throws_blown_out_pieces_up = test({ lift = 60 }, function(wall, part, Breakable)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local up, count = 0, 0
			for _, piece in workspace.VoronoiDebris:GetChildren() do
				if Breakable.rootOf(piece) == part and piece.AssemblyLinearVelocity.Magnitude > 20 then
					up += piece.AssemblyLinearVelocity.Y
					count += 1
				end
			end
			assert(count > 0 and up / count > 35, `{count} pieces, mean lift {up / math.max(count, 1)}`)
		end),

		-- loose pieces collide with nothing, so softer gravity is what keeps an explosion in view
		debris_gravity_softens_the_fall = test({ debrisGravity = 0.35 }, function(wall, part, Breakable)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			wall:collapse(point, direction)
			local count = 0
			for _, piece in workspace.VoronoiDebris:GetChildren() do
				if Breakable.rootOf(piece) == part then
					local force = piece:FindFirstChildOfClass("VectorForce")
					assert(force and force.Attachment0 and force.RelativeTo == Enum.ActuatorRelativeTo.World, "no lift on a piece")
					local expected = piece.AssemblyMass * workspace.Gravity * 0.65
					assert(math.abs(force.Force.Y - expected) < expected * 0.01 and force.Force.X == 0 and force.Force.Z == 0, `force {force.Force}, expected {expected}`)
					count += 1
				end
			end
			assert(count > 3, `{count} pieces`)
		end),

		debris_falls_normally_by_default = test(nil, function(wall, part, Breakable)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			for _, piece in workspace.VoronoiDebris:GetChildren() do
				assert(Breakable.rootOf(piece) ~= part or not piece:FindFirstChildOfClass("VectorForce"))
			end
		end),

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

		-- a hit that touches many fragments cuts them side by side, not one after another
		many_fragments_cut_together = test(nil, function(wall, part)
			for i, x in { -6, 6 } do
				local point, direction = face(part, x, 0)
				wall:hit(point, direction, i)
			end
			local Voronoi = require(lib)
			local real = Voronoi.fracture
			local active, peak, calls = 0, 0, 0
			Voronoi.fracture = function(...)
				active += 1
				calls += 1
				peak = math.max(peak, active)
				local result = real(...)
				active -= 1
				return result
			end
			wall.settings.holeRadius = 5 -- reach the rubble around both holes
			local point, direction = face(part, 0, -4)
			local ok, report = pcall(wall.hit, wall, point, direction, 3)
			Voronoi.fracture = real
			assert(ok, tostring(report))
			assert(calls >= 3, `only {calls} fragments cut`)
			assert(peak == calls, `at most {peak} of {calls} cuts ran together`)
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

		-- the settings that keep walls light are the library's own defaults
		light_defaults = function()
			local Breakable = load()
			local part = newWall()
			local wall = Breakable.new(part)
			local fracture = wall.settings.fracture
			assert(fracture.simplify == true and fracture.meshContent == "opaque", "heavy defaults")
			assert(fracture.workers == 0 and fracture.frameBudgetMs == 10)
			wall:destroy()
			local custom = Breakable.new(part, { fracture = { capColor = Color3.new(1, 0, 0) } })
			assert(custom.settings.fracture.simplify == true, "an override replaced every default")
			assert(custom.settings.fracture.capColor == Color3.new(1, 0, 0))
			custom:destroy()
			local again = Breakable.new(part)
			assert(again.settings.fracture.capColor == nil, "defaults were mutated")
			again:destroy()
			part:Destroy()
		end,

		destroying_the_part_cleans_up = test(nil, function(wall, part, Breakable)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local fragments = wall:fragments()
			assert(#fragments > 0)
			part:Destroy()
			task.wait()
			for _, fragment in fragments do
				assert(fragment.Parent == nil, "fragment left standing")
			end
			assert(wall.destroyed and wall:debrisCount() == 0 and Breakable.debrisCount() == 0)
		end),

		removing_the_part_cleans_up = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local fragments = wall:fragments()
			part.Parent = nil
			task.wait()
			for _, fragment in fragments do
				assert(fragment.Parent == nil, "fragment left standing")
			end
			assert(wall.destroyed and wall:debrisCount() == 0)
		end),

		part_destroyed_during_a_hit = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			local done, report = false, nil
			task.spawn(function()
				report = wall:hit(point, direction, 1, os.clock() + 0.5)
				done = true
			end)
			part:Destroy()
			local started = os.clock()
			while not done and os.clock() - started < 10 do
				task.wait()
			end
			assert(done and report == nil and #wall:fragments() == 0 and wall:debrisCount() == 0)
		end),

		-- other code may delete a fragment; the next hit carries on without it
		deleted_fragment_is_skipped = test(nil, function(wall, part)
			local point, direction = face(part, 0, 0)
			wall:hit(point, direction, 1)
			local far = part.CFrame:PointToWorldSpace(Vector3.new(12, 0, 0))
			local victim, distance = nil, -1
			for _, fragment in wall:fragments() do
				local away = (fragment.Position - far).Magnitude
				if away > distance then
					victim, distance = fragment, away
				end
			end
			victim:Destroy()
			wall.settings.holeRadius = 40
			local second = face(part, 12, 0)
			local ok, report = pcall(wall.hit, wall, second, direction, 2)
			assert(ok, tostring(report))
			assert(report, "hit did nothing")
		end),

		-- an error partway through a hit leaves a whole wall, not half of one
		error_while_applying_resets = test(nil, function(wall, part, Breakable)
			local point, direction = face(part, -8, 0)
			wall:hit(point, direction, 1)
			wall.settings.launchSpeed = "fast"
			local second = face(part, 8, 0)
			assert(not pcall(wall.hit, wall, second, direction, 2))
			assert(part.Transparency == 0 and part.CanCollide, "wall left half applied")
			assert(wall.hits == 0 and #wall:fragments() == 0 and Breakable.debrisCount() == 0)
			wall.settings.launchSpeed = 70
			assert(wall:hit(second, direction, 3), "cannot be hit afterwards")
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
