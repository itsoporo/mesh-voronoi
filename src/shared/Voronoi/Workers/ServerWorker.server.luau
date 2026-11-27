-- A template: it only does something once cloned into an Actor by the scheduler.
local actor = script:GetActor()
if actor then
	local core = script:WaitForChild("Core") :: ObjectValue
	local start = require(core.Value :: ModuleScript) :: (Actor) -> ()
	start(actor)
end
