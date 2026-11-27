--!nocheck
-- Runs *.spec modules against a fresh clone of the library, so edits are always picked up.
-- Usage: require(game.ReplicatedStorage.VoronoiTests.Runner:Clone())("MeshData")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return function(filter: string?): string
	local tests = ReplicatedStorage.VoronoiTests

	local sandbox = Instance.new("Folder")
	sandbox.Name = "VoronoiSandbox"
	local lib = ReplicatedStorage.Voronoi:Clone()
	lib.Parent = sandbox
	sandbox.Parent = ReplicatedStorage

	local lines, passed, failed = {}, 0, 0
	local function fail(label: string, err: any)
		failed += 1
		table.insert(lines, `FAIL {label}: {tostring(err)}`)
	end

	local specs = {}
	for _, child in tests:GetChildren() do
		local name = string.match(child.Name, "^(.+)%.spec$")
		if name and (not filter or string.find(name, filter, 1, true)) then
			table.insert(specs, child)
		end
	end
	table.sort(specs, function(a, b)
		return a.Name < b.Name
	end)
	if #specs == 0 then
		fail("runner", `no spec matches "{filter}"`)
	end

	for _, spec in specs do
		local loaded, cases = pcall(function()
			return require(spec:Clone())(lib)
		end)
		if not loaded then
			fail(spec.Name, cases)
			continue
		end
		local names = {}
		for name in cases do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local ok, err = pcall(cases[name])
			if ok then
				passed += 1
			else
				fail(`{spec.Name} / {name}`, err)
			end
		end
	end

	pcall(function()
		local api = require(lib)
		if api.shutdown then
			api.shutdown()
		end
	end)
	sandbox:Destroy()

	table.insert(lines, `PASS {passed} FAIL {failed}`)
	return table.concat(lines, "\n")
end
