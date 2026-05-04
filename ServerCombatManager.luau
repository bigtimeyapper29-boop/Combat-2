--[=[
	Simple Combat System
		by uepV
]=]

-- SERVICES
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

-- FOLDERS
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local Modules = ReplicatedStorage:FindFirstChild("Modules")
local Hitboxes = ReplicatedStorage:FindFirstChild("Hitboxes")
local Sounds = ReplicatedStorage:FindFirstChild("Sounds")

-- MODULES
local zonePlus = require(Modules.Zone)      -- hitbox detection
local Misc = require(Modules.Misc)          -- ragdoll & disable
local PunchRock = require(Modules.PunchRock) -- rock debris

-- REMOTES
local attackRemote = script.Parent:WaitForChild("Attack")
local Replicate = Remotes.Replicate

-- ANIMATIONS
local combatAnims = ReplicatedStorage.Animations.Combat
local getHitAnims = ReplicatedStorage.Animations.GetHit

-- CONSTANTS / CACHED DATA
local ImmunityTag = "Immunity"
local HitboxTemplate = Hitboxes.Combat.M1
local WeldCF = require(HitboxTemplate.weldCF)

-- PER‑PLAYER STATE
local playerStates = {}
local function getState(player: Player)
	local state = playerStates[player]
	if not state then
		state = {
			m1Debounce = false,
			combo = 1,
			doingCombo = 0,
			hitTargets = {},   -- reset every swing
		}
		playerStates[player] = state
	end
	return state
end

--[=[ Helper: play a sound with random pitch and auto‑destroy ]=]
local function playRandomSound(soundTemplate: Sound, parent: Instance)
	local sound = soundTemplate:Clone()
	sound.Parent = parent
	sound.PlaybackSpeed = math.random(8, 12) / 10
	sound:Play()
	task.delay(3, function()
		if sound then sound:Destroy() end
	end)
end

--[=[ Helper: apply a linear velocity for a short time ]=]
local function applyLinearVelocity(part: BasePart, velocity: Vector3, duration: number)
	local attachment = part:FindFirstChild("RootAttachment")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Parent = part
	end
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.MaxForce = 1e6
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VectorVelocity = velocity
	lv.Parent = part
	task.delay(duration, function()
		lv:Destroy()
	end)
end

--[=[ Handlers for the different hit outcomes ]=]

local function handleParry(attackerCharacter: Model, _targetHRP: BasePart, _attackerHRP: BasePart)
	Replicate:FireAllClients("Combat", "HitFX", "Parry", _targetHRP)
	local humanoid = attackerCharacter:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		local parryAnim = animator.LoadAnimation(combatAnims.Parry)
		if parryAnim then
			parryAnim:Play()
			task.delay(1, function()
				if parryAnim then parryAnim:Stop() end
			end)
		end
	end
	Misc.InsertDisabled(attackerCharacter, 0.7)  -- stun the attacker
end

local function handleBlockedHit(targetModel: Model, targetHRP: BasePart, attackerHRP: BasePart)
	Replicate:FireAllClients("Combat", "HitFX", "BlockedHit", targetHRP)
	local blockBar = targetModel:FindFirstChild("BlockBar")
	if blockBar and blockBar:IsA("IntValue") then
		blockBar.Value = math.max(0, blockBar.Value - 5)
	end
	-- small pushback
	applyLinearVelocity(targetHRP, attackerHRP.CFrame.LookVector * 10, 0.16)
end

local function handleNormalHit(
	targetModel: Model,
	targetHumanoid: Humanoid,
	targetHRP: BasePart,
	attackerHRP: BasePart,
	currentCombo: number,
	attackerChar: Model
)
	targetHumanoid:TakeDamage(5)
	Replicate:FireAllClients("Combat", "HitFX", "NormalHit", targetHRP)


	local animator = targetHumanoid:FindFirstChildOfClass("Animator")
	local hurtAnim = animator.LoadAnimation(getHitAnims.Hit1)
	if hurtAnim then
		hurtAnim:Play(0.01, 0.7, 1.3)
	end

	if currentCombo == 4 then
		-- Final combo hit: ragdoll + knockback + rock debris
		PunchRock.Punch(
			attackerHRP.Position,
			attackerHRP.CFrame.LookVector,
			Vector3.new(0, -10, 0),
			15, 2, 30, 0.6, 0.9,
			15, 3, 2, 0.6, 1
		)
		CollectionService:AddTag(targetModel, "Ragdoll")
		task.delay(3, function()
			if targetModel and targetModel.Parent then
				CollectionService:RemoveTag(targetModel, "Ragdoll")
			end
		end)
		applyLinearVelocity(targetHRP, attackerHRP.CFrame.LookVector * 25, 0.5)
	else
		Misc.InsertDisabled(targetModel, 0.5)  -- small stun
	end
end

--[=[ Process a single potential target hit ]=]
local function processTarget(
	targetModel: Model,
	attackerCharacter: Model,
	attackerHRP: BasePart,
	player: Player,
	currentCombo: number
)
	local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if not targetHumanoid or targetHumanoid.Health <= 0 then return end

	local targetHRP = targetModel:FindFirstChild("HumanoidRootPart")
	if not targetHRP then return end

	-- Determine blocking state (stored on the Player instance)
	local targetPlayer = Players:GetPlayerFromCharacter(targetModel)
	local isBlocking = false
	if targetPlayer then
		local blockVal = targetPlayer:FindFirstChild("isBlocking")
		if blockVal and blockVal.Value then
			isBlocking = true
		end
	end

	-- Perfect block (parry)
	if CollectionService:HasTag(targetModel, "Perfect Block") then
		handleParry(attackerCharacter, targetHRP, attackerHRP)
		return
	end

	-- Block check: defender must be facing the attacker (dot < 0.7)
	local dot = attackerHRP.CFrame.LookVector:Dot(targetHRP.CFrame.LookVector)
	if isBlocking and dot < 0.7 then
		handleBlockedHit(targetModel, targetHRP, attackerHRP)
		return
	end

	-- Normal hit
	handleNormalHit(targetModel, targetHumanoid, targetHRP, attackerHRP, currentCombo, attackerCharacter)
end

--[=[ Create the hitbox, detect hits, and apply effects ]=]
local function createHitbox(
	character: Model,
	hrp: BasePart,
	player: Player,
	currentCombo: number,
	hitTargets: {[string]: boolean}
)
	local hitbox = HitboxTemplate:Clone()
	hitbox.Size *= 0.7
	hitbox.CFrame = hrp.CFrame
	hitbox.Parent = hrp

	local weld = Instance.new("Weld")
	weld.Part0 = hrp
	weld.Part1 = hitbox
	weld.C1 = WeldCF
	weld.Parent = hitbox

	local hitzone = zonePlus.new(hitbox)
	hitzone:setAccuracy("Precise")

	local anyHit = false

	for _, part in ipairs(hitzone:getParts()) do
		local targetModel = part.Parent
		-- Skip own character and non‑models
		if targetModel == character or not targetModel:IsA("Model") then continue end

		-- Skip already hit or immune targets
		if hitTargets[targetModel.Name] then continue end
		if CollectionService:HasTag(targetModel, ImmunityTag) then continue end

		-- Mark as hit and grant temporary immunity to prevent multi‑hits
		CollectionService:AddTag(targetModel, ImmunityTag)
		hitTargets[targetModel.Name] = true
		anyHit = true

		-- Process the target
		processTarget(targetModel, character, hrp, player, currentCombo)

		-- Remove immunity after a short delay
		task.delay(0.2, function()
			if targetModel and targetModel.Parent then
				CollectionService:RemoveTag(targetModel, ImmunityTag)
			end
		end)
	end

	if anyHit then
		playRandomSound(Sounds.Hit, character)
	end

	-- Destroy hitbox after 0.3 seconds
	task.delay(0.3, function()
		if hitbox then hitbox:Destroy() end
	end)
end

--[=[ Attack action ]=]
local function onAttack(player: Player, character: Model, humanoid: Humanoid, hrp: BasePart)
	local state = getState(player)
	-- Guards
	if state.m1Debounce then return end
	local isBlockingVal = player:FindFirstChild("isBlocking")
	if isBlockingVal and isBlockingVal.Value then return end
	local disabledVal = character:FindFirstChild("Disabled")
	if disabledVal and disabledVal.Value then return end

	-- Set attacking flag (for external scripts)
	local values = character:FindFirstChild("Values")
	if values then
		local isAttacking = values:FindFirstChild("IsAttacking")
		if isAttacking then
			isAttacking.Value = true
			task.delay(0.5, function() isAttacking.Value = false end)
		end
	end

	state.m1Debounce = true
	state.hitTargets = {}   -- fresh hit list for this swing

	-- Load all combo animations

	local animator = humanoid:FindFirstChildOfClass("Animator")
	local anims = {
		animator.LoadAnimation(combatAnims.A1),
		animator.LoadAnimation(combatAnims.A2),
		animator.LoadAnimation(combatAnims.A3),
		animator.LoadAnimation(combatAnims.A4),
	}

	local currentCombo = state.combo
	state.doingCombo = currentCombo
	local anim = anims[currentCombo]
	anim:Play(0.1, 1, 0.9)

	-- Advance combo (wraps from 4 to 1)
	if currentCombo == 4 then
		state.combo = 1
	else
		state.combo = currentCombo + 1
	end

	-- Fist swing sound
	playRandomSound(Sounds.FistSwing, character)

	-- Animation markers
	local hitMarkerReached = false
	local resetMarkerReached = false

	anim:GetMarkerReachedSignal("Hit"):Connect(function()
		hitMarkerReached = true
		createHitbox(character, hrp, player, currentCombo, state.hitTargets)
	end)

	anim:GetMarkerReachedSignal("DBReset"):Connect(function()
		resetMarkerReached = true
		state.m1Debounce = false
	end)

	-- Fallbacks in case animation markers are skipped
	task.delay(0.5, function()
		if not hitMarkerReached then
			createHitbox(character, hrp, player, currentCombo, state.hitTargets)
		end
	end)

	task.delay(1.2, function()
		if not resetMarkerReached then
			state.m1Debounce = false
		end
	end)

	-- Reset combo if no follow‑up attack within 1.5 seconds
	task.delay(1.5, function()
		if state.combo == 1 and state.doingCombo ~= 0 then
			state.doingCombo = 0
		end
	end)
end

--[=[ Block action ]=]
local function onBlock(player: Player)
	local state = getState(player)
	if state.m1Debounce then return end
	local character = player.Character
	if not character then return end
	if character:FindFirstChild("Disabled") then return end

	local isBlockingVal = player:FindFirstChild("isBlocking")
	if isBlockingVal then
		isBlockingVal.Value = true
	end
end

--[=[ Unblock action ]=]
local function onUnblock(player: Player)
	local isBlockingVal = player:FindFirstChild("isBlocking")
	if isBlockingVal then
		isBlockingVal.Value = false
	end
end

--[=[ Main remote listener ]=]
attackRemote.OnServerEvent:Connect(function(player: Player, action: string)
	local character = player.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp then return end

	if action == "Attack" then
		onAttack(player, character, humanoid, hrp)
	elseif action == "Block" then
		onBlock(player)
	elseif action == "Unblock" then
		onUnblock(player)
	end
end)
