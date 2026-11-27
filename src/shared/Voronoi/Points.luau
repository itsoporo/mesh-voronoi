-- Generates Voronoi sites in part-local studs.

local Config = require(script.Parent.Config)

local ATTEMPTS_PER_SITE = 30

local Points = {}

-- Pure version: `size` is the box to fill, `localFocus` the centre for "clustered".
function Points.sample(size: Vector3, localFocus: Vector3?, config: { [string]: any }?): { Vector3 }
	local options = Config.resolve(config)
	local random = Random.new(options.seed)
	local half = (size / 2 + Vector3.one * options.boundsPadding):Max(Vector3.zero)
	local clustered = options.distribution == "clustered"
	local focus = (localFocus or Vector3.zero):Max(-half):Min(half)
	local radius = options.focusRadius or size.Magnitude / 4

	local function candidate(): Vector3
		if clustered then
			-- squaring the distance packs sites towards the focus
			local offset = random:NextUnitVector() * (radius * random:NextNumber() ^ 2)
			return (focus + offset):Max(-half):Min(half)
		end
		return Vector3.new(
			random:NextNumber(-half.X, half.X),
			random:NextNumber(-half.Y, half.Y),
			random:NextNumber(-half.Z, half.Z)
		)
	end

	local sites: { Vector3 } = {}
	local attempts = options.count * ATTEMPTS_PER_SITE
	while #sites < options.count and attempts > 0 do
		attempts -= 1
		local p = candidate()
		local clear = true
		if options.minSpacing > 0 then
			for _, other in sites do
				if (other - p).Magnitude < options.minSpacing then
					clear = false
					break
				end
			end
		end
		if clear then
			table.insert(sites, p)
		end
	end
	return sites
end

-- Sites for a part. `config.focus` is in world space.
function Points.generate(part: BasePart, config: { [string]: any }?): { Vector3 }
	local focus = config and config.focus
	local localFocus = if focus then part.CFrame:PointToObjectSpace(focus) else nil
	return Points.sample(part.Size, localFocus, config)
end

return Points
