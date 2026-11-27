-- One per-frame time budget shared by all main-thread work in this library, so cuts
-- running side by side do not each spend a full budget in the same frame.

local RunService = game:GetService("RunService")

local frame = 0
local sliceFrame = -1
local sliceStart = 0

RunService.Heartbeat:Connect(function()
	frame += 1
end)

local Budget = {}

-- Call before a unit of work: yields while this frame has already used `milliseconds`.
function Budget.checkpoint(milliseconds: number)
	while true do
		if frame ~= sliceFrame then
			sliceFrame = frame
			sliceStart = os.clock()
		end
		if (os.clock() - sliceStart) * 1000 < milliseconds then
			return
		end
		task.wait()
	end
end

return Budget
