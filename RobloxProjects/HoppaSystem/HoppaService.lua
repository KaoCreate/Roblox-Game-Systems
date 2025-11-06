-- HoppaService Module
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local Events = ReplicatedStorage:WaitForChild("Events")
local NoticeRE = Events:WaitForChild("ShowHoppaNotice")

local StatsService = require(ReplicatedStorage.Modules:WaitForChild("StatsService"))
local DataStoreHandler = require(game.ServerScriptService:WaitForChild("DataStoreHandler"))
local QuestService = require(game.ReplicatedStorage.Modules.Quest.QuestService)
local LB = require(game.ServerScriptService:WaitForChild("LeaderboardService"))
local WingService = require(game.ServerScriptService:WaitForChild("WingService"))


local HoppaService = {}
local ActiveHop = {}
local HoppaScale = {}
local lastScaleAt = {}
local ActiveGlide = {}


local Net = require(ReplicatedStorage.Modules.Net)
local E = Net.Names.Events


local function lerp(a, b, t) return a + (b - a) * t end
local function clamp01(x) return math.max(0, math.min(1, x)) end
local function easeOutCubic(t) return 1 - (1 - t)^3 end
local function expApproach(cur, target, sharpness, dt)
	return target + (cur - target) * math.exp(-sharpness * dt)
end

local BASE_WALK = 16
local SprintGuard: {[Player]: {prev: number, conn: RBXScriptConnection?}} = {}

-- Auto-glide trigger when player is falling (not in Hoppa)
local FALL_TO_GLIDE = {
	minFreefallTime   = 0.65,
	minHeightAboveHit = 28,
	minDownSpeed      = -12,
	retriggerDelay    = 2.0,
}

-- === Hoppa Restrictions ===
local CONFIG = {
	BlockInNoHoppaZones = true,
	BlockWhenAirborne   = true,

	GroundMode = "TAGGED_PARTS",  -- "TAGGED_PARTS" or "Y_THRESHOLD"
	GroundTag  = "HoppaGround",
	GroundYMax = 10,

	BlockCooldown = 2,

	RayLength = 50,
	MaxGroundGap = 6,
}

-- === Glide Settings ===
local GLIDE = {
	initialGravityScale   = 0.10,
	finalGravityScale     = 0.55,
	initialXZSpeed        = 18,
	finalXZSpeed          = 60,
	initialTerminalFall   = -18,
	finalTerminalFall     = -48,
	rampTime              = 6.0,

	preStickDist          = 1.2,
	landingHold           = 1.0,
	maxTime               = 90,
}

-- === Landing Pads (for Finish Glide) ===
local LANDING = {
	PadTag = "HoppaLandingPad", -- tag the pad they end on
	SnapOffset = 0.05,          -- hover a hair above the surface
}

local function startNoSprint(player: Player, humanoid: Humanoid?)
	if not humanoid or SprintGuard[player] then return end
	local prev = humanoid.WalkSpeed
	humanoid:SetAttribute("HoppaNoSprint", true)
	humanoid.WalkSpeed = math.min(prev or BASE_WALK, BASE_WALK)
	
	local conn; conn = RunService.Heartbeat:Connect(function()
		-- Stop guarding if player/humanoid goes away
		if not player.Parent or not humanoid.Parent then
			if conn then conn:Disconnect() end
			return
		end
		-- While ascending or gliding, keep WalkSpeed from exceeding base
		if ActiveHop[player] or humanoid:GetAttribute("IsGliding") or humanoid:GetAttribute("HoppaNoSprint") then
			if humanoid.WalkSpeed ~= BASE_WALK then
				humanoid.WalkSpeed = BASE_WALK
			end
		else
			if conn then conn:Disconnect() end
		end
	end)

	SprintGuard[player] = { prev = prev, conn = conn }
end

local function stopNoSprint(player: Player, humanoid: Humanoid?)
	local g = SprintGuard[player]
	if not g then return end
	if g.conn then g.conn:Disconnect() end
	if humanoid and humanoid.Parent then
		-- Restore the old speed (after landing hold finishes)
		humanoid.WalkSpeed = g.prev or BASE_WALK
		humanoid:SetAttribute("HoppaNoSprint", false)
	end
	SprintGuard[player] = nil
end


local function _getTaggedPads()
	local pads = {}
	for _, inst in ipairs(CollectionService:GetTagged(LANDING.PadTag)) do
		if inst:IsA("BasePart") and inst.Parent then
			table.insert(pads, inst)
		end
	end
	return pads
end

local function _nearestPadXZ(pos: Vector3)
	local pads = _getTaggedPads()
	local best, bestD2
	for _, pad in ipairs(pads) do
		local dx = pos.X - pad.Position.X
		local dz = pos.Z - pad.Position.Z
		local d2 = dx*dx + dz*dz
		if not bestD2 or d2 < bestD2 then
			best, bestD2 = pad, d2
		end
	end
	return best
end


local function deriveGlideFromHeight(H)
	local f = clamp01((H - 50) / 550)
	return {
		initialGravityScale = lerp(GLIDE.initialGravityScale, 0.50, f),
		finalGravityScale   = lerp(GLIDE.finalGravityScale,   1.10, f),
		initialXZSpeed      = lerp(GLIDE.initialXZSpeed,      30,   f),
		finalXZSpeed        = lerp(GLIDE.finalXZSpeed,        90,  f),
		initialTerminalFall = lerp(GLIDE.initialTerminalFall, -32,  f),
		finalTerminalFall   = lerp(GLIDE.finalTerminalFall,   -140, f),
		rampTime            = lerp(GLIDE.rampTime,             2.4,  f),
		preStickDist        = GLIDE.preStickDist,
		landingHold         = GLIDE.landingHold,
		maxTime             = lerp(GLIDE.maxTime,             120,  f),
	}
end

-- === Ascent (ballistic-only, matches old BV+ballistic height) ===
local ASCENT = {
	minHeight       = 10,
	maxHeight       = 20000,  -- tune for whales
	baseHeight      = 0,      -- exact old mapping had no base
	assistTime      = 0.0,    -- no second push; keep pure ballistic
	xzDampTime      = 0.8,
	xzDampSharpness = 24.0,
}

local function getAnim(name1, name2, name3)
	local anims = ReplicatedStorage:FindFirstChild("Animations")
	if not anims then return nil end
	return (name1 and anims:FindFirstChild(name1))
		or (name2 and anims:FindFirstChild(name2))
		or (name3 and anims:FindFirstChild(name3))
end

local function playLandingAnim(humanoid: Humanoid)
	local landAnim = getAnim("GlideLand","Landing","LandingImpact")
	if not landAnim then return end
	local track = humanoid:LoadAnimation(landAnim)
	track:Play(0.05, 1, 1.0)
end

local function _clearHoppaForces(root: BasePart)
	if not root then return end
	for _, inst in ipairs(root:GetChildren()) do
		if inst:IsA("BodyVelocity") or inst:IsA("VectorForce") or inst:IsA("LinearVelocity")
			or inst:IsA("BodyGyro") or inst:IsA("AngularVelocity") then
			inst:Destroy()
		end
	end
	local align = root:FindFirstChildWhichIsA("AlignPosition")
	if align then align:Destroy() end
	local stickAtt = root:FindFirstChild("HoppaStickAtt")
	if stickAtt then stickAtt:Destroy() end
end

local function ensureThrownFolder()
	local f = workspace:FindFirstChild("Thrown")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Thrown"
		f.Parent = workspace
	end
	return f
end

local _fallWatch = {}
local _lastGlideAt = {}

local function _cleanupFallWatch(player)
	local w = _fallWatch[player]
	if w then
		if w.conn then w.conn:Disconnect() end
		_fallWatch[player] = nil
	end
end

local function _groundBelow(root: BasePart, char: Instance)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	return workspace:Raycast(root.Position + Vector3.new(0,2,0), Vector3.new(0,-10000,0), rp)
end

function HoppaService._bindFallWatcher(player)
	_cleanupFallWatch(player)
	local w = { tFree = 0, conn = nil }
	_fallWatch[player] = w

	w.conn = RunService.Heartbeat:Connect(function(dt)
		local char = player.Character
		if not char then w.tFree = 0 return end
		local root = char:FindFirstChild("HumanoidRootPart")
		local hum  = char:FindFirstChildOfClass("Humanoid")
		if not (root and hum) then w.tFree = 0 return end

		-- don't autoglide if hopping or already gliding
		if ActiveHop[player] or (ActiveGlide and ActiveGlide[player]) then
			w.tFree = 0
			return
		end

		local vy = root.AssemblyLinearVelocity.Y
		local falling = hum.FloorMaterial == Enum.Material.Air and vy < -0.1
		if not falling then w.tFree = 0 return end

		w.tFree += dt
		if w.tFree < FALL_TO_GLIDE.minFreefallTime then return end

		local hit = _groundBelow(root, char)
		local dist = hit and (root.Position.Y - hit.Position.Y) or math.huge
		if dist < FALL_TO_GLIDE.minHeightAboveHit then return end
		if vy > FALL_TO_GLIDE.minDownSpeed then return end

		local now = os.clock()
		if _lastGlideAt[player] and now - _lastGlideAt[player] < FALL_TO_GLIDE.retriggerDelay then
			return
		end
		_lastGlideAt[player] = now

		local apexAltitude = dist
		HoppaService._startGlide(player, root, hum, { apexHeight = apexAltitude }, function()
			local char2 = player.Character
			if char2 and CollectionService:HasTag(char2, "HoppaCD") then
				CollectionService:RemoveTag(char2, "HoppaCD")
			end
			ActiveHop[player] = nil
			hum.WalkSpeed = 16
			local tool = char2 and char2:FindFirstChild("HoppaTool")
			if tool then tool:SetAttribute("IsCasting", false); tool.Enabled = true end
			local Stop = Events:FindFirstChild("StopHoppaAnim")
			if Stop then Stop:FireClient(player) end
		end)
		w.tFree = 0
	end)
end

Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function()
		HoppaService._bindFallWatcher(p)
	end)
end)
for _,p in ipairs(Players:GetPlayers()) do
	if p.Character then HoppaService._bindFallWatcher(p) end
	p.CharacterAdded:Connect(function()
		HoppaService._bindFallWatcher(p)
	end)
end
Players.PlayerRemoving:Connect(function(p)
	_cleanupFallWatch(p)
	_lastGlideAt[p] = nil
end)

local function stickToGround(root: BasePart, hitPos: Vector3, holdTime: number, humanoid: Humanoid)
	local att = Instance.new("Attachment"); att.Name = "HoppaStickAtt"; att.Parent = root
	local align = Instance.new("AlignPosition")
	align.Attachment0 = att
	align.RigidityEnabled = true
	align.MaxForce = 1e7
	align.Responsiveness = 200
	align.ApplyAtCenterOfMass = true
	align.Parent = root

	local stand = (humanoid and humanoid.HipHeight or 0) + 2.4
	align.Position = hitPos + Vector3.new(0, stand, 0)

	root.AssemblyLinearVelocity  = Vector3.new(0,0,0)
	root.AssemblyAngularVelocity = Vector3.new(0,0,0)
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	end

	task.delay(holdTime or 1.0, function()
		if align then align:Destroy() end
		if att and att.Parent then att:Destroy() end
		if humanoid then
			humanoid.WalkSpeed = 16
			humanoid.JumpPower = 50
		end
	end)
end

local function spawnFXInstanceAtRoot(tpl: Instance, root: BasePart, lifetime: number?)
	local thrown = ensureThrownFolder()
	local function handleChild(inst: Instance)
		if inst:IsA("Sound") then
			local s = inst:Clone()
			s.Parent = root
			s:Play()
			Debris:AddItem(s, (s.TimeLength or 1.5) + 0.5)
		elseif inst:IsA("ParticleEmitter") then
			local pe = inst:Clone()
			pe.Parent = root
			pe:Emit( math.max(tonumber(pe:GetAttribute("EmitCount")) or 5, 1) )
			Debris:AddItem(pe, lifetime or 2)
		elseif inst:IsA("Attachment") then
			local at = inst:Clone()
			at.Parent = root
			for _, sub in ipairs(inst:GetChildren()) do
				if sub:IsA("ParticleEmitter") then
					local pe = sub:Clone()
					pe.Parent = at
					pe:Emit( math.max(tonumber(pe:GetAttribute("EmitCount")) or 40, 1) )
					Debris:AddItem(pe, lifetime or 2)
				end
				if sub:IsA("Sound") then
					local s = sub:Clone()
					s.Parent = at; s:Play()
					Debris:AddItem(s, (s.TimeLength or 1.5) + 0.5)
				end
			end
			Debris:AddItem(at, lifetime or 2)
		elseif inst:IsA("BasePart") then
			local p = inst:Clone()
			p.CFrame = root.CFrame
			p.Parent = thrown
			Debris:AddItem(p, lifetime or 2)
		elseif inst:IsA("Model") then
			local m = inst:Clone()
			local pp = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			if pp then m:PivotTo(root.CFrame) end
			m.Parent = thrown
			for _, sub in ipairs(m:GetDescendants()) do
				if sub:IsA("ParticleEmitter") then sub:Emit( tonumber(sub:GetAttribute("EmitCount")) or 5 ) end
				if sub:IsA("Sound") then sub:Play() end
			end
			Debris:AddItem(m, lifetime or 2.5)
		end
	end
	if tpl:IsA("Folder") or tpl:IsA("Model") then
		for _, child in ipairs(tpl:GetChildren()) do handleChild(child) end
		return
	end
	handleChild(tpl)
end

local function getVFX(name: string)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild(name)
end
local function getSFX(name: string)
	local sounds = ReplicatedStorage:FindFirstChild("Sounds")
	return sounds and sounds:FindFirstChild(name)
end

local function playPeakFX(root: BasePart)
	local vfx = getVFX("HoppaPeakVFX") or getVFX("HoppaPeakFX")
	local sfx = getSFX("HoppaPeakSfx") or getSFX("HoppaPeakFX")
	if vfx then spawnFXInstanceAtRoot(vfx, root, 2) end
	if sfx then spawnFXInstanceAtRoot(sfx, root, 2) end
end

local function playRecordFX(root: BasePart)
	local vfx = getVFX("HoppaRecordVFX") or getVFX("HoppaRecordFX")
	local sfx = getSFX("HoppaRecordSfx") or getSFX("HoppaRecordFX")
	if vfx then spawnFXInstanceAtRoot(vfx, root, 3) end
	if sfx then spawnFXInstanceAtRoot(sfx, root, 3) end
end

local _lastNoticeAt = {}
local function sendNotice(player, key)
	local now = os.clock()
	if _lastNoticeAt[player] and (now - _lastNoticeAt[player]) < 0.3 then return end
	_lastNoticeAt[player] = now
	Net:fireClient(player, E.ShowHoppaNotice, key)
end

local function hasTagInAncestry(inst, tagName)
	local cur = inst
	while cur do
		if CollectionService:HasTag(cur, tagName) then
			return true
		end
		cur = cur.Parent
	end
	return false
end

local function getGroundRefTopY()
	local parent = workspace
	for _, name in ipairs(CONFIG.GroundRefPath or {}) do
		parent = parent:FindFirstChild(name)
		if not parent then return nil end
	end
	if not parent or not parent:IsA("BasePart") then return nil end
	return parent.Position.Y + parent.Size.Y * 0.5
end

local function rayDownFrom(root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {root.Parent}
	return workspace:Raycast(root.Position, Vector3.new(0, -CONFIG.RayLength, 0), params)
end


function HoppaService.CanHoppaHere(player, root, humanoid)
	if CONFIG.BlockWhenAirborne and humanoid.FloorMaterial == Enum.Material.Air then
		return false, "Airborne"
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { player.Character }
	local result = workspace:Raycast(root.Position + Vector3.new(0, 2, 0), Vector3.new(0, -CONFIG.RayLength, 0), rp)
	local hit = result and result.Instance
	if hit then
		if CONFIG.BlockInNoHoppaZones and hasTagInAncestry(hit, "NoHoppaZone") then
			return false, "NoHoppaZone"
		end
		local dy = (root.Position.Y - result.Position.Y)
		local groundedByRay = (dy >= -1 and dy <= CONFIG.MaxGroundGap)
		if CONFIG.GroundMode == "TAGGED_PARTS" then
			local onAllowedGround = hasTagInAncestry(hit, CONFIG.GroundTag)
			if groundedByRay and onAllowedGround then
				return true
			else
				return false, "OnlyGround"
			end
		else
			if groundedByRay and root.Position.Y <= CONFIG.GroundYMax then
				return true
			else
				return false, "OnlyGround"
			end
		end
	else
		return false, "OnlyGround"
	end
end

local function getCharacterParts(player)
	local character = player.Character
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local tool = character:FindFirstChild("HoppaTool")
	if not root or not humanoid or not tool then return end
	return character, root, humanoid, tool
end

function HoppaService.Perform(player)
	local character, root, humanoid, tool = getCharacterParts(player)
	if not character or not tool then return end
	if ActiveHop[player] then return end
	if CollectionService:HasTag(character, "HoppaCD") then
		sendNotice(player, "Cooldown")
		return
	end
	if tool:GetAttribute("IsCasting") then return end

	local allowed, reasonKey = HoppaService.CanHoppaHere(player, root, humanoid)
	if not allowed then
		local cd = CONFIG.BlockCooldown
		CollectionService:AddTag(character, "HoppaCD")
		tool:SetAttribute("IsCasting", false)
		tool.Enabled = false
		sendNotice(player, reasonKey or "OnlyGround")
		task.delay(cd, function()
			if character and CollectionService:HasTag(character, "HoppaCD") then
				CollectionService:RemoveTag(character, "HoppaCD")
			end
			if tool then tool.Enabled = true end
		end)
		return
	end

	local stats = StatsService:Get(player)
	if not stats then return end

	-- Slider: same as before
	local alpha = HoppaService.GetScale(player) -- 0..1
	local Pmax = math.max(stats.jumpPower or 0, 0)
	
	-- NEW: Wings Multiplier
	local wingMul = 1
	pcall(function() wingMul = WingService.GetHoppaMultiplier(player) end)
	Pmax = Pmax * (wingMul or 1)
	
	local effectivePower = math.exp(alpha * math.log(Pmax + 1)) - 1
	if effectivePower <= 0 then return end

	ActiveHop[player] = true
	CollectionService:AddTag(character, "HoppaCD")
	tool:SetAttribute("IsCasting", true)
	tool.Enabled = false
	startNoSprint(player, humanoid)
	

	local anim = ReplicatedStorage:FindFirstChild("Animations")
	anim = anim and anim:FindFirstChild("HoppaCast")
	if anim then
		local track = humanoid:LoadAnimation(anim)
		track:Play()
		track:AdjustSpeed(1.2)
	end

	_clearHoppaForces(root)

	task.delay(0.15, function()
		HoppaService._createTornado(player, root, humanoid, tool, stats, effectivePower, alpha)
	end)
end

-- compute a good "main ground" Y for Finish button (lowest tagged ground, or fallback)
local function getMainGroundY()
	local y = getGroundRefTopY()
	if y then return y end
	local lowest = math.huge
	for _, inst in ipairs(CollectionService:GetTagged(CONFIG.GroundTag)) do
		if inst:IsA("BasePart") then
			local top = inst.Position.Y + inst.Size.Y * 0.5
			if top < lowest then lowest = top end
		end
	end
	return (lowest ~= math.huge) and lowest or 0
end

local function probeGround(root: BasePart, char: Instance)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }

	local origins = {
		root.Position + Vector3.new( 0,  2, 0),
		root.Position + root.CFrame.RightVector*1.5 + Vector3.new(0,2,0),
		root.Position - root.CFrame.RightVector*1.5 + Vector3.new(0,2,0),
		root.Position + root.CFrame.LookVector*1.5  + Vector3.new(0,2,0),
		root.Position - root.CFrame.LookVector*1.5  + Vector3.new(0,2,0),
	}

	local best, bestDist
	for _, o in ipairs(origins) do
		local res = workspace:Raycast(o, Vector3.new(0, -100, 0), rp)
		if res then
			local d = (o.Y - res.Position.Y)
			if not bestDist or d < bestDist then
				best, bestDist = res, d
			end
		end
	end

	return best, bestDist or math.huge
end

-- Internal: Tornado + Force + Reward
function HoppaService._createTornado(player, root, humanoid, tool, stats, effectivePower, alpha)
	local ok, err = pcall(function()
		_clearHoppaForces(root)
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

		local tornadoTpl = ReplicatedStorage.Assets:FindFirstChild("Tornado")
		if tornadoTpl then
			ensureThrownFolder()
			local tornado = tornadoTpl:Clone()
			local power = effectivePower
			local vizScale = math.clamp(power / 100, 0, 1)
			tornado.Size = tornado.Size * (0.1 + 0.9 * vizScale)
			local offsetY = tornado.Size.Y / 2
			tornado.CFrame = root.CFrame * CFrame.new(0, offsetY, -2) * CFrame.Angles(math.rad(180), 0, 0)
			tornado.Parent = workspace.Thrown
			if tornado:FindFirstChild("Sound") then tornado.Sound:Play() end
			TweenService:Create(tornado, TweenInfo.new(0.2, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
				CFrame = tornado.CFrame * CFrame.Angles(0, math.rad(45), 0)
			}):Play()
			Debris:AddItem(tornado, 2.5)
		end

		-- === Ascent: match old BV(0.6s at v=50*ln(1+P)) + ballistic apex ===
		_clearHoppaForces(root)
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

		local g = workspace.Gravity
		local L = math.log(1 + math.max(effectivePower, 0)) -- natural log
		local A = 30.0                                    -- distance covered during 0.6s BV (50 * 0.6)
		local B = (50 * 50) / (2 * g)                     -- ballistic extra height term
		local desiredH = ASCENT.baseHeight + A * L + B * (L * L)
		desiredH = math.clamp(desiredH, ASCENT.minHeight, ASCENT.maxHeight)

		local vy0 = math.sqrt(2 * g * desiredH)

		-- small nudge off the floor prevents immediate ground contact by physics
		root.CFrame = root.CFrame + Vector3.new(0, 0.1, 0)
		root.AssemblyLinearVelocity = Vector3.new(0, vy0, 0)

		-- declare BEFORE closures (prevents upvalue glitches)
		local liftBV = nil
		local watchdogFired = false

		task.delay(1.0, function()
			if watchdogFired then return end
			watchdogFired = true
			if liftBV then liftBV:Destroy() end
			ActiveHop[player] = nil
			tool:SetAttribute("IsCasting", false)
			tool.Enabled = true
			stopNoSprint(player, humanoid)
			local char = player.Character
			if char and CollectionService:HasTag(char, "HoppaCD") then
				CollectionService:RemoveTag(char, "HoppaCD")
			end
			local Stop = Events:FindFirstChild("StopHoppaAnim")
			if Stop then Stop:FireClient(player) end
		end)

		if (ASCENT.assistTime or 0) > 0 then
			liftBV = Instance.new("BodyVelocity")
			liftBV.Name = "HoppaLift"
			liftBV.MaxForce = Vector3.new(0, 1e7, 0)
			liftBV.P = 9000
			liftBV.Velocity = Vector3.new(0, vy0, 0)
			liftBV.Parent = root
			Debris:AddItem(liftBV, ASCENT.assistTime)
		end

		-- damp XZ to go straight up initially
		local riseStart = os.clock()
		local ascendConn; ascendConn = RunService.Heartbeat:Connect(function(dt)
			local since = os.clock() - riseStart
			if since > ASCENT.xzDampTime then
				if ascendConn then 
					ascendConn:Disconnect() 
					ascendConn = nil
				end
				return
			end
			local v = root.AssemblyLinearVelocity
			local nx = v.X + (0 - v.X) * (1 - math.exp(-ASCENT.xzDampSharpness * dt))
			local nz = v.Z + (0 - v.Z) * (1 - math.exp(-ASCENT.xzDampSharpness * dt))
			root.AssemblyLinearVelocity = Vector3.new(nx, v.Y, nz)
		end)

		-- measure apex, reward, then glide
		local startY, peakY = root.Position.Y, root.Position.Y
		local leftGround = false
		local startTime = os.clock()

		local connection, diedConn
		diedConn = humanoid.Died:Connect(function()
			if connection then connection:Disconnect() end
			if diedConn then diedConn:Disconnect() end
			if liftBV then liftBV:Destroy() end
			ActiveHop[player] = nil
			tool:SetAttribute("IsCasting", false)
			stopNoSprint(player, humanoid)
			tool.Enabled = true
			local Stop = Events:FindFirstChild("StopHoppaAnim")
			if Stop then Stop:FireClient(player) end
		end)

		connection = RunService.Heartbeat:Connect(function()
			local y = root.Position.Y
			if y > peakY then peakY = y end
			if y > startY + 1 then leftGround = true end
			if leftGround then watchdogFired = true end

			local falling = (root.AssemblyLinearVelocity.Y <= 0)
			if falling and leftGround and os.clock() - startTime >= 0.5 then
				connection:Disconnect()
				if diedConn then diedConn:Disconnect() end
				if liftBV then liftBV:Destroy() end

				local height = math.floor(peakY - startY)
				local reward = math.floor(height / 5)
				local bonus  = math.floor(reward * stats:getMoneyMultiplier())

				stats:addMoney(bonus)
				Net:fireClient(player, E.UpdateMoney, stats.money)
				Net:fireClient(player, E.ShowFeedback, "+" .. bonus .. " Money")
				QuestService.OnHoppaUsed(player)
				QuestService.OnWorldEvent(player, "HoppaUsed")
				require(game.ServerScriptService.Libraries.SaveQueue).enqueue(player)

				local isRecord
				if stats.updateHighestAltitude then
					isRecord = stats:updateHighestAltitude(height)
				else
					isRecord = height > (stats.highestAltitude or 0)
					if isRecord then stats.highestAltitude = height end
				end
				LB.UpdateMaxAltitude(player.UserId, stats.highestAltitude)

				if isRecord then
					playRecordFX(root)
					local ShowHoppaRecord = Events:FindFirstChild("ShowHoppaRecord")
					if ShowHoppaRecord then
						ShowHoppaRecord:FireClient(player, height)
					end
				else
					playPeakFX(root)
				end

				local rp = RaycastParams.new()
				rp.FilterType = Enum.RaycastFilterType.Exclude
				rp.FilterDescendantsInstances = { player.Character }
				local groundAtApex = workspace:Raycast(root.Position + Vector3.new(0,2,0), Vector3.new(0,-10000,0), rp)
				local apexAltitude = groundAtApex and (root.Position.Y - groundAtApex.Position.Y) or height

				HoppaService._startGlide(player, root, humanoid, { apexHeight = apexAltitude }, function()
					local char = player.Character
					if char and CollectionService:HasTag(char, "HoppaCD") then
						CollectionService:RemoveTag(char, "HoppaCD")
					end
					ActiveHop[player] = nil
					humanoid.WalkSpeed = 16
					tool:SetAttribute("IsCasting", false)
					tool.Enabled = true
					local Stop = Events:FindFirstChild("StopHoppaAnim")
					if Stop then Stop:FireClient(player) end
				end)
			end
		end)
	end)

	if not ok then
		warn("[HoppaService] Ascent error: ", err)
		ActiveHop[player] = nil
		local char = player.Character
		if char and CollectionService:HasTag(char, "HoppaCD") then
			CollectionService:RemoveTag(char, "HoppaCD")
		end
		if tool then tool:SetAttribute("IsCasting", false); tool.Enabled = true end
		local Stop = Events:FindFirstChild("StopHoppaAnim")
		if Stop then Stop:FireClient(player) end
	end
end

-- Start gliding; calls onLanded() when the player truly touches down.
function HoppaService._startGlide(player, root: BasePart, humanoid: Humanoid, arg4, arg5)
	local params, onLanded
	if typeof(arg4) == "table" then params, onLanded = arg4, arg5 else params, onLanded = {}, arg4 end
	local H  = tonumber(params.apexHeight) or 0
	local G  = deriveGlideFromHeight(H)
	local char = player.Character
	if not (char and root and humanoid) then return end
	
	startNoSprint(player, humanoid)
	
	humanoid:SetAttribute("IsGliding", true)

	local att = Instance.new("Attachment"); att.Name = "GlideAtt"; att.Parent = root
	local vf  = Instance.new("VectorForce"); vf.Attachment0 = att; vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.Name   = "GlideForce"; vf.Parent = root

	local bv  = Instance.new("BodyVelocity"); bv.Name = "GlideXZ"
	bv.MaxForce = Vector3.new(8e5, 0, 8e5)  -- was 1e6
	bv.Velocity = Vector3.zero
	bv.P = 7000                             -- was 6000
	bv.Parent = root

	local glideTrack
	do
		local glideAnim = getAnim("GlideLoop")
		if glideAnim then
			glideTrack = humanoid:LoadAnimation(glideAnim)
			glideTrack:Play(0.15, 1, 1.0)
		end
	end
	local glideLoop
	do
		local sounds = ReplicatedStorage:FindFirstChild("Sounds")
		local tpl = sounds and sounds:FindFirstChild("HoppaGlideLoop")
		if tpl then
			glideLoop = tpl:Clone(); glideLoop.Looped = true
			glideLoop.Parent = root; glideLoop:Play()
		end
	end

	local function updateUpForce(curG)
		local mass = root.AssemblyMass or 0
		local g    = workspace.Gravity
		vf.Force   = Vector3.new(0, mass * g * (1 - curG), 0)
	end

	local function cleanup()
		if glideLoop and glideLoop.Parent then glideLoop:Stop(); glideLoop:Destroy() end
		if glideTrack then glideTrack:Stop(0.1) end
		if bv and bv.Parent then bv:Destroy() end
		if vf and vf.Parent then vf:Destroy() end
		if att and att.Parent then att:Destroy() end
		
		if humanoid and humanoid.Parent then
			humanoid:SetAttribute("IsGliding", false)
		end
	end
	
	local diedConn
	diedConn = humanoid.Died:Connect(function()
		if conn then conn:Disconnect() end
		cleanup()
		local GlideState = Events:FindFirstChild("GlideState")
		if GlideState then GlideState:FireClient(player, "stop") end
		ActiveGlide[player] = nil
		stopNoSprint(player, humanoid)
		if diedConn then diedConn:Disconnect() end
	end)

	local GlideState = Events:FindFirstChild("GlideState")
	if GlideState then GlideState:FireClient(player, "start") end

	local finished = false
	local function finishAt(hitPos: Vector3?)
		if finished then return end
		finished = true

		cleanup()
		
		if diedConn then diedConn:Disconnect() end
		
		root.AssemblyLinearVelocity  = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero

		-- FX/SFX + shake + anim
		local function spawnLandingRubble(rootPart: BasePart, pieces: number?, life: number?)
			local count = pieces or 5
			local lifeTime = life or 2
			local folder = ensureThrownFolder()
			for i = 1, count do
				local p = Instance.new("Part")
				p.Name = "LandingRubble"
				p.Size = Vector3.new(math.random(2,4)/10, math.random(2,4)/10, math.random(2,4)/10)
				p.Material = Enum.Material.Concrete
				p.Color = Color3.fromRGB(86, 42, 13)
				p.Anchored = false
				p.CanCollide = true
				p.Massless = true
				p.CFrame = rootPart.CFrame * CFrame.new(math.random(-4,4)/10, -1, math.random(-4,4)/10)
				p.Parent = folder
				p.AssemblyLinearVelocity = Vector3.new(math.random(-12,12), math.random(8,14), math.random(-12,12))
				Debris:AddItem(p, lifeTime)
			end
		end
		spawnLandingRubble(root, 4, 2)
		
		if GlideState then GlideState:FireClient(player, "stop") end
		
		local crash = (ReplicatedStorage.Sounds and ReplicatedStorage.Sounds:FindFirstChild("HoppaCrash"))
		if crash then spawnFXInstanceAtRoot(crash, root, 2) end
		local HoppaImpact = Events:FindFirstChild("HoppaImpact")
		if HoppaImpact then HoppaImpact:FireClient(player, { duration = 0.45, amplitude = 1.6 }) end
		local dust = getVFX("LandingDustVFX")
		if dust then spawnFXInstanceAtRoot(dust, root, 1.5) end
		playLandingAnim(humanoid)

		local safePos = hitPos or (root.Position - Vector3.new(0, root.Size.Y/2, 0))
		stickToGround(root, safePos, G.landingHold or 1.0, humanoid)
		

		task.delay((G.landingHold or 1.0) + 0.05, function()
			if onLanded then onLanded() end
			stopNoSprint(player, humanoid)
		end)

		
		ActiveGlide[player] = nil
	end

	ActiveGlide[player] = function()
		-- Prefer a tagged landing pad
		local pad = _nearestPadXZ(root.Position)
		if pad and pad:IsA("BasePart") and pad.Parent then
			local topY = pad.Position.Y + pad.Size.Y * 0.5
			local snapPos = Vector3.new(pad.Position.X, topY, pad.Position.Z)
			-- place slightly above the surface, then finish
			root.CFrame = CFrame.new(snapPos + Vector3.new(0, (humanoid.HipHeight + 2.4 + LANDING.SnapOffset), 0))
			finishAt(snapPos)
			return
		end

		-- Fallback: original behavior (ray or main ground)
		local mainY = getMainGroundY()
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { player.Character }
		
		
		local from = root.Position + Vector3.new(0, 2000, 0)
		local hit = workspace:Raycast(from, Vector3.new(0, -10000, 0), rp)
		local pos = hit and hit.Position or Vector3.new(root.Position.X, mainY, root.Position.Z)
		root.CFrame = CFrame.new(pos + Vector3.new(0, (humanoid.HipHeight + 2.4), 0))
		finishAt(pos)
	end


	local t0 = os.clock()
	local H0 = math.max(H, 1)
	local conn; conn = RunService.Heartbeat:Connect(function(dt)
		local pt = clamp01((os.clock() - t0) / (G.rampTime or 2.0))
		local bestHit, dist = probeGround(root, char)
		local remain = bestHit and (root.Position.Y - bestHit.Position.Y) or H0
		local ph = 1 - clamp01(remain / H0)
		local e  = easeOutCubic(math.max(pt, ph))

		-- blended params
		local curG    = lerp(G.initialGravityScale,   G.finalGravityScale,   e)
		local curXZ   = lerp(G.initialXZSpeed,        G.finalXZSpeed,        e)
		local curTerm = lerp(G.initialTerminalFall,   G.finalTerminalFall,   e)

		-- gravity & vertical velocity shaping first
		updateUpForce(curG)

		local vel   = root.AssemblyLinearVelocity
		local newVy = expApproach(vel.Y, curTerm, 22.0, dt)
		if newVy < curTerm then newVy = curTerm end
		root.AssemblyLinearVelocity = Vector3.new(vel.X, newVy, vel.Z)

		-- gate sideways speed by how fast we're falling (skydiver feel)
		local fallFactor = clamp01(((-newVy) - 12) / 80)   -- stricter than 60; tweak 60–100
		local maxXZ = math.min(curXZ, 90) * fallFactor     -- optional hard cap at ~90

		-- steer toward the capped target with “heavier” response
		local md = humanoid.MoveDirection
		local wanted = (md.Magnitude > 0) and (md.Unit * maxXZ) or Vector3.zero
		local curHV = Vector3.new(bv.Velocity.X, 0, bv.Velocity.Z)
		local newHX = expApproach(curHV.X, wanted.X, 5.0, dt)  -- 4–6 = weighty
		local newHZ = expApproach(curHV.Z, wanted.Z, 5.0, dt)
		bv.Velocity = Vector3.new(newHX, 0, newHZ)
		

		local speed = math.abs(newVy)
		local preStick = (G.preStickDist or 1.2) + math.clamp(speed * 0.035, 0, 4.0)

		if (bestHit and dist <= preStick and newVy <= -1) or humanoid.FloorMaterial ~= Enum.Material.Air then
			if conn then conn:Disconnect() end
			finishAt(bestHit and bestHit.Position or nil)
			return
		end

		if os.clock() - t0 > (G.maxTime or 120) then
			if conn then conn:Disconnect() end
			finishAt(bestHit and bestHit.Position or nil)
			return
		end
	end)
end

function HoppaService.SetScale(player, alpha)
	alpha = tonumber(alpha) or 1
	alpha = math.clamp(alpha, 0,1)
	local now = os.clock()
	if lastScaleAt[player] and now - lastScaleAt[player] < 0.1 then return end
	lastScaleAt[player] = now
	HoppaScale[player] = alpha
end

function HoppaService.GetScale(player)
	return HoppaScale[player] or 1
end

Players.PlayerRemoving:Connect(function(player)
	_cleanupFallWatch(player)
	_lastGlideAt[player] = nil
	_lastNoticeAt[player] = nil       -- done
	ActiveHop[player] = nil           -- done
	ActiveGlide[player] = nil         -- done
	HoppaScale[player] = nil
	lastScaleAt[player] = nil
	
	local g = SprintGuard[player]
	if g and g.conn then g.conn:Disconnect() end
	SprintGuard[player] = nil
end)


function HoppaService.FinishGlide(player)
	local fin = ActiveGlide[player]
	if fin then fin() end
end


return HoppaService
