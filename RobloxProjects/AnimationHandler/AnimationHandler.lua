-- Animation Handler: movement (idle/walk/run), fall, emote, ability, etc
-- Will skip tracks of missing animations

local RunService = game:GetService("RunService")

local AnimationHandler = {} --class
AnimationHandler.__index = AnimationHandler --class

-- channels we coordinate to avoid clashing animations
local CHANNELS = { Movement = "Movement", Fall = "Fall", Emote = "Emote", Ability = "Ability" }

local function loadTrack(animator: Animator, anim: Instance?)
	if not animator or not anim or not anim:IsA("Animation") then return nil end
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	return ok and track or nil
end

local function stopTrack(track, fadeTime)
	if track and track.IsPlaying then
		track:Stop(fadeTime or 0.15)
	end
end

function AnimationHandler.new(character: Model, anims: {[string]: Instance})
	local self = setmetatable({}, AnimationHandler)
	
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid")
	self.Animator = self.Humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", self.Humanoid)
	
	-- animation library
	self.Anims = anims or {}
	-- active tracks by channel
	self.Active = {}
	
	-- runtime flags
	self._falling = false
	self._sprinting = false
	self._abilityLock = false
	self._conn = {}
	self._destroyed = false
	
	-- preload/caches
	self._tracks = {
		Idle = loadTrack(self.Animator, self.Anims.Idle),
		Walk = loadTrack(self.Animator, self.Anims.Walk),
		Run = loadTrack(self.Animator, self.Anims.Run),
		Fall = loadTrack(self.Animator, self.Anims.Fall),
	}
	
	self:_hookHumanoid()
	return self
end

-- external API ------

function AnimationHandler:SetSprinting(on: boolean)
	self._sprinting = on and true or false
	self:_refreshMovement()
end

-- if you're using an ability (Hoppa) lock movement loop
function AnimationHandler:SetAbilityLock(on: boolean)
	self._abilityLock = on and true or false
	if on then
		-- pause movement track softly; ability plays on its own
		self:_playOnChannel(CHANNELS.Movement, nil, 0.1) -- stop
	else
		self:_refreshMovement()
	end
end

-- simple emote player (stops when you call again with nil or when character moves)
function AnimationHandler:PlayEmote(anim: Instance?, speed: number?)
	if anim then
		local track = loadTrack(self.Animator, anim)
		if track then
			track:Play(0.2)
			if speed then track:AdjustSpeed(speed) end
			self:_playOnChannel(CHANNELS.Emote, track)
		end
	else
		self:_playOnChannel(CHANNELS.Emote, nil, 0.15) -- stop emote
	end
end

function AnimationHandler:PlayAbility(anim: Instance, speed: number?)
	if not anim then return end

	self:SetAbilityLock(true) -- pauses Movement channel

	local track = self.Animator:LoadAnimation(anim)
	if not track then return end

	-- Try to force high priority on the track (safe if engine disallows)
	pcall(function() track.Priority = Enum.AnimationPriority.Action4 end)

	track.Looped = false
	if speed then track:AdjustSpeed(speed) end

	self:_playOnChannel("Ability", track, 0.1)
	track.Stopped:Connect(function()
		self:_playOnChannel("Ability", nil, 0.1)
		self:SetAbilityLock(false)
	end)
end


function AnimationHandler:Destroy()
	if self._destroyed then return end
	self._destroyed = true
	for _, c in ipairs(self._conn) do c:Disconnect() end
	for _, t in pairs(self.Active) do stopTrack(t, 0.1) end
	self.Active = {}
end

-- internals ----

function AnimationHandler:_playOnChannel(channel: string, track: AnimationTrack?, fadeTime: number?)
	-- stop old
	local old = self.Active[channel]
	if old and old ~= track then
		stopTrack(old, fadeTime or 0.15)
	end
	self.Active[channel] = track
	if track and not track.IsPlaying then
		track:Play(0.15)
	end
end

function AnimationHandler:_hookHumanoid()
	-- state change: fall/land
	table.insert(self._conn, self.Humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Freefall then
			self._falling = true
			self:_playFall()
		elseif new == Enum.HumanoidStateType.Landed 
			or new == Enum.HumanoidStateType.Running
			or new == Enum.HumanoidStateType.RunningNoPhysics
			or new == Enum.HumanoidStateType.Jumping then
			-- leaving fall soon; defer to movement loop
			self._falling = false
			self:_refreshMovement()
		end
	end))
	
	-- Speed updates (fires often, good for switching walk/run/idle)
	table.insert(self._conn, self.Humanoid.Running:Connect(function(speed)
		if not self._falling and not self._abilityLock then
			self:_refreshMovement(speed)
		end
	end))
	
	-- backup: refresh a few times a second
	table.insert(self._conn, RunService.RenderStepped:Connect(function()
		if not self._falling and not self._abilityLock then
			self:_refreshMovement()
		end
	end))
end

function AnimationHandler:_playFall()
	local fall = self._tracks.Fall
	if fall then
		-- stop movement channel while falling
		self:_playOnChannel(CHANNELS.Movement, nil, 0.1)
		self:_playOnChannel(CHANNELS.Fall, fall, 0.1)
	end
end

function AnimationHandler:_refreshMovement(lastSpeed: number?)
	if self._abilityLock then return end
	-- if an emote is playing, let it finish until movement is strong
	local emoteActive = self.Active[CHANNELS.Emote]
	local vel = self.Character.PrimaryPart and self.Character.PrimaryPart.Velocity or Vector3.zero
	local hSpeed = (Vector3.new(vel.X, 0, vel.Z)).Magnitude
	local speed = lastSpeed or hSpeed

	if emoteActive and speed < 0.5 then
		-- keep emote; don't auto-cancel
	elseif emoteActive and speed >= 0.5 then
		-- cancel emote on movement
		self:_playOnChannel(CHANNELS.Emote, nil, 0.15)
	end

	-- choose track
	local target
	if speed < 0.5 then
		target = self._tracks.Idle or nil
	elseif self._sprinting and self._tracks.Run then
		target = self._tracks.Run
	else
		target = self._tracks.Walk or self._tracks.Run
	end

	-- stop fall if any
	self:_playOnChannel(CHANNELS.Fall, nil, 0.1)
	-- start movement
	self:_playOnChannel(CHANNELS.Movement, target, 0.1)

	-- speed scaling for walk/run if playing
	local current = self.Active[CHANNELS.Movement]
	if current and current.IsPlaying then
		-- modest scaling so long strides feel faster
		local scale = math.clamp((speed / (self.Humanoid.WalkSpeed)), 0.5, 1.8)
		current:AdjustSpeed(scale)
	end
end

return AnimationHandler