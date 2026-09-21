---@omw-context local
-- ============================================================================
-- OSSC: Shared NPC / Creature item quickcasting
-- Shared implementation for scrolls and cast-on-use enchanted items.
--
-- IMPORTANT: This module does not own an onUpdate AI loop. NPC/Creature
-- decision loops are responsible for deciding WHEN to quickcast. This module
-- only contains the shared item resolution/casting implementation and event
-- handlers used during an already-started cast.
-- ============================================================================
local self    = require('openmw.self')
local core    = require('openmw.core')
local types   = require('openmw.types')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')
local util    = require('openmw.util')
local vfs     = require('openmw.vfs')
local I       = require('openmw.interfaces')
local async   = require('openmw.async')
-- Friendlier Fire gate. Item quick-casts go through Spell Framework Plus,
-- which applies spells from Lua and bypasses FF's sweep, so OSSC detects
-- friendly fire itself (mirroring FF's test) before consuming the item and
-- firing a harmful spell at a friendly.
local friendlyFire = require('scripts.ossc.ossc_friendlyfire')
local Penalty = require('scripts.ossc.ossc_penalty')
-- Launch offsets are user-editable data (scripts/ossc/ossc_launch_offsets.lua).
local launchOffsets = require('scripts.ossc.ossc_launch_offsets')

local SCRIPT_PATH = 'scripts/ossc/ossc_actor_items.lua'
local RANGE = core.magic.RANGE
local ENCHANTMENT_TYPE = core.magic.ENCHANTMENT_TYPE

local generalSettings   = storage.globalSection('SettingsOSSC_General')
local npcSettings       = storage.globalSection('SettingsOSSC_NPC')
local animationSettings = storage.globalSection('SettingsOSSC_Animations')
local animSpeedSettings = storage.globalSection('SettingsOSSC_AnimSpeeds')

local function settingOr(section, key, default)
    local value = section:get(key)
    if value == nil then return default end
    return value
end

-- ── Spell classification ───────────────────────────────────────────────────
-- Shared with the global script through scripts/ossc/ossc_caster_utils.lua.
-- A partial/stale install must not take the actor script down (a `require`
-- of a missing data file throws), so probe the VFS and fall back to the same
-- record-based scan locally. `Actor.spells` also contains passive Abilities,
-- so those must never make a non-biped creature eligible.
local CASTER_UTILS_FILE   = 'scripts/ossc/ossc_caster_utils.lua'
local CASTER_UTILS_MODULE = 'scripts.ossc.ossc_caster_utils'

local function builtinHasCastableSpell(actor, allowPowers)
    local knownSpells = types.Actor.spells(actor)
    if not knownSpells then return false end
    local SPELL_TYPE = core.magic.SPELL_TYPE
    local spellRecords = core.magic.spells.records
    for _, knownSpell in pairs(knownSpells) do
        local spellId = knownSpell
        if type(knownSpell) ~= 'string' then spellId = knownSpell.id end
        local record = spellId and spellRecords[spellId]
        if record and (record.type == SPELL_TYPE.Spell
            or (allowPowers == true and record.type == SPELL_TYPE.Power)) then
            return true
        end
    end
    return false
end

local casterUtils
if vfs.fileExists(CASTER_UTILS_FILE) then
    casterUtils = require(CASTER_UTILS_MODULE)
else
    print('[OSSC-ITEM] ' .. CASTER_UTILS_FILE .. ' unavailable (module not found: ' .. CASTER_UTILS_MODULE
        .. '); using the built-in spell classifier. Update/reinstall OSSC.')
    casterUtils = { hasCastableSpell = builtinHasCastableSpell }
end

-- ── Cast state ─────────────────────────────────────────────────────────────
local isCasting = false
local currentCastId = 0
local currentAnimGroup = nil
local currentSpell = nil
local currentTarget = nil
local fired = false
local nextCastAllowedTime = 0
-- Simulation time after which every cast timer created by this script has
-- certainly fired (see armDetachAck below).
local pendingTimersUntil = 0.0
-- NGarde parry-after-cast lock owned by this script (see
-- setNgardeParryControl below); only ever cleared when this script set it.
-- Spell casts (ossc_npc) and item casts can never overlap, so the two scripts
-- cannot fight over NGarde's single external-control boolean.
local ngardeParryControlActive = false
local ngardeCompatWarned = false

local SCHOOL_STRS = {
    [0] = 'alteration', [1] = 'conjuration', [2] = 'destruction',
    [3] = 'illusion', [4] = 'mysticism', [5] = 'restoration',
}

local RANGE_STRS = {
    [RANGE.Self] = 'Self', [RANGE.Touch] = 'Touch', [RANGE.Target] = 'Target',
}

local ANIM_BY_SCHOOL_AND_RANGE = {
    destruction = { [RANGE.Self]='quickbuff', [RANGE.Touch]='qcdrain', [RANGE.Target]='quickcast' },
    restoration = { [RANGE.Self]='quickbuff', [RANGE.Touch]='qcdrain', [RANGE.Target]='quickcast' },
    alteration  = { [RANGE.Self]='quickbuff', [RANGE.Touch]='qctouch', [RANGE.Target]='qcalt' },
    illusion    = { [RANGE.Self]='quickbuff', [RANGE.Touch]='qctouch', [RANGE.Target]='qcill' },
    conjuration = { [RANGE.Self]='qcconj', [RANGE.Touch]='qctouch', [RANGE.Target]='qcconj' },
    mysticism   = { [RANGE.Self]='qcsnap', [RANGE.Touch]='qctouch', [RANGE.Target]='quickcast' },
}

-- Settings key of the per-school/range animation choice, built once.
local ANIM_SETTING_KEYS = {}
for school in pairs(ANIM_BY_SCHOOL_AND_RANGE) do
    local schoolKey = school:sub(1, 1):upper() .. school:sub(2)
    local keys = {}
    for range, rangeStr in pairs(RANGE_STRS) do
        keys[range] = 'Anim_' .. schoolKey .. '_' .. rangeStr .. '_3rd'
    end
    ANIM_SETTING_KEYS[school] = keys
end

local QUICKCAST_GROUPS = {
    'quickcast', 'quickbuff', 'qcconj', 'qctouch', 'qcalt', 'qcalts',
    'qcill', 'qcsnap', 'qcdrain', 'qcskrow', 'eqcastr',
}

local LIGHT_ATTACK_GROUPS = { 'weapononehand', 'weapononehand1', 'handtohand', 'throwweapon' }

local SPEED_KEYS = {
    quickcast = 'AnimSpeed_Quickcast', quickbuff = 'AnimSpeed_Quickbuff', qcconj = 'AnimSpeed_Qcconj',
    qctouch = 'AnimSpeed_Qctouch', qcalt = 'AnimSpeed_Qcalt', qcalts = 'AnimSpeed_Qcalts',
    qcill = 'AnimSpeed_Qcill', qcsnap = 'AnimSpeed_Qcsnap', qcdrain = 'AnimSpeed_Qcdrain',
    qcskrow = 'AnimSpeed_Qcskrow',
}

local UP = util.vector3(0, 0, 1)
local FORWARD = util.vector3(0, 1, 0)
local LEFT = util.vector3(-1, 0, 0)
local TARGET_CHEST_OFFSET = util.vector3(0, 0, 60)

local function isEligibleActor()
    -- NPCs always use the humanoid actor path. The master NPC toggle is
    -- re-checked live (same rule as the creature toggles below) so disabling
    -- it also stops item quick-casts on an already-attached NPC.
    if self.type == types.NPC then
        return settingOr(npcSettings, 'NPCQuickCastEnabled', true) == true
    end
    if self.type ~= types.Creature then return false end

    -- Master creature toggle (mirrors the global attachment gate so a setting
    -- change also stops item quick-casts on an already-attached creature).
    if not settingOr(npcSettings, 'NPCQuickCastCreatures', true) then return false end

    -- Keep the Creature record's real `isBiped` field as the first criterion.
    local record = types.Creature.record(self)
    if record and record.isBiped == true then return true end

    -- Non-bipeds qualify dynamically when their Actor spell list contains an
    -- actual castable spell, and only while the dedicated non-biped creature
    -- toggle is enabled. Passive Abilities never qualify them.
    if not settingOr(npcSettings, 'NPCQuickCastNonBipedCreatures', true) then return false end
    return casterUtils.hasCastableSpell(self, settingOr(npcSettings, 'NPCQuickCastAllowPowers', false))
end
local isEligible = isEligibleActor()

local function log(msg)
    print(string.format('[OSSC-ITEM %s] %s', tostring(self.recordId), tostring(msg)))
end

local function isOverEncumbered(actor)
    local encumbrance = types.Actor.getEncumbrance(actor)
    local capacity = types.Actor.getCapacity(actor)
    return type(encumbrance) == 'number'
        and type(capacity) == 'number'
        and encumbrance > capacity
end

local function incapacitated()
    if types.Actor.isDead(self) then return true end
    -- Actor.canMove is also false while overencumbered, but over capacity only
    -- stops locomotion — never item/scroll casting. Exclude encumbrance here
    -- (same rule as ossc_npc.lua / ossc_player.lua) so an over-loaded actor's
    -- item quick-casts are not silently refused by startCast.
    if not types.Actor.canMove(self) and not isOverEncumbered(self) then return true end
    local activeEffects = types.Actor.activeEffects(self)
    local silence = activeEffects and activeEffects:getEffect('silence')
    return silence ~= nil and (silence.magnitude or 0) > 0
end

local function anyGroupPlaying(groups)
    for i = 1, #groups do
        if anim.isPlaying(self, groups[i]) then return true end
    end
    return false
end

-- ── Item resolution ────────────────────────────────────────────────────────
local function getRecord(item)
    if not item or not item:isValid() then return nil end
    local objectType = item.type
    if not objectType or not objectType.record then return nil end
    return objectType.record(item)
end

local function isScroll(item, enchantmentType)
    if enchantmentType == ENCHANTMENT_TYPE.CastOnce then return true end
    if item.type ~= types.Book then return false end
    local book = types.Book.record(item)
    return book ~= nil and book.isScroll == true
end

-- [ENCHANT FORMULA] Same formula as OSSC's player implementation and the
-- global charge consumer.
local function getEffectiveCost(baseCost)
    local skill = 0
    if self.type == types.NPC then
        skill = types.NPC.stats.skills.enchant(self).modified or 0
    end
    return math.max(1, math.floor(0.01 * (110 - skill) * baseCost))
end

local function resolveItem(item)
    local record = getRecord(item)
    local enchantId = record and record.enchant
    if not enchantId or enchantId == '' then return nil end
    local enchantment = core.magic.enchantments.records[enchantId]
    if not enchantment then return nil end
    if enchantment.type ~= ENCHANTMENT_TYPE.CastOnUse and enchantment.type ~= ENCHANTMENT_TYPE.CastOnce then
        return nil
    end

    local charge = enchantment.charge or 0
    local itemData = types.Item.itemData(item)
    if itemData and itemData.enchantmentCharge ~= nil then charge = itemData.enchantmentCharge end

    local cost = getEffectiveCost(enchantment.cost or 1)
    if enchantment.type == ENCHANTMENT_TYPE.CastOnUse and charge < cost then return nil end

    return {
        id = enchantId,
        item = item,
        record = record,
        enchantment = enchantment,
        effects = enchantment.effects,
        cost = cost,
        isScroll = isScroll(item, enchantment.type),
        charge = charge,
    }
end

-- Every castable scroll / cast-on-use item in the inventory (fresh list).
local function findItems()
    local result = {}
    local inventory = types.Actor.inventory(self)
    if not inventory then return result end
    local allItems = inventory:getAll()
    for i = 1, #allItems do
        local resolved = resolveItem(allItems[i])
        if resolved then result[#result + 1] = resolved end
    end
    return result
end

-- ── Targeting ──────────────────────────────────────────────────────────────
local function getTarget()
    local ai = I.AI
    if not ai then return nil end
    local target = nil
    if ai.getActiveTarget then target = ai.getActiveTarget('Combat') end
    if not target and ai.getTarget then target = ai.getTarget() end
    if target and target:isValid() and not types.Actor.isDead(target) then return target end
    return nil
end

-- NPCs and the player always use the biped skeleton; creatures only when
-- their record carries the biped flag. Anything else (or an invalid handle)
-- takes the bone-free path — never assume biped bones on an unknown target.
local function isBipedActor(actor)
    if not actor or not actor:isValid() then return false end
    if actor.type == types.NPC or actor.type == types.Player then return true end
    if actor.type ~= types.Creature then return false end
    local record = types.Creature.record(actor)
    return record ~= nil and record.isBiped == true
end

local function targetPoint(target)
    -- The spine lookup is biped-only: on a non-biped target the bone does not
    -- exist, so go straight to the body offset instead of erroring.
    if isBipedActor(target)
        and (type(anim.hasBone) ~= 'function' or anim.hasBone(target, 'Bip01 Spine2')) then
        local transform = anim.getBoneTransform and anim.getBoneTransform(target, 'Bip01 Spine2')
        if transform and transform.position then
            return target.position + target.rotation * transform.position
        end
    end
    return target.position + TARGET_CHEST_OFFSET
end

-- Per-animation launch offsets (see scripts/ossc/ossc_launch_offsets.lua).
-- Actors always use the 'third' table applied from the actor origin along
-- the actor's facing.
local function spawnPos()
    local offset = launchOffsets.get(currentAnimGroup, false)
    local rotation = self.rotation
    return self.position
        + (rotation * FORWARD) * offset.forward
        + (rotation * LEFT) * offset.left
        + UP * offset.up
end

local function schoolAndRange(spell)
    local firstEffect = spell.effects and spell.effects[1]
    if not firstEffect then return 'destruction', RANGE.Target end
    local range = firstEffect.range or RANGE.Target
    local mgef = core.magic.effects.records[firstEffect.id]
    local school = mgef and mgef.school
    if type(school) == 'string' then return school:lower(), range end
    return SCHOOL_STRS[school] or 'destruction', range
end

local function getQuickCastEffectScale(spell)
    -- Scrolls (CastOnce enchantments) are excluded when the scroll toggle is
    -- on, so a scroll cast lands at full strength.  Cast-on-use enchanted
    -- items stay penalised either way.  (Powers cannot quick-cast from an
    -- item.)
    if settingOr(generalSettings, 'QuickCastEffectPenaltyScrollsExempt', false) == true
        and spell and spell.isScroll then
        return 1.0
    end
    -- 'skill_based' follows the actor's Enchant skill; anything else is a
    -- flat percentage (or off).
    local mode = settingOr(generalSettings, 'QuickCastEffectPenalty', 'off')
    if Penalty.isSkillBased(mode) then
        local enchant = self.type == types.NPC and types.NPC.stats.skills.enchant
        local skill = enchant and enchant(self)
        return Penalty.skillScale(skill and skill.modified or 0)
    end
    return Penalty.scale(mode)
end

local function chooseAnimation(spell)
    local school, range = schoolAndRange(spell)
    local settingKeys = ANIM_SETTING_KEYS[school]
    local group = settingKeys and animationSettings:get(settingKeys[range])
    if group and group ~= '' then return group end
    local bySchool = ANIM_BY_SCHOOL_AND_RANGE[school]
    return bySchool and bySchool[range] or 'quickcast'
end

-- Parry-after-cast lock (mirror of the player script's setNgardeParryControl):
-- while an item quick-cast owns the hands, NGarde must refuse new guard
-- raises. See the ossc_npc.lua copy for the full rationale; released by
-- cleanup() on every cast-end path.
local function setNgardeParryControl(active)
    local settingOn = settingOr(generalSettings, 'BlockDuringNGardeParry', true)
    active = (active == true) and (settingOn and true or false)
    local fencer = I.NGardeFencer
    if fencer and type(fencer.externalParryControl) == 'function' then
        if active and type(fencer.forceLowerGuard) == 'function' then
            fencer.forceLowerGuard()
        end
        fencer.externalParryControl(active)
        ngardeParryControlActive = active
    else
        ngardeParryControlActive = false
        if active and fencer ~= nil and not ngardeCompatWarned then
            ngardeCompatWarned = true
            log('WARNING: BlockDuringNGardeParry is on but I.NGardeFencer.externalParryControl is missing — update NGarde')
        end
    end
end

local function cleanup()
    if ngardeParryControlActive then setNgardeParryControl(false) end
    isCasting = false
    currentAnimGroup = nil
    currentSpell = nil
    currentTarget = nil
    fired = false
end

-- Scroll/charge consumption for item quick-casts happens in exactly one place:
-- Spell Framework Plus's launch resource guard (the request below is sent with
-- isFree = false, and ossc_player.lua's handleCastCosts documents the same
-- contract for the player).  An earlier local OSSC_ConsumeScroll /
-- OSSC_ConsumeCharge pre-consume here double-spent every cast; those global
-- handlers still exist in scripts/ossc/ossc_global.lua for other callers.

local CAST_USER_DATA = { OSSC = true, NPC = true, CREATURE = true, ITEM = true }

local function fire(spell, target)
    if fired or not isCasting or not spell or not spell.item then return end
    fired = true
    local _, range = schoolAndRange(spell)
    local start = spawnPos()
    local direction = self.rotation * FORWARD
    local hitObject = nil
    if range == RANGE.Self then
        target, hitObject = self, self
    elseif target and target:isValid() then
        direction = (targetPoint(target) - start):normalize()
        if range == RANGE.Touch then hitObject = target end
    else
        target = nil
    end

    -- Friendlier Fire: don't consume the item or fire a harmful spell at a
    -- friendly target. Spell Framework Plus applies OSSC casts from Lua, which
    -- bypasses FF's sweep, so detect friendly fire here before spending the
    -- item.
    if range ~= RANGE.Self and target and target ~= self
        and friendlyFire.isFriendlyFireBlocked(self, target, spell.effects) then
        log('ITEM QUICKCAST VETOED — friendly fire: ' .. tostring(spell.id) .. ' -> ' .. tostring(target.recordId))
        return
    end

    -- The scroll/charge cost is consumed by Spell Framework Plus's launch
    -- resource guard (isFree = false on the request below) — the same single
    -- consumer the player path uses (see ossc_player.lua handleCastCosts).
    -- Consuming here as well used to remove a SECOND scroll per cast (and
    -- double-charge enchanted items), and for the last copy it emptied the
    -- stack before SFP's guard could see it: the guard then rejected the cast
    -- with "no valid enchanted item" after the cast animation had already
    -- played — a visible cast that dealt no effect at all.  The
    -- OSSC_ConsumeScroll / OSSC_ConsumeCharge global handlers remain
    -- available for other callers, but this path must not use them when SFP
    -- performs the deduction at launch.
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker = self,
        caster = self,
        spellId = spell.id,
        startPos = start,
        direction = direction,
        area = 0,
        isFree = false,
        item = spell.item,
        itemRecordId = spell.item.recordId,
        hitObject = hitObject,
        spawnOffset = 80,
        isGodMode = false,
        effectScale = getQuickCastEffectScale(spell),
        showAllCastVfx = true,
        userData = CAST_USER_DATA,
    })
    log(string.format('ITEM QUICKCAST: item=%s enchant=%s range=%s scroll=%s cost=%d',
        tostring(spell.item.recordId), tostring(spell.id), tostring(range), tostring(spell.isScroll), spell.cost))
end

-- NGarde parry block: while this actor is holding up a parry guard (or is in
-- the wind-up to raise it) a quick-cast must not start, whether it is a spell
-- or a scroll/enchanted-item cast — the hands are committing to a block and the
-- cast would play over the guard. No-op when NGarde is absent (its interfaces
-- are only registered by NGarde's own scripts) or the actor is not parrying.
local function isParryingViaNgarde()
    local fencer = I.NGardeFencer
    if not fencer then return false end
    if type(fencer.isParrying) == 'function' and fencer.isParrying() then return true end
    return type(fencer.startedParry) == 'function' and fencer.startedParry() == true
end

local function shouldBlockDuringNgardeParry()
    if not settingOr(generalSettings, 'BlockDuringNGardeParry', true) then return false end
    return isParryingViaNgarde()
end

local function getCastSpeed(group)
    local speed = (animSpeedSettings:get(SPEED_KEYS[group] or 'AnimSpeed_Quickcast') or 1.0)
        * (animSpeedSettings:get('AnimSpeedScale') or 1.0)
    if speed <= 0 then return 1 end
    return speed
end

-- Per-bone-group priorities (identical upper-body split to ossc_npc.lua).
-- Every group in the blend mask is listed explicitly: openmw.animation.
-- playBlended seeds an unlisted group with PRIORITY.Default (0), which
-- would silently let weapon poses keep the RightArm.
--   Arms + Torso = PRIORITY.Hit (6) when no 1H swing is in flight: beats
--   Weapon-stance poses so a two-hander's grip can't pin the casting
--   arm, but stays BELOW PRIORITY.Weapon (7) so a real weapon attack
--   that starts mid-cast still wins the bones.
--   When a 1H / H2H / thrown attack is already mid-swing, RightArm +
--   Torso are left out so the cast cannot freeze the attack mid-anim.
--   LowerBody is omitted entirely, not just assigned a low priority, so
--   the actor's locomotion animation remains the root-motion source
--   throughout a quickcast while a two-handed weapon is equipped.
local function buildPlayOptions(speed)
    local priority = { [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Hit }
    local blendMask = anim.BLEND_MASK.LeftArm
    if not anyGroupPlaying(LIGHT_ATTACK_GROUPS) then
        priority[anim.BONE_GROUP.RightArm] = anim.PRIORITY.Hit
        priority[anim.BONE_GROUP.Torso]    = anim.PRIORITY.Hit
        blendMask = blendMask + anim.BLEND_MASK.RightArm + anim.BLEND_MASK.Torso
    end
    return {
        priority = priority,
        startKey = 'start', stopKey = 'stop',
        blendMask = blendMask,
        speed = speed,
    }
end

local function playCastAnimation(group, options)
    local controller = I.AnimationController
    if controller and controller.playBlendedAnimation then
        controller.playBlendedAnimation(group, options)
        return
    end
    anim.playBlended(self, group, options)
end

-- Timers cannot carry arguments, so the cast they belong to is identified by
-- the cast id captured when they were armed.
local armedCastId = 0

local function onReleaseTimer()
    if not isCasting or currentCastId ~= armedCastId or fired then return end
    fire(currentSpell, currentTarget)
end

local function onFinishTimer()
    if not isCasting or currentCastId ~= armedCastId then return end
    if not fired then fire(currentSpell, currentTarget) end
    cleanup()
end

local function startCast(spell)
    -- Re-check live so disabling creature (or non-biped creature) quick-casting
    -- stops an already-attached actor instead of relying on the init snapshot.
    if not isEligibleActor() then return false end
    if isCasting or not spell or incapacitated() or anyGroupPlaying(QUICKCAST_GROUPS) then return false end
    if shouldBlockDuringNgardeParry() then
        log("Cast blocked — NGarde parry is active")
        return false
    end
    -- The start gate above has passed: lock NGarde now so a guard cannot be
    -- raised over this item cast.
    setNgardeParryControl(true)
    local group = chooseAnimation(spell)
    isCasting, fired = true, false
    currentSpell, currentAnimGroup = spell, group
    currentTarget = getTarget()
    currentCastId = currentCastId + 1
    armedCastId = currentCastId

    types.Actor.setSelectedSpell(self, nil)
    types.Actor.setSelectedEnchantedItem(self, nil)
    types.Actor.setStance(self, types.Actor.STANCE.Weapon)

    local speed = getCastSpeed(group)
    playCastAnimation(group, buildPlayOptions(speed))

    local releaseDelay, finishDelay = 0.5 / speed, 1.2 / speed
    pendingTimersUntil = math.max(pendingTimersUntil, core.getSimulationTime() + finishDelay + 0.3)
    async:newUnsavableSimulationTimer(releaseDelay, onReleaseTimer)
    async:newUnsavableSimulationTimer(finishDelay, onFinishTimer)
    return true
end

-- ── Safe detach ────────────────────────────────────────────────────────────
-- Mirrors the NPC script protocol: cast timers cannot be cancelled, so only
-- report "ready to detach" to the global script once every timer that this
-- script created has certainly fired. The global script removes both actor
-- scripts only after each attached script has acked.
local readyToDetachEvent = { actor = self, script = SCRIPT_PATH }

local function detachAckTick()
    if isCasting or core.getSimulationTime() < pendingTimersUntil then
        async:newUnsavableSimulationTimer(0.25, detachAckTick)
        return
    end
    core.sendGlobalEvent('OSSC_ReadyToDetach', readyToDetachEvent)
end

local function armDetachAck()
    async:newUnsavableSimulationTimer(math.max(0.05, pendingTimersUntil - core.getSimulationTime() + 0.05), detachAckTick)
end

local function onTextKey(groupname, key)
    if not isCasting or groupname ~= currentAnimGroup then return end
    if not isEligibleActor() then return end
    local k = tostring(key):lower()
    if k == 'release' then
        fire(currentSpell, getTarget())
    elseif k == 'stop' then
        if not fired then fire(currentSpell, getTarget()) end
        cleanup()
    end
end

if isEligible and I.AnimationController then
    for i = 1, #QUICKCAST_GROUPS do
        I.AnimationController.addTextKeyHandler(QUICKCAST_GROUPS[i], onTextKey)
    end
end

local function onInit()
    if not isEligible then
        log('creature has neither the biped flag nor a castable spell — item quickcast disabled')
        return
    end
    log('shared item quickcast module active (eligible actor confirmed, no per-tick AI loop)')
end

local function onSave()
    return { nextCastAllowedTime = nextCastAllowedTime }
end

local function onLoad(data)
    -- External NGarde control is transient engine state: a save made mid-cast
    -- must never keep guards locked after the load.
    setNgardeParryControl(false)
    nextCastAllowedTime = data and data.nextCastAllowedTime or 0
end

-- Sent by the global script when it wants to detach this script: stop any
-- in-flight item cast and ack only once every cast timer created by this
-- script has certainly fired (they cannot be cancelled, and a removed
-- script's timers fail in the engine).
local function onCombatEnded()
    cleanup()
    armDetachAck()
end

local function isItemCasting()
    return isCasting
end

return {
    -- The caster script (ossc_npc.lua / ossc_creature.lua) decides WHEN to
    -- quick-cast; this interface lets it list and fire the actor's scrolls /
    -- cast-on-use items through the shared implementation above.
    interfaceName = 'OSSC_ActorItems',
    interface = {
        version = 1,
        findItems = findItems,
        startCast = startCast,
        isCasting = isItemCasting,
    },
    engineHandlers = {
        onInit = onInit,
        onSave = onSave,
        onLoad = onLoad,
    },
    eventHandlers = {
        OSSC_CombatEnded = onCombatEnded,
    },
}
