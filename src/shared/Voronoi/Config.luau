-- Defaults and validation for every Voronoi option.

export type Config = {
	-- Points
	count: number,
	seed: number,
	distribution: string, -- "uniform" | "clustered"
	focus: Vector3?, -- world space
	focusRadius: number?, -- studs; default is a quarter of the part's diagonal
	minSpacing: number, -- studs
	boundsPadding: number, -- studs added to each face of the box; negative shrinks
	-- Geometry
	closeHoles: boolean,
	splitIslands: boolean,
	capColor: Color3?,
	simplify: boolean, -- merge flat faces so pieces carry fewer triangles
	-- Execution
	workers: number, -- 0 cuts on the calling thread
	frameBudgetMs: number,
	parallelism: number, -- cells expected to run side by side on the target device
	printTimings: boolean, -- print a benchmark line after each fracture
	meshContent: string, -- "auto" | "opaque": opaque pieces hold no editable memory but build slower
	-- Parts
	collisionFidelity: Enum.CollisionFidelity,
	renderFidelity: Enum.RenderFidelity,
	-- Demo
	demoSide: string, -- "client" | "server": where the click demo fractures
	force: number, -- speed given to each piece, studs per second
	upwardBias: number,
	resetAfter: number,
}

local function isNumber(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isInteger(value: any): boolean
	return isNumber(value) and value % 1 == 0
end

local function atLeast(minimum: number)
	return function(value: any): boolean
		return isNumber(value) and value >= minimum
	end
end

local function positive(value: any): boolean
	return isNumber(value) and value > 0
end

local function isType(name: string)
	return function(value: any): boolean
		return typeof(value) == name
	end
end

local function isEnum(enum: Enum)
	return function(value: any): boolean
		return typeof(value) == "EnumItem" and value.EnumType == enum
	end
end

local validators: { [string]: (any) -> boolean } = {
	count = function(value)
		return isInteger(value) and value >= 1
	end,
	seed = isInteger,
	distribution = function(value)
		return value == "uniform" or value == "clustered"
	end,
	focus = isType("Vector3"),
	focusRadius = positive,
	minSpacing = atLeast(0),
	boundsPadding = isNumber,
	closeHoles = isType("boolean"),
	splitIslands = isType("boolean"),
	capColor = isType("Color3"),
	simplify = isType("boolean"),
	meshContent = function(value)
		return value == "auto" or value == "opaque"
	end,
	workers = function(value)
		return isInteger(value) and value >= 0 and value <= 64
	end,
	frameBudgetMs = positive,
	parallelism = function(value)
		return isInteger(value) and value >= 1
	end,
	printTimings = isType("boolean"),
	collisionFidelity = isEnum(Enum.CollisionFidelity),
	renderFidelity = isEnum(Enum.RenderFidelity),
	demoSide = function(value)
		return value == "client" or value == "server"
	end,
	force = atLeast(0),
	upwardBias = isNumber,
	resetAfter = positive,
}

local Config = {}

-- focus, focusRadius and capColor default to nil.
Config.defaults = table.freeze({
	count = 32,
	seed = 1,
	distribution = "uniform",
	minSpacing = 0,
	boundsPadding = 0,
	closeHoles = true,
	splitIslands = true,
	simplify = false,
	meshContent = "auto",
	workers = 8,
	frameBudgetMs = 4,
	parallelism = 8,
	printTimings = false,
	collisionFidelity = Enum.CollisionFidelity.Hull,
	renderFidelity = Enum.RenderFidelity.Automatic,
	demoSide = "client",
	force = 40,
	upwardBias = 0.35,
	resetAfter = 6,
})

function Config.resolve(overrides: { [string]: any }?): Config
	local result: any = table.clone(Config.defaults)
	if overrides then
		for key, value in overrides do
			local validate = validators[key]
			if not validate then
				error(`Voronoi config: unknown key "{key}"`, 2)
			end
			if not validate(value) then
				error(`Voronoi config: invalid value for "{key}": {tostring(value)}`, 2)
			end
			result[key] = value
		end
	end
	return result
end

return Config
