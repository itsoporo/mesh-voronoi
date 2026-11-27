-- Visual-only shell, impact flash, dust and sparks. Run on clients.

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local OVERSHOOT = 45 -- studs the shell carries on past the wall

local Effects = {}

local function ghost(size: Vector3, cframe: CFrame): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = cframe
	return part
end

-- A glowing shell with a tracer, from `origin` to `target` in `seconds`, then through.
function Effects.shell(origin: Vector3, target: Vector3, seconds: number)
	local path = target - origin
	if path.Magnitude < 1 then
		return
	end
	local direction = path.Unit
	local shell = ghost(Vector3.new(0.45, 0.45, 2.2), CFrame.lookAt(origin, target))
	shell.Material = Enum.Material.Neon
	shell.Color = Color3.fromRGB(255, 196, 90)

	local top, bottom = Instance.new("Attachment"), Instance.new("Attachment")
	top.Position, bottom.Position = Vector3.new(0, 0.22, 0.9), Vector3.new(0, -0.22, 0.9)
	top.Parent, bottom.Parent = shell, shell
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = top, bottom
	trail.Lifetime = 0.18
	trail.LightEmission = 1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 220, 150), Color3.fromRGB(255, 110, 40))
	trail.Transparency = NumberSequence.new(0.1, 1)
	trail.FaceCamera = true
	trail.Parent = shell
	shell.Parent = workspace

	local started = os.clock()
	local total = seconds * (1 + OVERSHOOT / path.Magnitude)
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		local elapsed = os.clock() - started
		local travelled = path.Magnitude * elapsed / seconds
		shell.CFrame = CFrame.lookAt(origin + direction * travelled, origin + direction * (travelled + 1))
		if elapsed >= total then
			connection:Disconnect()
			shell.Transparency = 1
			Debris:AddItem(shell, trail.Lifetime)
		end
	end)
end

local function burst(parent: Instance, properties: { [string]: any }, count: number)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	for property, value in properties do
		(emitter :: any)[property] = value
	end
	emitter.Parent = parent
	emitter:Emit(count)
end

-- `direction` is the shot's travel direction, `color` the colour of what was hit.
function Effects.impact(position: Vector3, direction: Vector3, color: Color3)
	local holder = ghost(Vector3.one, CFrame.lookAt(position - direction, position - direction * 2))
	holder.Transparency = 1
	holder.Parent = workspace

	local flash = ghost(Vector3.one * 1.5, CFrame.new(position - direction * 0.8))
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 214, 140)
	flash.Parent = workspace
	local light = Instance.new("PointLight")
	light.Color = flash.Color
	light.Range = 24
	light.Brightness = 6
	light.Parent = flash
	local quick = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(flash, quick, { Size = Vector3.one * 7, Transparency = 1 }):Play()
	TweenService:Create(light, quick, { Brightness = 0 }):Play()
	Debris:AddItem(flash, 0.25)

	local dust = {
		Texture = SMOKE,
		Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.25)),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 6) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.8, 1.6),
		Speed = NumberRange.new(6, 22),
		Drag = 4,
		SpreadAngle = Vector2.new(55, 55),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
		LightInfluence = 1,
	}
	burst(holder, dust, 18) -- back towards the shooter
	local exit = ghost(Vector3.one, CFrame.lookAt(position + direction * 2.5, position + direction * 3.5))
	exit.Transparency = 1
	exit.Parent = workspace
	dust.Speed = NumberRange.new(14, 40)
	dust.SpreadAngle = Vector2.new(30, 30)
	burst(exit, dust, 28) -- punched out the far side

	burst(exit, {
		Texture = SPARK,
		Color = ColorSequence.new(Color3.fromRGB(255, 200, 90)),
		Size = NumberSequence.new(0.35, 0),
		Lifetime = NumberRange.new(0.15, 0.5),
		Speed = NumberRange.new(35, 90),
		Acceleration = Vector3.new(0, -60, 0),
		SpreadAngle = Vector2.new(45, 45),
		LightEmission = 1,
		LightInfluence = 0,
		Orientation = Enum.ParticleOrientation.VelocityParallel,
	}, 30)

	Debris:AddItem(holder, 2)
	Debris:AddItem(exit, 2)
end

return Effects
