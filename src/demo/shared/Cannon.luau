-- Wall demo logic shared by the client and server scripts.

-- the library sits beside this script's folder
local Breakable = require(script.Parent.Parent:WaitForChild("Voronoi"):WaitForChild("Breakable"))

local HIT_SLACK = 1.5 -- studs a reported hit may be off the wall
local MIN_FLIGHT, MAX_FLIGHT = 0.05, 0.45

local Cannon = {}

local function walls(): Instance?
	local map = workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Walls")
end

-- True for a shot at a part in workspace.Map.Walls that lands on it. Safe to call with
-- whatever a client sends; NaN fails every comparison.
function Cannon.isValidShot(root: any, position: any, direction: any, origin: any): boolean
	local folder = walls()
	if not folder or typeof(root) ~= "Instance" or not root:IsA("BasePart") or not root:IsDescendantOf(folder) then
		return false
	end
	if typeof(position) ~= "Vector3" or typeof(direction) ~= "Vector3" or typeof(origin) ~= "Vector3" then
		return false
	end
	local offset = root.CFrame:PointToObjectSpace(position):Abs() - root.Size / 2
	if not (offset.X <= HIT_SLACK and offset.Y <= HIT_SLACK and offset.Z <= HIT_SLACK) then
		return false
	end
	if not (direction.Magnitude >= 0.5 and direction.Magnitude <= 1.5) then
		return false
	end
	return (origin - position).Magnitude <= 2000
end

function Cannon.flightTime(distance: number, settings: { [string]: any }): number
	return math.clamp(distance / settings.shellSpeed, MIN_FLIGHT, MAX_FLIGHT)
end

-- Damages the wall and prints the benchmark. Yields. `applyAt` is when the shell lands.
function Cannon.fire(root: BasePart, position: Vector3, direction: Vector3, seed: number, settings: { [string]: any }, applyAt: number?)
	local ok, report = pcall(function()
		return Breakable.get(root, settings.breakable):hit(position, direction, seed, applyAt)
	end)
	if not ok then
		warn(`Voronoi demo: {report}`)
		return nil
	end
	if report then
		print(string.format(
			"[Voronoi] %s hit: computed in %.3f s | %d blown out, %d fell, %d standing, %.0f%% left%s",
			root.Name,
			report.seconds,
			report.flying,
			report.dropped,
			report.standing,
			report.remaining * 100,
			if report.collapsed then " | COLLAPSED" else ""
		))
	end
	return report
end

return Cannon
