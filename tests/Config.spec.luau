return function(lib)
	local Config = require(lib.Config)
	return {
		defaults = function()
			local c = Config.resolve()
			assert(c.count == 32 and c.workers == 8 and c.seed == 1 and c.frameBudgetMs == 4)
			assert(c.collisionFidelity == Enum.CollisionFidelity.Hull)
			assert(c.parallelism == 8)
			assert(Config.resolve({ parallelism = 4 }).parallelism == 4)
			assert(c.demoSide == "client")
			assert(c.simplify == false and c.meshContent == "auto")
			assert(c.printTimings == false)
			assert(Config.resolve({ printTimings = true }).printTimings == true)
			assert(Config.resolve({ demoSide = "server" }).demoSide == "server")
		end,
		override_does_not_leak = function()
			assert(Config.resolve({ count = 5 }).count == 5)
			assert(Config.resolve().count == 32)
		end,
		unknown_key_errors = function()
			local ok, err = pcall(Config.resolve, { cout = 5 })
			assert(not ok and string.find(err, "cout"))
		end,
		invalid_values_error = function()
			for _, bad in { { count = 0 }, { count = 1.5 }, { workers = -1 }, { distribution = "x" }, { frameBudgetMs = 0 }, { minSpacing = -1 }, { parallelism = 0 }, { parallelism = 2.5 }, { demoSide = "both" }, { printTimings = 1 }, { simplify = 1 }, { meshContent = "solid" } } do
				assert(not pcall(Config.resolve, bad))
			end
		end,
	}
end
