-- A wall (or any block or mesh part) that takes repeated hits.
--
--   local Breakable = require(ReplicatedStorage.Voronoi.Breakable)
--   local wall = Breakable.get(part, settings)
--   wall:hit(position, direction, seed)   -- yields
--
-- Each hit punches a hole: chunks inside `holeRadius` fly along the shot and the rest
-- stays anchored. Damaged walls do not decay into clutter: slivers and unsupported
-- fragments fall off, debris despawns and is capped, and after enough damage the whole
-- wall collapses. Every removed piece frees its editable mesh.
--
-- Call it on one side only for any given wall: on the server so every player agrees
-- on the holes, or on each client for effects that do not affect gameplay.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Voronoi = require(script.Parent)

local ROOT_LINK = "BreakableRoot"
local ATTACHMENT = "BreakableWeld"
local FRAGMENT_FOLDER = "VoronoiWalls"
local DEBRIS_FOLDER = "VoronoiDebris"
local FADE_SECONDS = 0.5
local CLEARANCE_SECONDS = 0.15 -- debris passes through its neighbours while leaving the hole
local TOUCHING = 0.05 -- studs
local SMALL_MESH = 300 -- triangles; fragments this small are cut here, not on workers

local DEFAULTS = {
	holeRadius = 3, -- studs
	maxHits = 8, -- the wall collapses on this hit
	collapseBelow = 0.45, -- ...or when this fraction of its material is left
	maxFragments = 90, -- ...or when it would need more parts than this
	minFragmentVolume = 0.6, -- cubic studs; smaller fragments fall off
	debrisLifetime = 4, -- seconds
	maxDebris = 120, -- loose pieces alive across all walls
	rebuildAfter = 20 :: number | boolean, -- seconds without a hit; false never rebuilds
	launchSpeed = 70, -- studs per second along the shot
	spread = 25, -- studs per second away from the shot line
	lift = 0, -- studs per second upwards, added to whatever a hit or a blast throws
	-- seconds the parts a cut replaces stay visible (no longer solid), so a client that is still loading the new
	-- meshes never sees a gap
	swapDelay = 0,
	debrisCollides = true,
	rings = false :: any, -- { Ring } to lay out each hole's sites differently; false for the standard 25
	-- true welds the fragments to the wall part instead of anchoring them, for walls that are part of something that
	-- can move or fall
	attach = false,
	support = true, -- fragments that lose contact with the bottom of the wall fall
	-- Voronoi options for every cut; yours are merged over these
	fracture = {
		workers = 0, -- wall fragments are tiny: workers cost more than they save
		frameBudgetMs = 10,
		simplify = true, -- far fewer triangles per fragment
		meshContent = "opaque", -- fragments hold no editable memory, however many pile up
	} :: { [string]: any },
}

-- Sites of one hole: `count` of them around the impact at `distance` hole radii. `flies` says whether their cells are
-- blown out; left out, a cell flies if its site is closer than the radius.
export type Ring = { distance: number, count: number, flies: boolean? }

-- Ready made sites for one hit, as `holeSites` returns them. Walls hit with the same layout get the same hole.
export type Layout = { sites: { Vector3 }, flies: { boolean } }

local STANDARD_RINGS: { Ring } = {
	{ distance = 0, count = 1 },
	{ distance = 0.5, count = 4 },
	{ distance = 0.82, count = 6 },
	{ distance = 1.35, count = 7 },
	{ distance = 2.3, count = 7 },
}

local Breakable = {}
Breakable.__index = Breakable

local registry: { [BasePart]: any } = {}
local debris: { any } = {} -- oldest first

local function folder(name: string): Instance
	local found = workspace:FindFirstChild(name)
	if not found then
		found = Instance.new("Folder")
		found.Name = name
		found.Parent = workspace
	end
	return found :: Instance
end

-- The two axes spanning the wall's face and the thin one, as component indices.
local function axes(size: Vector3): (number, number, number)
	if size.X <= size.Y and size.X <= size.Z then
		return 3, 2, 1
	elseif size.Y <= size.Z then
		return 1, 3, 2
	end
	return 1, 2, 3
end

local function component(v: Vector3, axis: number): number
	return if axis == 1 then v.X elseif axis == 2 then v.Y else v.Z
end

local UNIT = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }

-- A frame on the part whose Y is the part's own axis closest to world up, and which of its axes that is.
local function upright(part: BasePart): (CFrame, number)
	local rotation = part.CFrame.Rotation
	local axis, lean = 2, rotation.YVector.Y
	for index, vector in { [1] = rotation.XVector, [3] = rotation.ZVector } do
		if math.abs(vector.Y) > math.abs(lean) + 1e-3 then
			axis, lean = index, vector.Y
		end
	end
	local up = rotation:VectorToWorldSpace(UNIT[axis]) * (if lean < 0 then -1 else 1)
	local right = rotation:VectorToWorldSpace(UNIT[axis % 3 + 1])
	return CFrame.fromMatrix(part.Position, right, up), axis
end

-- Sites for one hit, in world space, and for each whether its cell is blown out.
function Breakable.holeSites(
	wall: CFrame,
	size: Vector3,
	impact: Vector3,
	radius: number,
	seed: number,
	rings: { Ring }?
): ({ Vector3 }, { boolean })
	local random = Random.new(seed)
	local u, v, thin = axes(size)
	local localImpact = wall:PointToObjectSpace(impact)
	local centreU, centreV = component(localImpact, u), component(localImpact, v)
	local sites, flies = {}, {}
	for _, ring in rings or STANDARD_RINGS do
		local distance, count = ring.distance, ring.count
		local start = random:NextNumber(0, 2 * math.pi)
		for k = 1, count do
			local angle = start + (k + random:NextNumber(-0.3, 0.3)) * 2 * math.pi / count
			local r = distance * radius * (1 + random:NextNumber(-0.1, 0.1))
			local values = { 0, 0, 0 }
			values[u] = centreU + math.cos(angle) * r
			values[v] = centreV + math.sin(angle) * r
			-- sites at different depths tilt the cut faces
			values[thin] = random:NextNumber(-0.3, 0.3) * component(size, thin)
			table.insert(sites, wall:PointToWorldSpace(Vector3.new(values[1], values[2], values[3])))
			table.insert(flies, if ring.flies == nil then r < radius else ring.flies :: boolean)
		end
	end
	return sites, flies
end

-- Which boxes rest on the ground, directly or through other boxes. Returns a set of
-- indices.
function Breakable.supported(boxes: { { min: Vector3, max: Vector3 } }, ground: number): { [number]: boolean }
	local standing: { [number]: boolean } = {}
	local queue = {}
	for i, box in boxes do
		if box.min.Y <= ground + TOUCHING then
			standing[i] = true
			table.insert(queue, i)
		end
	end
	while #queue > 0 do
		local a = boxes[table.remove(queue) :: number]
		for i, b in boxes do
			if
				not standing[i]
				and a.min.X <= b.max.X + TOUCHING and b.min.X <= a.max.X + TOUCHING
				and a.min.Y <= b.max.Y + TOUCHING and b.min.Y <= a.max.Y + TOUCHING
				and a.min.Z <= b.max.Z + TOUCHING and b.min.Z <= a.max.Z + TOUCHING
			then
				standing[i] = true
				table.insert(queue, i)
			end
		end
	end
	return standing
end

-- A part's bounding box in the space of `frame`.
local function boxIn(frame: CFrame, part: BasePart): { min: Vector3, max: Vector3 }
	local relative = frame:ToObjectSpace(part.CFrame)
	local half = part.Size / 2
	local reach = relative.XVector:Abs() * half.X + relative.YVector:Abs() * half.Y + relative.ZVector:Abs() * half.Z
	return { min = relative.Position - reach, max = relative.Position + reach }
end

function Breakable.new(root: BasePart, settings: { [string]: any }?)
	local options = table.clone(DEFAULTS)
	options.fracture = table.clone(DEFAULTS.fracture)
	for key, value in settings or {} do
		if DEFAULTS[key] == nil then
			error(`Breakable: unknown setting "{key}"`, 2)
		end
		if key == "fracture" then
			for option, chosen in value do
				options.fracture[option] = chosen
			end
		else
			(options :: any)[key] = value
		end
	end
	local self = setmetatable({
		root = root,
		settings = options,
		hits = 0,
		collapsed = false,
		destroyed = false,
		_standing = {} :: { any },
		_original = nil :: any, -- the root's properties while it is hidden
		_retiring = {} :: { any }, -- replaced pieces still visible for `swapDelay`
		_volume = 0,
		_generation = 0,
		_hitNumber = 0,
		_busy = false,
		_watching = {} :: { RBXScriptConnection },
	}, Breakable)
	registry[root] = self
	-- a wall that is destroyed, stored away or streamed out takes its rubble with it
	local function gone()
		self:destroy()
	end
	table.insert(self._watching, root.Destroying:Connect(gone))
	table.insert(self._watching, root.AncestryChanged:Connect(function()
		if not root:IsDescendantOf(workspace) then
			gone()
		end
	end))
	return self
end

-- The wall for `root`, creating it with `settings` the first time.
function Breakable.get(root: BasePart, settings: { [string]: any }?)
	return registry[root] or Breakable.new(root, settings)
end

-- The wall part a fragment came from, or nil. Works on the client for server walls.
function Breakable.rootOf(part: Instance): BasePart?
	local link = part:FindFirstChild(ROOT_LINK)
	return if link and link:IsA("ObjectValue") then link.Value :: BasePart? else nil
end

function Breakable:fragments(): { BasePart }
	local parts = {}
	for _, record in self._standing do
		table.insert(parts, record.part)
	end
	return parts
end

function Breakable:trianglesOf(part: BasePart): number
	for _, record in self._standing do
		if record.part == part then
			return #record.mesh.caps
		end
	end
	return 0
end

function Breakable:volumeOf(part: BasePart): number
	for _, record in self._standing do
		if record.part == part then
			return record.volume
		end
	end
	return 0
end

-- Loose pieces alive: of this wall, or of every wall when called as Breakable.debrisCount().
function Breakable.debrisCount(self: any?): number
	if not self then
		return #debris
	end
	local count = 0
	for _, entry in debris do
		if entry.owner == self then
			count += 1
		end
	end
	return count
end

local function removeDebris(entry: any)
	local index = table.find(debris, entry)
	if index then
		table.remove(debris, index)
		entry.release()
	end
end

-- Welds a fragment to the wall part, which carries it wherever the wall goes.
local function attach(part: BasePart, root: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = ATTACHMENT
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
end

function Breakable:_throw(record: any, velocity: Vector3, spin: Vector3)
	local options = self.settings
	local part = record.part :: BasePart
	local weld = part:FindFirstChild(ATTACHMENT)
	if weld then
		weld:Destroy()
		part.Massless = false
	end
	part.Anchored = false
	part.CanQuery = false -- shots and clicks pass through rubble
	part.CanTouch = false
	part.CanCollide = false
	part.Parent = folder(DEBRIS_FOLDER)
	if RunService:IsRunning() and RunService:IsServer() then
		part:SetNetworkOwner(nil)
	end
	part.AssemblyLinearVelocity = velocity
	part.AssemblyAngularVelocity = spin

	local entry = { owner = self, release = record.release }
	table.insert(debris, entry)
	if options.debrisCollides then
		task.delay(CLEARANCE_SECONDS, function()
			if part.Parent then
				part.CanCollide = true
			end
		end)
	end
	local lifetime = options.debrisLifetime
	task.delay(math.max(lifetime - FADE_SECONDS, 0), function()
		if part.Parent and lifetime > FADE_SECONDS then
			TweenService:Create(part, TweenInfo.new(FADE_SECONDS), { Transparency = 1 }):Play()
		end
	end)
	task.delay(lifetime, removeDebris, entry)

	while #debris > options.maxDebris do
		removeDebris(debris[1])
	end
end

-- The wall part stays as the anchor for its fragments, untouchable at once and unseen after `delay`, until `reset`.
function Breakable:_hideRoot(delay: number?)
	local root = self.root :: BasePart
	local original = {
		Transparency = root.Transparency,
		CanCollide = root.CanCollide,
		CanQuery = root.CanQuery,
		CanTouch = root.CanTouch,
	}
	self._original = original
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	if delay and delay > 0 then
		task.delay(delay, function()
			if self._original == original then -- not rebuilt in the meantime
				root.Transparency = 1
			end
		end)
	else
		root.Transparency = 1
	end
end

-- Takes a replaced piece out of play at once and out of sight after `swapDelay`.
function Breakable:_retire(record: any)
	local delay = self.settings.swapDelay
	if delay <= 0 then
		record.release()
		return
	end
	local part = record.part :: BasePart
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	table.insert(self._retiring, record)
	task.delay(delay, function()
		local index = table.find(self._retiring, record)
		if index then
			table.remove(self._retiring, index)
			record.release()
		end
	end)
end

-- The velocity of a piece thrown by an explosion at `impact` travelling along `direction`: mostly onwards, outwards
-- from the impact and up, the nearest pieces fastest.
function Breakable:_blast(part: BasePart, impact: Vector3, direction: Vector3, random: Random): Vector3
	local options = self.settings
	local away = part.Position - impact
	local sideways = away - direction * away:Dot(direction)
	local reach = math.max((self.root :: BasePart).Size.Magnitude / 2, 1)
	local near = math.clamp(1.2 - sideways.Magnitude / reach * 0.7, 0.5, 1.2)
	local outwards = if sideways.Magnitude > 1e-3 then sideways.Unit else Vector3.zero
	return direction * options.launchSpeed * near * random:NextNumber(0.8, 1.2)
		+ outwards * options.spread * random:NextNumber(0.6, 1.2)
		+ Vector3.yAxis * options.lift * random:NextNumber(0.6, 1.4)
end

-- Is there anything left to hit along the shot at this point?
function Breakable:_solidAt(position: Vector3, direction: Vector3): boolean
	if #self._standing == 0 then
		return self.hits == 0
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = self:fragments()
	local depth = self.root.Size.Magnitude
	local reach = math.min(self.root.Size.X, self.root.Size.Y, self.root.Size.Z) + 1
	local found = workspace:Raycast(position - direction * 1, direction * math.min(reach * 2, depth), params)
	return found ~= nil
end

function Breakable:_apply(
	position: Vector3,
	direction: Vector3,
	seed: number,
	applyAt: number?,
	holeRadius: number?,
	layout: Layout?
)
	local options = self.settings
	local root = self.root :: BasePart
	local generation = self._generation
	local inWorld = root:IsDescendantOf(workspace)
	-- forget fragments that something else has deleted
	for i = #self._standing, 1, -1 do
		if not self._standing[i].part.Parent then
			table.remove(self._standing, i).release()
		end
	end
	-- a layout says itself where the hole is, which may be beside this part's share of the shot line
	if not layout and not self:_solidAt(position, direction) then
		return nil
	end

	local radius = holeRadius or options.holeRadius
	local sites, flies
	if layout then
		sites, flies = layout.sites, layout.flies
	else
		sites, flies = Breakable.holeSites(root.CFrame, root.Size, position, radius, seed, options.rings or nil)
	end
	local u, v, thin = axes(root.Size)
	local impact = root.CFrame:PointToObjectSpace(position)

	-- The root on the first hit, afterwards every fragment the hole can reach.
	-- Fragments wholly inside the hole are blown out as they are.
	local targets, whole = {}, {}
	if self.hits == 0 then
		table.insert(targets, { part = root, mesh = nil })
	else
		for _, record in self._standing do
			local box = boxIn(root.CFrame, record.part)
			local lowU, highU = component(box.min, u) - component(impact, u), component(box.max, u) - component(impact, u)
			local lowV, highV = component(box.min, v) - component(impact, v), component(box.max, v) - component(impact, v)
			local nearU, nearV = math.max(lowU, 0, -highU), math.max(lowV, 0, -highV)
			local farU, farV = math.max(-lowU, highU), math.max(-lowV, highV)
			if farU * farU + farV * farV <= radius * radius then
				table.insert(whole, record)
			elseif nearU * nearU + nearV * nearV <= radius * radius then
				table.insert(targets, record)
			end
		end
		-- the far ring only shapes the cracks in an intact wall; on fragments it would
		-- just make more, smaller ones
		local nearSites, nearFlies = {}, {}
		for i, site in sites do
			local offset = root.CFrame:PointToObjectSpace(site) - impact
			local planar = Vector2.new(component(offset, u), component(offset, v)).Magnitude
			if planar <= radius * 1.6 then
				table.insert(nearSites, site)
				table.insert(nearFlies, flies[i])
			end
		end
		sites, flies = nearSites, nearFlies
	end
	if #targets + #whole == 0 then
		return nil
	end

	-- Cut everything first, so the wall changes in a single step. The cuts run side by
	-- side: one after another they would each cost at least a frame.
	local cuts = {}
	local failure: any = nil
	local pending = #targets
	local started = os.clock()
	for i, target in targets do
		task.spawn(function()
			local ok, err = pcall(function()
				local localSites = table.create(#sites)
				for k, site in sites do
					localSites[k] = target.part.CFrame:PointToObjectSpace(site)
				end
				local config = table.clone(options.fracture)
				config.seed = seed
				-- handing a small mesh to workers costs more than cutting it
				if target.mesh and #target.mesh.tris / 3 <= SMALL_MESH then
					config.workers = 0
				end
				cuts[i] = { target = target, result = Voronoi.fracture(target.part, localSites, config, target.mesh) }
			end)
			if not ok then
				failure = failure or err
			end
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait()
	end
	local seconds = os.clock() - started
	if applyAt then
		while os.clock() < applyAt and generation == self._generation do
			task.wait()
		end
	end
	local removed = inWorld and not root:IsDescendantOf(workspace)
	if failure or removed or generation ~= self._generation then
		for _, cut in cuts do
			cut.result:destroy()
		end
		if failure then
			error(failure, 0)
		end
		return nil
	end

	-- Everything from here changes the wall. It does not yield, and if any of it fails
	-- the wall is rebuilt rather than left half changed.
	local function commit()
		local random = Random.new(seed)
		local first = self.hits == 0
		-- where each cut part is now: a wall that is part of something moving has moved since the cut began
		local frames = {}
		for i, cut in cuts do
			frames[i] = cut.target.part.CFrame
		end
		if first then
			self:_hideRoot(options.swapDelay)
			self._volume = 0
		else
			for _, cut in cuts do
				local index = table.find(self._standing, cut.target)
				if index then
					table.remove(self._standing, index)
					self:_retire(cut.target)
				end
			end
		end

		local report = { targets = #targets + #whole, flying = 0, dropped = 0, standing = 0, collapsed = false, remaining = 0, seconds = seconds }
		local function spin(scale: number): Vector3
			return random:NextUnitVector() * scale
		end
		local function drop(record: any)
			report.dropped += 1
			self:_throw(record, Vector3.zero, spin(2))
		end

		local function launch(record: any)
			report.flying += 1
			local away = record.part.Position - position
			local sideways = away - direction * away:Dot(direction)
			local off = math.min(sideways.Magnitude / radius, 1.5)
			local velocity = direction * options.launchSpeed * math.clamp(1.15 - off * 0.6, 0.35, 1.15)
			if sideways.Magnitude > 1e-3 then
				velocity += sideways.Unit * options.spread * off
			end
			velocity += Vector3.yAxis * options.lift
			self:_throw(record, velocity + spin(options.spread * 0.3), spin(14))
		end

		for _, record in whole do
			local index = table.find(self._standing, record)
			if index then
				table.remove(self._standing, index)
				launch(record)
			end
		end

		local standingParts = folder(FRAGMENT_FOLDER)
		for i, cut in cuts do
			for _, piece in cut.result.pieces do
				piece.part.CFrame = frames[i] * CFrame.new(piece.center)
				if first then
					self._volume += piece.volume
				end
				local record = { part = piece.part, mesh = piece.mesh, volume = piece.volume, release = piece.destroy }
				local link = Instance.new("ObjectValue")
				link.Name = ROOT_LINK
				link.Value = root
				link.Parent = piece.part
				if flies[piece.siteIndex] then
					launch(record)
				elseif piece.volume < options.minFragmentVolume then
					drop(record)
				else
					if options.attach then
						piece.part.Anchored = false
						piece.part.Massless = true
						piece.part.Parent = standingParts
						attach(piece.part, root)
					else
						piece.part.Anchored = true
						piece.part.Parent = standingParts
					end
					table.insert(self._standing, record)
				end
			end
		end

		-- anything no longer connected to the ground falls (walls only, not floors)
		local frame, up = upright(root)
		if options.support and thin ~= up then
			local boxes = {}
			for i, record in self._standing do
				boxes[i] = boxIn(frame, record.part)
			end
			local held = Breakable.supported(boxes, -component(root.Size, up) / 2)
			for i = #self._standing, 1, -1 do
				if not held[i] then
					drop(table.remove(self._standing, i))
				end
			end
		end

		self.hits += 1
		local left = 0
		for _, record in self._standing do
			left += record.volume
		end
		report.remaining = if self._volume > 0 then left / self._volume else 0

		if self.hits >= options.maxHits or report.remaining <= options.collapseBelow or #self._standing > options.maxFragments then
			self.collapsed = true
			report.collapsed = true
			for _, record in self._standing do
				self:_throw(record, self:_blast(record.part, position, direction, random), spin(14))
			end
			table.clear(self._standing)
		end
		report.standing = #self._standing
		return report
	end

	local committed, result = pcall(commit)
	if not committed then
		for _, list in { targets, whole } do
			for _, record in list do
				if record.release then
					record.release()
				end
			end
		end
		for _, cut in cuts do
			cut.result:destroy()
		end
		self:reset()
		error(result, 0)
	end
	return result
end

-- Yields until the hit has been applied. `direction` is the shot's travel direction.
-- `applyAt` (an os.clock() time) holds the result back, e.g. until a shell arrives.
-- `radius` overrides the `holeRadius` setting for this hit, and `layout` its sites.
-- Returns nil if there was nothing to hit or the wall was reset or collapsed meanwhile.
function Breakable:hit(
	position: Vector3,
	direction: Vector3,
	seed: number,
	applyAt: number?,
	radius: number?,
	layout: Layout?
)
	local generation = self._generation
	-- one hit at a time: each cuts what the previous one left
	while self._busy do
		task.wait()
	end
	if self.destroyed or self.collapsed or generation ~= self._generation then
		return nil
	end
	self._busy = true
	local ok, report = pcall(self._apply, self, position, direction.Unit, seed, applyAt, radius, layout)
	self._busy = false
	if not ok then
		error(report, 0)
	end

	if report and generation == self._generation then
		self._hitNumber += 1
		local number = self._hitNumber
		if self.settings.rebuildAfter then
			task.delay(self.settings.rebuildAfter :: number, function()
				if number == self._hitNumber and generation == self._generation then
					self:reset()
				end
			end)
		end
	end
	return report
end

-- Brings the whole wall down. Given where an explosion hit it and which way that travelled, the standing fragments are
-- blown away from there; without, they fall where they are. An untouched wall is simply hidden. A hit still being cut
-- is discarded. Returns the number of fragments thrown. `reset` rebuilds the wall.
function Breakable:collapse(impact: Vector3?, direction: Vector3?): number
	if self.destroyed or self.collapsed then
		return 0
	end
	self._generation += 1
	self.collapsed = true
	if not self._original then
		self:_hideRoot()
	end
	local random = Random.new(self.hits)
	local thrown = #self._standing
	for _, record in self._standing do
		if impact and direction then
			local velocity = self:_blast(record.part, impact, direction.Unit, random)
			self:_throw(record, velocity, random:NextUnitVector() * 14)
		else
			self:_throw(record, random:NextUnitVector() * self.settings.spread * 0.2, random:NextUnitVector() * 3)
		end
	end
	table.clear(self._standing)
	return thrown
end

-- Rebuilds the wall, removing its fragments and debris.
function Breakable:reset()
	self._generation += 1
	for _, record in self._standing do
		record.release()
	end
	table.clear(self._standing)
	for _, record in self._retiring do
		record.release()
	end
	table.clear(self._retiring)
	for i = #debris, 1, -1 do
		if debris[i].owner == self then
			removeDebris(debris[i])
		end
	end
	if self._original then
		for property, value in self._original do
			(self.root :: any)[property] = value
		end
		self._original = nil
	end
	self.hits = 0
	self.collapsed = false
end

function Breakable:destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, connection in self._watching do
		connection:Disconnect()
	end
	table.clear(self._watching)
	self:reset()
	if registry[self.root] == self then
		registry[self.root] = nil
	end
end

return Breakable
