-- Options for the click-Suzanne demo. Any Voronoi config key works here.
return {
	demoSide = "client", -- "client": every player fractures; "server": one shared fracture
	count = 32,
	capColor = Color3.fromRGB(170, 70, 70), -- tint of the cut faces; remove for none
	force = 40,
	upwardBias = 0.35,
	resetAfter = 6,
	printTimings = true, -- benchmark line in the output after each break
	-- Suzanne's worst frame is set by her slowest single cell, so a larger budget
	-- breaks her sooner at no extra cost in smoothness
	frameBudgetMs = 16,
}
