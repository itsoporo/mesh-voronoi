-- Options for the breakable walls in workspace.Map.Walls.
return {
	shellSpeed = 300, -- studs per second; the wall is cut while the shell flies
	maxRange = 1000, -- studs

	-- Voronoi.Breakable settings
	breakable = {
		holeRadius = 3, -- studs
		maxHits = 8, -- the wall collapses on this hit
		collapseBelow = 0.45, -- ...or when this fraction of its material is left
		maxFragments = 90, -- ...or above this many standing parts
		minFragmentVolume = 0.6, -- cubic studs; smaller fragments fall off
		debrisLifetime = 3,
		maxDebris = 60, -- loose pieces alive across all walls
		rebuildAfter = 20, -- seconds without a hit; false to stay broken
		launchSpeed = 70,
		spread = 25,
		-- merged over Breakable's own wall-friendly Voronoi options
		fracture = { capColor = Color3.fromRGB(150, 140, 130) },
	},
}
