-- Connected Discord-Github: @f0cus_dev Roblox: @f0cusdev
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local player: Player = Players.LocalPlayer

-- tuning
local TAG: string = "SwingPoint"
local REACH: number = 60
local MIN_ROPE_DIST: number = 4 -- closer than this and the rope jitters
local PULL: number = 15
local LAUNCH_SPEED: number = 40
local SWING_CAP: number = 10
local EXIT_BOOST: number = 1.1
local FAKE_GRAVITY: number = 0.8 -- 1 felt like falling off a cliff
local MIN_AIM_DOT: number = 0.5 -- stops you grabbing stuff behind you

local hooked: boolean = false
local hookTarget: BasePart? = nil
local hookStart: number = 0
local heartbeatConn: RBXScriptConnection? = nil

local char: Model?, hrp: BasePart?, hum: Humanoid? = nil, nil, nil

local linearVelocity: LinearVelocity?, rope: RopeConstraint?, playerAttach: Attachment?, anchorAttach: Attachment?, alignOrientation: AlignOrientation? = nil, nil, nil, nil, nil
local shoulder: Motor6D?, shoulderC0: CFrame?, upperTorso: BasePart?, jumpTrack: AnimationTrack? = nil, nil, nil, nil

local baseWalkSpeed: number = 16
local baseAutoRotate: boolean = true
local timeSinceRelease: number = 0
local needsFailsafe: boolean = false
local lastRingTarget: BasePart? = nil

local rayParams: RaycastParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function buildRing(): (ScreenGui, Frame)
	-- ResetOnSpawn is off so reruns would stack guis
	local old = player.PlayerGui:FindFirstChild("_GrappleUI")
	if old then
		old:Destroy()
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "_GrappleUI"
	screen.ResetOnSpawn = false
	screen.Parent = player.PlayerGui

	local ring = Instance.new("Frame")
	ring.BackgroundTransparency = 1
	ring.Size = UDim2.fromOffset(48, 48)
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Visible = false
	ring.Parent = screen

	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 255, 255)
	stroke.Thickness = 2
	stroke.Parent = ring

	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(4, 4)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.BackgroundColor3 = Color3.fromRGB(0, 255, 255)
	dot.Parent = ring

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	return screen, ring
end

local gui: ScreenGui, ring: Frame = buildRing()

local function flatUnit(v: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude > 0.001 then
		return flat.Unit
	end
	return fallback -- looking straight up/down
end

local function getGroundHit(distance: number): RaycastResult?
	return workspace:Raycast(hrp.Position, Vector3.new(0, -distance, 0), rayParams)
end

local function getNearestAnchor(): BasePart?
	-- runs every frame, hrp isn't there yet at the start
	if not hrp then
		return nil
	end

	local nearest: BasePart?, nearestDist: number = nil, math.huge
	local look: Vector3 = workspace.CurrentCamera.CFrame.LookVector

	for _, part in ipairs(CollectionService:GetTagged(TAG)) do
		if not part:IsA("BasePart") then
			continue
		end

		local offset: Vector3 = part.Position - hrp.Position
		local dist: number = offset.Magnitude

		if dist > MIN_ROPE_DIST and dist < REACH and dist < nearestDist then
			if look:Dot(offset / dist) >= MIN_AIM_DOT then
				nearest = part
				nearestDist = dist
			end
		end
	end

	return nearest
end

local function playSound(soundId: string, position: Vector3): ()
	-- temp attachment so it plays from the spot in the world
	local attach = Instance.new("Attachment")
	attach.Position = position
	attach.Parent = workspace.Terrain

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = 0.75
	sound.Parent = attach
	sound:Play()

	Debris:AddItem(attach, 3)
end

local function restoreArm(): ()
	if jumpTrack then
		jumpTrack:Stop()
		jumpTrack = nil
	end

	if shoulder then -- nil on R6
		shoulder.C0 = shoulderC0
	end

	shoulder, shoulderC0, upperTorso = nil, nil, nil
end

-- also called on death/respawn so some of this might not exist
local function clearSwing(): ()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end

	if linearVelocity then linearVelocity:Destroy() end
	if alignOrientation then alignOrientation:Destroy() end
	if rope then rope:Destroy() end
	if playerAttach then playerAttach:Destroy() end
	if anchorAttach then anchorAttach:Destroy() end

	linearVelocity, alignOrientation, rope, playerAttach, anchorAttach = nil, nil, nil, nil, nil
	restoreArm()
	hookTarget = nil
end

local function restoreCharacter(): ()
	hum.PlatformStand = false
	hum.WalkSpeed = baseWalkSpeed
	hum.AutoRotate = baseAutoRotate
	hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
	hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
	hrp.CanCollide = true
end

local function doRelease(keepMomentum: boolean): ()
	-- mouse up fires on every click, not just hooked ones
	if not hooked then
		return
	end
	hooked = false
	timeSinceRelease = 0
	needsFailsafe = true

	-- must happen before clearSwing or you just drop
	if keepMomentum then
		hrp.AssemblyLinearVelocity = linearVelocity.VectorVelocity * EXIT_BOOST
	end

	restoreCharacter()

	-- PlatformStand sometimes leaves the humanoid stuck, so force a state
	local nextState: Enum.HumanoidStateType = getGroundHit(5) and Enum.HumanoidStateType.Running or Enum.HumanoidStateType.Freefall
	hum:ChangeState(nextState)
	playSound("rbxassetid://12222076", hrp.Position)

	clearSwing()
end

local function aimArm(): ()
	if not shoulder then
		return
	end

	local shoulderPos: Vector3 = (upperTorso.CFrame * shoulderC0).Position
	-- lookAt goes crazy if the points overlap
	if (hookTarget.Position - shoulderPos).Magnitude < 0.5 then
		return
	end

	local aim: CFrame = CFrame.lookAt(shoulderPos, hookTarget.Position)
	-- the extra quarter turn lines up the shoulder axis
	shoulder.C0 = upperTorso.CFrame:ToObjectSpace(aim) * CFrame.Angles(math.pi / 2, 0, 0)
end

local function onSwingTick(dt: number): ()
	-- anchor got deleted while we were hanging on it
	if not hookTarget.Parent then
		doRelease(false)
		return
	end

	if os.clock() - hookStart >= SWING_CAP then
		doRelease(true)
		return
	end

	-- the humanoid keeps undoing these when you touch the floor
	hum.PlatformStand = true
	hrp.CanCollide = false

	local toTarget: Vector3 = hookTarget.Position - playerAttach.WorldPosition
	local dist: number = toTarget.Magnitude
	if dist < 0.001 then
		return
	end
	local dir: Vector3 = toTarget / dist

	-- gravity, otherwise the swing just floats
	local velocity: Vector3 = linearVelocity.VectorVelocity + Vector3.new(0, -workspace.Gravity * FAKE_GRAVITY, 0) * dt

	-- keep the first hop but don't push into the floor
	if os.clock() - hookStart > 0.2 and velocity.Y < 0 and getGroundHit(4.5) then
		velocity = Vector3.new(velocity.X, 0, velocity.Z)
	end

	-- LinearVelocity has infinite force and would drag us past the rope length
	local alongRope: number = velocity:Dot(dir)
	if alongRope < 0 then
		velocity -= dir * alongRope
	end

	-- without this you can orbit forever
	if dist > MIN_ROPE_DIST then
		velocity += dir * PULL * dt
	end
	linearVelocity.VectorVelocity = velocity

	rope.Length = math.max(dist, MIN_ROPE_DIST) -- slack rope sags

	local flatVelocity: Vector3 = Vector3.new(velocity.X, 0, velocity.Z)
	if flatVelocity.Magnitude > 1 then
		alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, flatVelocity.Unit, Vector3.yAxis)
	end

	aimArm()
end

local function removeLeftovers(target: BasePart): ()
	-- a bugged swing can leave stuff behind
	for _, child in ipairs(hrp:GetChildren()) do
		if child.Name == "_pa"
			or child:IsA("LinearVelocity")
			or child:IsA("AlignOrientation")
			or child:IsA("RopeConstraint") then
			child:Destroy()
		end
	end

	for _, child in ipairs(target:GetChildren()) do
		if child.Name == "_aa" then
			child:Destroy()
		end
	end
end

local function captureArm(): ()
	shoulder, shoulderC0, upperTorso = nil, nil, nil
	local torso = char:FindFirstChild("UpperTorso")
	local upperArm = char:FindFirstChild("RightUpperArm")
	local joint = upperArm and upperArm:FindFirstChild("RightShoulder")
	-- R6 still swings, just no arm pose
	if not torso or not joint or not joint:IsA("Motor6D") then
		return
	end

	shoulder, shoulderC0, upperTorso = joint, joint.C0, torso
end

local function buildSwingObjects(target: BasePart): ()
	anchorAttach = Instance.new("Attachment")
	anchorAttach.Name = "_aa"
	anchorAttach.Parent = target

	playerAttach = Instance.new("Attachment")
	playerAttach.Name = "_pa"
	playerAttach.Position = Vector3.new(0, 1, 0)
	playerAttach.Parent = hrp

	rope = Instance.new("RopeConstraint")
	rope.Attachment0 = playerAttach
	rope.Attachment1 = anchorAttach
	rope.Visible = true
	rope.Thickness = 0.18
	rope.Color = BrickColor.new("Cyan")
	rope.Length = (target.Position - playerAttach.WorldPosition).Magnitude
	rope.Parent = hrp

	linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Attachment0 = playerAttach
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.MaxForce = math.huge
	linearVelocity.VectorVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
	linearVelocity.Parent = hrp

	alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = playerAttach
	alignOrientation.RigidityEnabled = true -- wobbled badly without it
	alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, hrp.CFrame.LookVector, Vector3.yAxis)
	alignOrientation.Parent = hrp
end

local function launch(): ()
	local forward: Vector3 = flatUnit(workspace.CurrentCamera.CFrame.LookVector, Vector3.zAxis)
	local currentY: number = hrp.AssemblyLinearVelocity.Y

	-- ground needs more kick
	local minUp: number = getGroundHit(5) and 20 or 10
	local up: number = math.max(currentY, minUp)

	linearVelocity.VectorVelocity = Vector3.new(0, up, 0) + forward * LAUNCH_SPEED
end

local function playJumpPose(): ()
	local animator = hum:FindFirstChildOfClass("Animator")
	local animate = char:FindFirstChild("Animate")
	local jump = animate and animate:FindFirstChild("jump")
	local anim = jump and jump:FindFirstChildOfClass("Animation")

	if animator and anim then
		jumpTrack = animator:LoadAnimation(anim)
		jumpTrack.Priority = Enum.AnimationPriority.Action
		jumpTrack:Play()
	end
end

local function doHook(): ()
	if hooked or not hrp or hum.Health <= 0 then
		return
	end

	local target: BasePart? = getNearestAnchor()
	if not target then
		return
	end

	hooked = true
	needsFailsafe = false
	hookTarget = target
	hookStart = os.clock()

	playSound("rbxassetid://131237241", target.Position)
	removeLeftovers(target)
	captureArm()

	hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
	hrp.AssemblyAngularVelocity = Vector3.zero

	buildSwingObjects(target)

	hum.WalkSpeed = 0
	hum.AutoRotate = false
	hum.PlatformStand = true
	hrp.CanCollide = false -- snagged on the anchor otherwise
	hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)

	launch()
	playJumpPose()

	heartbeatConn = RunService.Heartbeat:Connect(onSwingTick)
end

-- humanoid reapplies PlatformStand a few frames after release sometimes
local function failsafe(dt: number): ()
	if not needsFailsafe then
		return
	end

	timeSinceRelease += dt
	if timeSinceRelease <= 0.5 then
		return
	end

	needsFailsafe = false
	hum.PlatformStand = false
	-- only reset speed if it's still 0
	if hum.WalkSpeed == 0 then
		hum.WalkSpeed = baseWalkSpeed
	end
	hrp.CanCollide = true
end

local function hideRing(): ()
	ring.Visible = false
	lastRingTarget = nil
end

local function updateRing(): ()
	local target: BasePart? = getNearestAnchor()
	if not target then
		hideRing()
		return
	end

	local screenPos: Vector3, onScreen: boolean = workspace.CurrentCamera:WorldToScreenPoint(target.Position)
	if not onScreen then
		hideRing()
		return
	end

	ring.Visible = true
	ring.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)

	-- pop animation, only when the target changes
	if target ~= lastRingTarget then
		lastRingTarget = target
		ring.Size = UDim2.fromOffset(68, 68)
		TweenService:Create(ring, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.fromOffset(48, 48),
		}):Play()
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		doHook()
	elseif input.KeyCode == Enum.KeyCode.Space and hooked then
		doRelease(true)
	end
end)

-- no gameProcessed check here otherwise releasing over UI keeps you hooked
UserInputService.InputEnded:Connect(function(input: InputObject): ()
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		doRelease(true)
	end
end)

RunService.RenderStepped:Connect(function(dt: number): ()
	if hooked then
		ring.Visible = false
		return
	end

	failsafe(dt)
	updateRing()
end)

local function onCharacterAdded(newChar: Model): ()
	-- CharacterAdded can happen without Died
	if hooked then
		hooked = false
		clearSwing()
	end

	needsFailsafe = false
	char = newChar
	hrp = char:WaitForChild("HumanoidRootPart", 10)
	hum = char:WaitForChild("Humanoid", 10)
	-- parts never loaded, leave hrp nil so the grapple stays off
	if not hrp or not hum then
		hrp = nil
		return
	end

	baseWalkSpeed = hum.WalkSpeed
	baseAutoRotate = hum.AutoRotate
	rayParams.FilterDescendantsInstances = { char }

	hum.Died:Once(function(): ()
		hooked = false
		clearSwing()
	end)
end

if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

script.Destroying:Connect(function(): ()
	clearSwing()
	gui:Destroy()
end)
