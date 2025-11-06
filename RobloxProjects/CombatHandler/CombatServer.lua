-- ServerScriptService/CombatServer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService      = game:GetService("SoundService")
local Debris            = game:GetService("Debris")
local Players           = game:GetService("Players")

local WeaponInfo       = require(script.WeaponsInfo)
local CooldownService  = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CooldownService"))
local HitboxService    = require(script.Parent:WaitForChild("HitboxService"))
local ElegantSlash     = require(script.Parent.Skills.ElegantSlash)

local Animations = ReplicatedStorage.Animations
local Remotes    = ReplicatedStorage.Remotes

local LastSwingTick = {}
local DEFAULT_WALK  = 16

-- ========== Utils ==========
local function validTool(char)
	if not char:GetAttribute("Combo") then
		char:SetAttribute("Combo", 1)
	end
	local tool = char:FindFirstChildOfClass("Tool")
	if tool and tool:GetAttribute("Weapon") then
		return tool
	end
	return nil
end

local function setAttacking(char, value)
	char:SetAttribute("Attacking", value and true or nil)
end

local function playSound(audio, parent)
	if not audio or not parent then return end
	local s = audio:Clone()
	s.Parent = parent
	local rp = s:FindFirstChild("RandomPitch")
	if rp then rp.Octave = Random.new():NextNumber(0.9, 1.1) end
	s:Play()
	Debris:AddItem(s, s.TimeLength + 0.25)
end

local function playSoundIfExists(folder, name, parent)
	if not folder or not parent then return end
	playSound(folder:FindFirstChild(name) or folder:FindFirstChild(name:gsub("_","")), parent)
end

local function slowDuring(hum, mult, dur)
	if not hum or hum.Health <= 0 then return end
	local original = hum.WalkSpeed
	hum.WalkSpeed = math.max(6, (original > 0 and original or DEFAULT_WALK) * (mult or 0.75))
	task.delay(dur, function()
		if hum and hum.Parent then hum.WalkSpeed = original end
	end)
	return original -- return for failsafe restore
end

local function dealDamage(_, targetHum, amount)
	if not targetHum or targetHum.Health <= 0 then return end
	targetHum:TakeDamage(amount)
end

local function runHitboxPulse(attackerChar, cf, size, dmg, soundsFolder)
	local hits = HitboxService:BoxSweep(attackerChar, cf, size)
	for _, h in ipairs(hits) do
		dealDamage(attackerChar, h.Hum, dmg)
		if soundsFolder and soundsFolder:FindFirstChild("Hit") then
			playSound(soundsFolder.Hit, attackerChar.HumanoidRootPart)
		end
		Remotes.Visuals:FireAllClients("SlashFX", attackerChar, cf) -- VFX hook at impact
	end
end

-- ========== Core M1 ==========
local function doM1(plr, char, hum, weaponTool)
	-- hard gate: no overlap
	if char:GetAttribute("Attacking") then return end
	setAttacking(char, true)

	local currentWeaponName = weaponTool:GetAttribute("Weapon")
	local wInfo = WeaponInfo[weaponTool.Name]
	if not wInfo then setAttacking(char, nil) return end

	local comboIdx = char:GetAttribute("Combo")
	local cInfo = wInfo.Combo and wInfo.Combo[comboIdx]
	if not cInfo then setAttacking(char, nil) return end

	local animator     = hum:FindFirstChildOfClass("Animator")
	local animFolder   = Animations.Weapons[currentWeaponName]
	local soundsFolder = SoundService.Weapons[weaponTool.Name]
	local attackAnim   = animator:LoadAnimation(animFolder.M1s[comboIdx])

	LastSwingTick[plr] = os.clock()
	attackAnim:Play()

	-- SFX: finisher has unique sound if present
	local isFinisher = comboIdx == (wInfo.MaxCombo or 4)
	local finisherSound
	if isFinisher then
		local sfx = soundsFolder:FindFirstChild("SwingFinisher")
		if sfx then
			finisherSound = sfx:Clone()
			finisherSound.Parent = char.HumanoidRootPart
			finisherSound:Play()
			Debris:AddItem(finisherSound, finisherSound.TimeLength + 0.25)
		end
	else
		local s = soundsFolder and (soundsFolder:FindFirstChild("Swing") or soundsFolder:FindFirstChild("Swing_Short"))
		if s then
			local c = s:Clone()
			c.Parent = char.HumanoidRootPart
			c:Play()
			Debris:AddItem(c, c.TimeLength + 0.25)
		end
	end

	-- Trail for attack window
	Remotes.Visuals:FireAllClients("WeaponTrail", char, cInfo.AttackSpeed)


	-- Slow while attacking (and remember original for failsafe)
	local originalSpeed = slowDuring(hum, wInfo.AttackSlowMultiplier or 0.75, cInfo.AttackSpeed + (isFinisher and (cInfo.FinisherRecovery or 0.3) or 0))

	-- === Timing via Animation Marker "Hit" (preferred) with Windup fallback ===
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local fired = false
	local sentM1VFX = false
	local hitConn

	local function sendM1VFXAt(cf)
		if sentM1VFX then return end
		sentM1VFX = true

		local localCF = hrp and hrp.CFrame:ToObjectSpace(cf) or CFrame.new()

		-- Optional: let WeaponsInfo control burst size (fallback to 20)
		local emitCount
		if wInfo.M1VFXEmitCountPerCombo and wInfo.M1VFXEmitCountPerCombo[comboIdx] then
			emitCount = wInfo.M1VFXEmitCountPerCombo[comboIdx]
		else
			emitCount = wInfo.M1VFXEmitCount or 20
		end

		-- send: character, local-offset CF, duration, comboIdx, emitCount
		Remotes.Visuals:FireAllClients("M1LightPierce", char, localCF, cInfo.AttackSpeed, comboIdx, emitCount)
	end


	if attackAnim.GetMarkerReachedSignal then
		hitConn = attackAnim:GetMarkerReachedSignal("Hit"):Connect(function()
			if fired then return end
			fired = true

			if hrp then
				local cf   = hrp.CFrame * (cInfo.HitboxOffset or CFrame.new(0,0,-3))
				local size = cInfo.HitboxSize or Vector3.new(5,5,5)

				-- fire VFX at that static position/orientation
				sendM1VFXAt(cf)

				if not isFinisher then
					runHitboxPulse(char, cf, size, wInfo.Damage or 20, soundsFolder)
				else
					local pulses = cInfo.FlurryPulses or 3
					local dt     = cInfo.FlurryInterval or 0.08
					for _ = 1, pulses do
						runHitboxPulse(char, cf, size, wInfo.FinisherDamage or (wInfo.Damage or 20), soundsFolder)
						task.wait(dt)
					end
				end
			end
		end)
	end

	-- Fallback: if marker didn't fire, use Windup delay
	task.delay(cInfo.Windup or 0.1, function()
		if fired then return end
		if hrp then
			local cf   = hrp.CFrame * (cInfo.HitboxOffset or CFrame.new(0,0,-3))
			local size = cInfo.HitboxSize or Vector3.new(5,5,5)

			

			if not isFinisher then
				runHitboxPulse(char, cf, size, wInfo.Damage or 20, soundsFolder)
			else
				local pulses = cInfo.FlurryPulses or 3
				local dt     = cInfo.FlurryInterval or 0.08
				for _ = 1, pulses do
					runHitboxPulse(char, cf, size, wInfo.FinisherDamage or (wInfo.Damage or 20), soundsFolder)
					task.wait(dt)
				end
			end
		end
	end)

	-- Recovery and cleanup
	local total = cInfo.AttackSpeed + (isFinisher and (cInfo.FinisherRecovery or 0.3) or 0)
	task.wait(total)

	if finisherSound and finisherSound.IsPlaying then finisherSound:Stop() end
	if hitConn then hitConn:Disconnect() end
	setAttacking(char, nil)
	if hum and hum.Parent and originalSpeed then hum.WalkSpeed = originalSpeed end

	-- Advance/Reset combo
	local maxC = wInfo.MaxCombo or 4
	if comboIdx < maxC then
		char:SetAttribute("Combo", comboIdx + 1)
	else
		char:SetAttribute("Combo", 1)
	end
	task.delay(wInfo.ComboResetTime or 1.8, function()
		if os.clock() - (LastSwingTick[plr] or 0) >= (wInfo.ComboResetTime or 1.8) then
			char:SetAttribute("Combo", 1)
		end
	end)
end



-- ========== Dash / Specials (unchanged skeletons) ==========
local function doDash(plr)
	if not CooldownService:IsReady(plr, "Dash") then return end
	CooldownService:Start(plr, "Dash", 0.8)

	local char = plr.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	local hrp  = char and char:FindFirstChild("HumanoidRootPart")
	if not (char and hum and hrp and hum.Health > 0) then return end
	if char:GetAttribute("Stunned") then return end

	local look = hrp.CFrame.LookVector
	hrp.AssemblyLinearVelocity = Vector3.new(look.X, 0, look.Z) * 60 + Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
	char:SetAttribute("IFrames", true)
	Remotes.Visuals:FireAllClients("DashFX", char)
	task.delay(0.25, function()
		if char then char:SetAttribute("IFrames", nil) end
	end)
end

local function doSpecial(plr, key)
	local char = plr.Character
	if not char then return end
	local hum  = char:FindFirstChildOfClass("Humanoid")
	local weaponTool = validTool(char)
	if not hum or not weaponTool then return end

	local weaponName   = weaponTool.Name
	local currentWeapon= weaponTool:GetAttribute("Weapon")
	local wInfo        = WeaponInfo[weaponName]
	if not wInfo then return end

	if key == "R" then
		local s = wInfo.Skill_ElegantSlash
		if not s then return end

		if not CooldownService:IsReady(plr, "ElegantSlash") then return end
		CooldownService:Start(plr, "ElegantSlash", s.Cooldown or 10)

		if char:GetAttribute("Attacking") or char:GetAttribute("Stunned") then return end
		char:SetAttribute("Attacking", true)

		local animFolder  = ReplicatedStorage.Animations.Weapons[currentWeapon] and ReplicatedStorage.Animations.Weapons[currentWeapon].Skills
		local soundsFolder= SoundService.Weapons[weaponName]

		local ok, err = pcall(function()
			ElegantSlash.Execute({
				plr = plr, char = char, hum = hum, weaponTool = weaponTool,
				settings = s, animFolder = animFolder, soundsFolder = soundsFolder,
				Remotes = Remotes
			})
		end)
		if not ok then warn("[ElegantSlash] error:", err) end

		-- short post-lock to avoid immediate overlaps
		task.wait(0.2)
		char:SetAttribute("Attacking", nil)
	end
end



-- ========== Remote handling ==========
Remotes.Combat.OnServerEvent:Connect(function(plr, action, param)
	local char = plr.Character
	if not char then return end
	local hum  = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end

	if action == "VFX" then
		-- client asks us to broadcast equip/unequip visuals
		if param == "Equip" then
			Remotes.Visuals:FireAllClients("EquipFX", char)
		elseif param == "Unequip" then
			Remotes.Visuals:FireAllClients("UnequipFX", char)
		end
		return
	end

	-- hard gate against overlaps
	if char:GetAttribute("Attacking") and action ~= "Dash" then return end

	local weaponTool = validTool(char)
	if (action ~= "Dash") and not weaponTool then return end

	if action == "M1" and not char:GetAttribute("Stunned") then
		doM1(plr, char, hum, weaponTool)
	elseif action == "Dash" then
		doDash(plr)
	elseif action == "Special" then
		doSpecial(plr, param)
	end
end)
