return function(lib)
	local function load()
		return require(lib.Points)
	end
	local size = Vector3.new(4, 2, 6)

	local function inside(sites, half: Vector3)
		for _, p in sites do
			assert(math.abs(p.X) <= half.X + 1e-5 and math.abs(p.Y) <= half.Y + 1e-5 and math.abs(p.Z) <= half.Z + 1e-5, `outside: {p}`)
		end
	end

	local function equal(a, b): boolean
		if #a ~= #b then
			return false
		end
		for i, p in a do
			if p ~= b[i] then
				return false
			end
		end
		return true
	end

	return {
		count_in_bounds = function()
			local sites = load().sample(size, nil, { count = 50 })
			assert(#sites == 50)
			inside(sites, size / 2)
		end,
		deterministic = function()
			local Points = load()
			local first = Points.sample(size, nil, { count = 10, seed = 1 })
			assert(equal(first, Points.sample(size, nil, { count = 10, seed = 1 })))
			assert(not equal(first, Points.sample(size, nil, { count = 10, seed = 2 })))
		end,
		padding = function()
			local sites = load().sample(size, nil, { count = 50, boundsPadding = -0.5 })
			assert(#sites == 50)
			inside(sites, size / 2 - Vector3.one * 0.5)
		end,
		min_spacing = function()
			local sites = load().sample(size, nil, { count = 20, minSpacing = 1 })
			assert(#sites > 1)
			for i = 1, #sites do
				for j = i + 1, #sites do
					assert((sites[i] - sites[j]).Magnitude >= 1)
				end
			end
		end,
		impossible_spacing = function()
			assert(#load().sample(size, nil, { count = 5, minSpacing = 100 }) == 1)
		end,
		clustered = function()
			local focus = Vector3.new(2, 0, 0)
			local sites = load().sample(size, focus, { count = 40, distribution = "clustered", focusRadius = 0.5 })
			assert(#sites == 40)
			inside(sites, size / 2)
			for _, p in sites do
				assert((p - focus).Magnitude <= 0.5 + 1e-5)
			end
		end,
		world_focus = function()
			local part = Instance.new("Part")
			part.Size = size
			part.CFrame = CFrame.new(10, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
			local sites = load().generate(part, {
				count = 5,
				distribution = "clustered",
				focus = part.CFrame:PointToWorldSpace(Vector3.xAxis),
				focusRadius = 0.01,
			})
			part:Destroy()
			assert(#sites == 5)
			for _, p in sites do
				assert((p - Vector3.xAxis).Magnitude <= 0.011, `far from focus: {p}`)
			end
		end,
	}
end
