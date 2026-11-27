return function(lib)
	return {
		-- work running side by side shares one frame budget instead of each taking its own
		shared_between_callers = function()
			local Budget = require(lib.Budget)
			local frame = 0
			local connection = game:GetService("RunService").Heartbeat:Connect(function()
				frame += 1
			end)
			local perFrame: { [number]: number } = {}
			local finished = 0
			for _ = 1, 6 do
				task.spawn(function()
					for _ = 1, 10 do
						Budget.checkpoint(4)
						local started = os.clock()
						while os.clock() - started < 0.001 do
						end
						perFrame[frame] = (perFrame[frame] or 0) + 1
					end
					finished += 1
				end)
			end
			local started = os.clock()
			while finished < 6 and os.clock() - started < 10 do
				task.wait()
			end
			connection:Disconnect()
			assert(finished == 6, "work never finished")
			for at, count in perFrame do
				assert(count <= 6, `{count} one-millisecond jobs in frame {at} with a 4 ms budget`)
			end
		end,
	}
end
