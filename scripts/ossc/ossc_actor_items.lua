---@omw-context local
-- ============================================================================
-- OSSC: shared NPC/creature item quick-casting (scrolls, cast-on-use)
-- No AI loop: caster scripts decide when to cast.
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
-- Friendlier Fire gate: SFP bypasses FF's sweep, so check friendly fire before consuming.
local castRules = require('scripts.ossc.ossc_cast_rules')
-- Where an impact's hit statics are drawn (OSSC owns the placement).
local impactVfx = require('scripts.ossc.ossc_impact_vfx')
local friendlyFire = require('scripts.ossc.ossc_friendlyfire')
local Penalty = require('scripts.ossc.ossc_penalty')
-- Launch offsets are user-editable data (scripts/ossc/ossc_launch_offsets.lua).
local launchOffsets = require('scripts.ossc.ossc_launch_offsets')
-- Moving-target lead for target-range item quick-casts: a Lua clone of the
-- OpenMW engine's AI spell leading (mwmechanics/aicombat.cpp
-- AimDirToMovingTarget). Samples are taken when the cast starts and again at
-- the fire moment — the two-point estimate spans the cast wind-up, which for
-- an item cast is the same idea as the engine's fixed reaction-time window.
-- The lead itself never reads the stance.
local targetLead = require('scripts.ossc.ossc_target_lead')
-- Mercy CAO (Combat AI Overhaul, Max Yari) bridge: while Mercy drives this
-- actor the draw state is Mercy's, so an item cast must not force Weapon
-- stance under it. The decision to cast at all is the caster script's
-- (ossc_npc.lua), which already holds itself while Mercy's body is committed.
-- A REAL vanilla cast cycle is an absolute veto here too and stays so until
-- SpellCast Unequip Stop (or the fallback timeout) closes it. Mercy's Spell
-- posture is different: like ossc_npc.lua, this module can ask Mercy to yield
-- for one item quick-cast, switch to Weapon stance, then restore Mercy.
local mercy = require('scripts.ossc.ossc_mercy')
-- Shared detector for the nine real vanilla spellcast text keys. The broad
-- anim.isPlaying('spellcast') check also matches equip / idle posture anims.
local vanillaSpellcast = require('scripts.ossc.ossc_vanilla_spellcast')

local SCRIPT_PATH = 'scripts/ossc/ossc_actor_items.lua'
local RANGE = core.magic.RANGE
local STANCE = types.Actor.STANCE
local SLOT = types.Actor.EQUIPMENT_SLOT
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

-- ── Spell classification ──
-- require of a missing file throws: probe the VFS and fall back. Abilities never qualify.
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
-- Sim time after which all cast timers have fired.
local pendingTimersUntil = 0.0
-- NGarde parry lock; only cleared when this script set it.
local ngardeParryControlActive = false
local ngardeCompatWarned = false
-- A 1H / H2H charge parks its animation on a text key. Remember the hold so a
-- cast started in that window blends around the attack (ossc_npc parity).
local lightChargeUntil = 0
local LIGHT_CHARGE_HOLD_WINDOW = 1.5
-- Short Mercy CAO yield for one item quick-cast (mirrors ossc_npc.lua).
-- Session state only: save/load and combat end always hand the body back.
local mercyWindowSnapshot    = nil
local mercyWindowSavedStance = nil
local mercyWindowUntil       = 0.0
local mercyWindowLocal       = false
-- Session state for the shared real-vanilla-cast key detector and the
-- SpellCast Unequip Stop cycle. The NPC caster script owns the engine spell
-- list; this script only mirrors the gate for item quick-casts.
local vanillaSpellState = vanillaSpellcast.newState()
local MERCY_WINDOW_MAX_DURATION = 4.0

--- Allow Quick-Cast In Spell Stance (opt-in, off by default), read live from
--- the mirrored player setting. Off keeps the original rule: an item quick-cast
--- waits for a Spell posture to go away (Mercy yield or not at all).
local function allowCastInSpellStance()
    return settingOr(generalSettings, 'AllowQuickCastInSpellStance', false) == true
end

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

-- Weapon classes whose wind-up needs BOTH arms. A held 1H / H2H charge is a
-- light attack; these are not, so the cast keeps its full upper-body mask.
local HEAVY_WEAPON_TYPES = {
    [types.Weapon.TYPE.LongBladeTwoHand] = true,
    [types.Weapon.TYPE.BluntTwoClose]    = true,
    [types.Weapon.TYPE.AxeTwoHand]       = true,
    [types.Weapon.TYPE.SpearTwoWide]     = true,
    [types.Weapon.TYPE.BluntTwoWide]     = true,
    [types.Weapon.TYPE.MarksmanBow]      = true,
    [types.Weapon.TYPE.MarksmanCrossbow] = true,
}

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
    -- NPCs: master toggle re-checked live.
    if self.type == types.NPC then
        return settingOr(npcSettings, 'NPCQuickCastEnabled', true) == true
    end
    if self.type ~= types.Creature then return false end

    -- Master creature toggle, re-checked live.
    if not settingOr(npcSettings, 'NPCQuickCastCreatures', true) then return false end

    -- Keep the Creature record's real `isBiped` field as the first criterion.
    local record = types.Creature.record(self)
    if record and record.isBiped == true then return true end

    -- Non-bipeds need a castable spell and the non-biped toggle.
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
    -- canMove is false when overencumbered; that must not block item casts.
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

-- Player-script parity: a light attack already playing, or a 1H / H2H attack
-- charge held with a non-heavy weapon, must keep RightArm + Torso to itself.
-- A charge parks its animation on a text key, so anim.isPlaying() alone is not
-- enough — the mirrored controls.use catches that wind-up window.
local function lightAttackOwnsWeaponArm()
    if anyGroupPlaying(LIGHT_ATTACK_GROUPS) then return true end
    local weapon = types.Actor.getEquipment(self, SLOT.CarriedRight)
    if weapon and weapon.type == types.Weapon then
        local record = types.Weapon.record(weapon)
        if record and HEAVY_WEAPON_TYPES[record.type] then return false end
    end
    -- Parked charge wind-up: anim.isPlaying() is false at the text key, but
    -- the 1H release still owns RightArm + Torso.
    if core.getSimulationTime() < lightChargeUntil then return true end
    local use = self.controls and self.controls.use
    if use == nil then return false end
    -- ATTACK_TYPE has no 'Attack' key (OpenMW: NoAttack=0, Any=1, Chop=2,
    -- Slash=3, Thrust=4): reading it raised "Key not found: Attack" and took
    -- the whole item quick-cast down with it. Anything but NoAttack is a held
    -- or chained attack.
    local attackTypes = self.ATTACK_TYPE
    local noAttack = attackTypes and attackTypes.NoAttack
    if noAttack ~= nil then return use ~= noAttack end
    return use ~= 0
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

-- [ENCHANT FORMULA] Same as player and global charge consumer.
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

-- Non-biped or invalid targets take the bone-free path.
local function isBipedActor(actor)
    if not actor or not actor:isValid() then return false end
    if actor.type == types.NPC or actor.type == types.Player then return true end
    if actor.type ~= types.Creature then return false end
    local record = types.Creature.record(actor)
    return record ~= nil and record.isBiped == true
end

local function targetPoint(target)
    -- Spine bone is biped-only.
    if isBipedActor(target)
        and (type(anim.hasBone) ~= 'function' or anim.hasBone(target, 'Bip01 Spine2')) then
        local transform = anim.getBoneTransform and anim.getBoneTransform(target, 'Bip01 Spine2')
        if transform and transform.position then
            return target.position + target.rotation * transform.position
        end
    end
    -- Vanilla parity (CastSpell::launchMagicBolt): the middle of the actor's
    -- bounding box, not a fixed height above its feet.
    return castRules.actorAimPoint(target, TARGET_CHEST_OFFSET.z)
        or (target.position + TARGET_CHEST_OFFSET)
end

-- Launch offsets: actors use the 'third' table from origin along facing.
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
    -- Scrolls exempt when the toggle is on; enchanted items always penalised.
    if settingOr(generalSettings, 'QuickCastEffectPenaltyScrollsExempt', false) == true
        and spell and spell.isScroll then
        return 1.0
    end
    -- 'skill_based' uses Enchant skill; otherwise flat or off.
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

-- NGarde parry lock while an item cast owns the hands; released by cleanup().
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

--- A REAL engine vanilla cast opens a cycle on any of the nine vanilla
--- spellcast Start / Release / Stop text keys. Quick-casts stay held until
--- SpellCast Unequip Stop (or the fallback timeout). Mirrors ossc_npc.lua.
--- Hardcoded 5 s (the setting was removed): the authored keys arrive well
--- inside it; the fallback is only for an animation whose SpellCast Unequip
--- Stop key is missing.
local VANILLA_CAST_UNEQUIP_TIMEOUT = 5.0

local function vanillaCastUnequipTimeout()
    return VANILLA_CAST_UNEQUIP_TIMEOUT
end

local function noteVanillaSpellcastKey(groupname, key)
    local now = core.getSimulationTime()
    local kind = vanillaSpellcast.noteKey(vanillaSpellState, groupname, key,
        now, vanillaSpellcast.KEY_HOLD)
    if kind then
        log('Vanilla spellcast key: ' .. tostring(key) .. ' (' .. kind
            .. ', cycle=' .. tostring(vanillaSpellcast.cyclePending(vanillaSpellState))
            .. ')')
    end
    return kind
end

local function expireVanillaCastCycle()
    local now = core.getSimulationTime()
    if vanillaSpellcast.expireCycle(vanillaSpellState, now,
        vanillaCastUnequipTimeout()) then
        log('Vanilla cast cycle ended (SpellCast Unequip Stop timeout) '
            .. '— item quick-casts re-armed')
    end
end

local function realVanillaSpellcastActive()
    return vanillaSpellcast.active(vanillaSpellState,
        core.getSimulationTime(), vanillaCastUnequipTimeout())
end

--- Same cooperation rule as ossc_npc.lua: the actor's castables have one owner
--- at a time. The NPC caster script owns the strip, so ask it through the
--- same-actor interface; while the ENGINE holds the spells only vanilla casts
--- exist, and while OSSC holds them (stripped) only quick-casts do.
local function engineOwnsSpellList()
    local caster = I.OSSC_Caster
    if type(caster) ~= 'table'
        or type(caster.isSpellListStripped) ~= 'function' then
        return false
    end
    return caster.isSpellListStripped() ~= true
end

--- Close one OSSC-owned item quick-cast window and give Mercy its state,
--- combat trees and visual posture back. Safe to call from every cleanup path.
local function endMercyWindow(reason)
    if not mercyWindowSnapshot and not mercyWindowLocal then return end
    local wasLocal = mercyWindowLocal
    mercy.endYield(mercyWindowSnapshot)
    local savedStance = mercyWindowSavedStance
    mercyWindowSnapshot    = nil
    mercyWindowSavedStance = nil
    mercyWindowUntil       = 0.0
    mercyWindowLocal       = false
    -- A Mercy yield gives the Spell posture back; a local takeover keeps the
    -- Weapon stance so the engine AI cannot restore the bare posture.
    if not wasLocal and savedStance == STANCE.Spell and not isCasting
        and not realVanillaSpellcastActive() then
        types.Actor.setStance(self, STANCE.Spell)
    end
    log('OSSC item quick-cast window closed (' .. tostring(reason) .. ', '
        .. (wasLocal and 'local takeover' or 'Mercy yield') .. ')')
end

local function cleanup()
    if ngardeParryControlActive then setNgardeParryControl(false) end
    isCasting = false
    currentAnimGroup = nil
    currentSpell = nil
    currentTarget = nil
    fired = false
    lightChargeUntil = 0
    endMercyWindow('cast cleanup')
end

-- Item cost is consumed only by SFP's launch guard (isFree = false); pre-consuming here double-spends.

local CAST_USER_DATA = { OSSC = true, NPC = true, CREATURE = true, ITEM = true }

local function fire(spell, target)
    if fired or not isCasting or not spell or not spell.item then return end
    fired = true
    local _, range = schoolAndRange(spell)
    local start = spawnPos()
    local direction = self.rotation * FORWARD
    local hitObject = nil
    -- Where the bolt is aimed; also the impact point reported to SFP.
    local aimPoint = nil
    if range == RANGE.Self then
        target, hitObject = self, self
    elseif target and target:isValid() then
        local aim = targetPoint(target)
        aimPoint = aim
        direction = (aim - start):normalize()
        -- Each eligible target-range item cast gets one private 50/50 lead
        -- decision. Direction-only replacement preserves hitObject and Touch
        -- routing; a stationary target keeps the plain aim.
        if range == RANGE.Target and not types.Actor.isDead(target) then
            local now = core.getSimulationTime()
            if targetLead.shouldLead(self.id, now) then
                targetLead.track(target, now)
                local led = targetLead.launchDirection{
                    startPos      = start,
                    aimPoint      = aim,
                    target        = target,
                    effects       = spell.effects,
                    effectRecords = core.magic.effects.records,
                    now           = now,
                }
                if led then
                    direction = led
                    log('Moving-target lead applied: ' .. tostring(target.recordId))
                end
            end
        end
        if range == RANGE.Touch then
            -- Vanilla touch contact (ossc_cast_rules.isTouchTargetInReach:
            -- plain fCombatDistance reach, the combat cone and a world-only
            -- line of sight). An enchanted-item touch cast must not land on a
            -- target across the room; out of contact the charge is not spent
            -- and the cast fizzles, exactly like the spell path.
            if require('scripts.ossc.ossc_cast_rules').isTouchTargetInReach(self, target) then
                hitObject = target
            else
                log('Item touch target out of reach: ' .. tostring(target.recordId))
                target = nil
            end
        end
    else
        target = nil
    end

    -- Friendlier Fire: check before spending the item.
    if range ~= RANGE.Self and target and target ~= self
        and friendlyFire.isFriendlyFireBlocked(self, target, spell.effects) then
        log('ITEM QUICKCAST VETOED — friendly fire: ' .. tostring(spell.id) .. ' -> ' .. tostring(target.recordId))
        return
    end

    -- "Projectiles Pass Through Bystanders" (default on): an item quick-cast
    -- flies through EVERY actor that is not its target, exactly like the spell
    -- quick-cast release — the launch names its mark (see
    -- castRules.requestBystanderPassThrough), so the bolt does not see anybody
    -- else and the target is what stops it. SF+'s `piercing` is not used: it
    -- applies the spell to every actor crossed and cannot be bounded to stop at
    -- the intended target.
    local userData = CAST_USER_DATA
    -- The launch's real blast radius (see castRules.impactArea): an area
    -- enchantment keeps the ordinary collision so its blast still detonates.
    local boltArea = castRules.impactArea(spell)
    if settingOr(npcSettings, 'NPCProjectilesPassThroughBystanders', true)
        and range == RANGE.Target and boltArea <= 0 then
        userData = castRules.requestBystanderPassThrough(userData, self, target)
    end
    -- Who draws the impact: a cast that explodes anywhere is the engine's blast
    -- (each exploding effect's own area static, spawned by SF+'s
    -- detonateSpellAtPos exactly like CastSpell::explodeSpell), so SF+ keeps it.
    -- Only a cast with no area anywhere is taken over by OSSC's hit statics.
    if range ~= RANGE.Self and not castRules.explodes(spell) then
        userData = impactVfx.requestFor(userData, spell)
    end
    -- A hit on another actor only shows Spell Framework Plus' per-effect hit
    -- VFX if that actor can interpret its AddVfx event (global side attaches).
    if target and target ~= self then
        core.sendGlobalEvent('OSSC_EnsureHitVfx', { actor = target })
    end

    -- Do not consume here: SFP's launch guard does (isFree = false); double-consume breaks the last item.
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker = self,
        caster = self,
        spellId = spell.id,
        startPos = start,
        direction = direction,
        area = boltArea,
        isFree = false,
        item = spell.item,
        itemRecordId = spell.item.recordId,
        hitObject = hitObject,
        -- The impact point the bolt is aimed at (mid-actor), so downstream
        -- impact/hit-effect code has the same centre the aim used.
        hitPos = range ~= RANGE.Self and aimPoint or nil,
        spawnOffset = 80,
        isGodMode = false,
        effectScale = getQuickCastEffectScale(spell),
        showAllCastVfx = true,
        userData = userData,
    })
    log(string.format('ITEM QUICKCAST: item=%s enchant=%s range=%s scroll=%s cost=%d',
        tostring(spell.item.recordId), tostring(spell.id), tostring(range), tostring(spell.isScroll), spell.cost))
end

-- Block quick-casts while NGarde parry is up or winding up. No-op without NGarde.
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
    -- Same 12 s bound on the finish fallback as ossc_npc.getCastSpeed.
    if speed < 0.2 then return 0.2 end
    return speed
end

-- Weapon ready / unready transition in flight (a draw or a sheathe of the
-- actor's own weapon). Recorded from the playBlended hook below; a cast in
-- flight keeps its casting hand while it runs, and a quick-cast started from
-- an item never fights the transition.
local drawTransition = castRules.newDrawTransition()
local function weaponTransitionPlaying()
    return castRules.drawTransitionActive(drawTransition)
end

-- Bone-group priorities (same rule as ossc_npc.lua). List every group:
-- unlisted ones default to priority 0. A quick-cast ALWAYS outranks weapon
-- attacks (no setting any more): it plays at PRIORITY.Block (8), one step above
-- PRIORITY.Weapon (7), and claims LeftArm + RightArm + Torso, so an attack
-- animation that is already running — Mercy CAO swings its own weapons — can
-- no longer out-rank the cast. While a weapon ready/unready transition of the
-- actor's own is playing, the cast drops to LeftArm-only at that same
-- priority: it keeps the casting hand steady through the whole draw/sheathe
-- and still lets the transition finish on the right arm and torso.
local function buildPlayOptions(speed)
    local castPriority = anim.PRIORITY.Block or (anim.PRIORITY.Weapon + 1)
    local priority = { [anim.BONE_GROUP.LeftArm] = castPriority }
    local blendMask = anim.BLEND_MASK.LeftArm
    if not weaponTransitionPlaying() then
        priority[anim.BONE_GROUP.RightArm] = castPriority
        priority[anim.BONE_GROUP.Torso]    = castPriority
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

-- Timers cannot carry arguments; identify the cast by id.
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

-- Mercy compatibility is fixed to Cooperate: while Mercy drives this actor,
-- the draw state is Mercy's to choose and OSSC must not force Weapon stance.
local function mercyOwnsStance(hasTarget)
    -- During an OSSC item quick-cast window Mercy has explicitly yielded the
    -- draw state; OSSC owns Weapon stance until cleanup restores the posture.
    return mercy.isDriving(hasTarget == true)
        and not (mercyWindowSnapshot or mercyWindowLocal)
end

local function startCast(spell)
    -- Re-check eligibility live.
    if not isEligibleActor() then return false end
    if isCasting or not spell or incapacitated() or anyGroupPlaying(QUICKCAST_GROUPS) then return false end
    if shouldBlockDuringNgardeParry() then
        log("Cast blocked — NGarde parry is active")
        return false
    end
    -- Mod cast veto: the same hook the player and NPC quick-casters ask, so a
    -- mod's rule about scrolls / enchanted items is honoured on this route too
    -- (it used to be impossible: an item cast never touches the vanilla Use
    -- path these mods gate on).
    if castRules.hasCastVeto() then
        local payload = castRules.castPayload(spell,
            { source = 'npcItem', caster = self, charge = spell.cost })
        local vetoAllowed, vetoReason, vetoMessage =
            castRules.checkCastVeto(payload)
        if not vetoAllowed then
            castRules.reportVetoedCast(self, payload, vetoReason, vetoMessage, {
                log    = log,
                fizzle = settingOr(generalSettings, 'CastVetoFeedback', 'Vanilla') ~= 'Silent',
            })
            return false
        end
    end
    -- Only a real vanilla cast cycle blocks an item quick-cast, and it stays
    -- blocked until SpellCast Unequip Stop (or the fallback timeout). A bare
    -- Spell stance is a posture: ask Mercy for one short yield when needed,
    -- swap to Weapon stance and cast normally (mirrors ossc_npc.lua).
    expireVanillaCastCycle()
    -- Vanilla-cast mode: another mod handed this actor its spell list back, so
    -- the engine is the one casting. An item quick-cast here would fight it.
    if engineOwnsSpellList() then
        log('Cast blocked — engine owns the spell list (vanilla casting mode)')
        return false
    end
    local stance = types.Actor.getStance(self)
    -- A real engine cast cycle always blocks (that gesture owns the arms). A
    -- bare posture is the one the setting releases: with Allow Quick-Cast In
    -- Spell Stance on the item cast keeps the stance instead of waiting for a
    -- Mercy yield, and below it is not swapped to Weapon either.
    local spellStanceCast = allowCastInSpellStance()
    if stance == STANCE.Spell then
        if realVanillaSpellcastActive() then
            log('Cast blocked — waiting for SpellCast Unequip Stop before item quick-cast')
            return false
        end
        if spellStanceCast then
            -- Allowed by the opt-in setting: keep the engine's posture and cast
            -- from it (no Mercy yield, no stance swap).
            log('Item quick-cast starts from Spell stance — allowed by setting')
        else
            -- Short Mercy CAO quick-cast windows are hardcoded on (the toggle
            -- was removed): the alternative is standing down for a whole fight
            -- against a Mercy-driven caster that keeps its Spell posture.
            local mercyWindowEnabled = true
            local snapshot = nil
            if mercyWindowEnabled and mercy.canYield() then
                snapshot = mercy.beginYield()
            end
            -- A bare Spell posture is never taken over locally any more ("Take
            -- Over Bare Spell Stance" is permanently off, the setting is gone).
            -- Without a real Mercy yield the item cast waits.
            if snapshot == nil then
                log('Cast blocked — bare Spell posture, no Mercy yield available')
                return false
            end
            local localWindow = false
            mercyWindowSnapshot    = snapshot
            mercyWindowSavedStance = stance
            mercyWindowLocal       = localWindow
            mercyWindowUntil       = core.getSimulationTime() + MERCY_WINDOW_MAX_DURATION
            -- setStance is ignored while an attack/spell input is held. Mercy's
            -- combat trees are already yielded, so clearing it here is safe. A
            -- sticky selected spell is cleared too: it armed this Spell posture.
            local controls, attackTypes = self.controls, self.ATTACK_TYPE
            if controls then
                controls.use = attackTypes and attackTypes.NoAttack or 0
            end
            types.Actor.clearSelectedCastable(self)
            types.Actor.setStance(self, STANCE.Weapon)
            if types.Actor.getStance(self) == STANCE.Spell then
                endMercyWindow('stance switch failed')
                log('Cast blocked — could not leave Spell stance for the item window')
                return false
            end
            log('OSSC item quick-cast window opened — Weapon stance ('
                .. (localWindow and 'local takeover' or 'Mercy yield') .. ')')
        end
    end
    -- Lock NGarde for this cast.
    setNgardeParryControl(true)
    local group = chooseAnimation(spell)
    isCasting, fired = true, false
    currentSpell, currentAnimGroup = spell, group
    currentTarget = getTarget()
    currentCastId = currentCastId + 1
    armedCastId = currentCastId

    -- First velocity sample at cast start; fire() takes the second at release,
    -- spanning the wind-up (this script has no onUpdate loop of its own).
    if currentTarget and currentTarget.isValid and currentTarget:isValid() then
        targetLead.track(currentTarget, core.getSimulationTime())
    end

    types.Actor.setSelectedSpell(self, nil)
    types.Actor.setSelectedEnchantedItem(self, nil)
    -- Mercy CAO picks the draw state while it drives this actor, and the
    -- engine's setStance interrupts an attack being prepared — for a
    -- Mercy-driven NPC that is the swing Mercy is winding up. Asked here
    -- rather than cached: this script has no update loop of its own.
    if not spellStanceCast
        and not mercyOwnsStance(currentTarget ~= nil)
        and types.Actor.getStance(self) ~= STANCE.Spell then
        types.Actor.setStance(self, STANCE.Weapon)
    end

    local speed = getCastSpeed(group)
    playCastAnimation(group, buildPlayOptions(speed))

    -- Using an enchanted item is casting, and casting breaks invisibility:
    -- the same event the player's cast and the actor's spell quick-cast send
    -- (vanilla only breaks it on an attack, so an invisible actor could fire an
    -- item and stay hidden). Sent here, after every gate above, so a refused
    -- cast never reveals the actor.
    core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = self })

    -- The animation's own `Release` text key is the authoritative moment the
    -- hand is forward; these timers are only the fallback for a cast whose keys
    -- never arrive, so they sit after the authored keys of the shipped
    -- animations (see castRules.castTimings) instead of racing them.
    local releaseDelay, finishDelay = castRules.castTimings(speed)
    local now = core.getSimulationTime()
    pendingTimersUntil = math.max(pendingTimersUntil, now + finishDelay + 0.3)
    if mercyWindowSnapshot or mercyWindowLocal then
        mercyWindowUntil = math.max(mercyWindowUntil, now + finishDelay + 0.5)
    end
    async:newUnsavableSimulationTimer(releaseDelay, onReleaseTimer)
    async:newUnsavableSimulationTimer(finishDelay, onFinishTimer)
    return true
end

-- ── Safe detach ──
-- Timers cannot be cancelled: ack only after all have fired.
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

-- Light-attack charge keys: a parked 1H wind-up must keep RightArm + Torso
-- free until its release, exactly like ossc_npc's light-charge handling.
local function isChargeKey(key)
    return key:find('min attack', 1, true) ~= nil or key:find('max attack', 1, true) ~= nil
end

local function onCombatAnimTextKey(groupname, key)
    local k = tostring(key):lower()
    if isChargeKey(k) then
        lightChargeUntil = core.getSimulationTime() + LIGHT_CHARGE_HOLD_WINDOW
        return
    end
    if k:find('release', 1, true) or k:find('min hit', 1, true)
        or k:find('follow', 1, true) or k:find('stop', 1, true) then
        lightChargeUntil = 0
    end
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
    -- Light attacks are not cast groups, but their charge keys are how the
    -- parked 1H / H2H wind-up is detected for blend preservation.
    for i = 1, #LIGHT_ATTACK_GROUPS do
        I.AnimationController.addTextKeyHandler(LIGHT_ATTACK_GROUPS[i], onCombatAnimTextKey)
    end
    -- Real engine spellcasts: the nine self/target/touch Start / Release /
    -- Stop keys open a cast cycle; SpellCast Unequip Stop closes it and
    -- re-arms item quick-casts. Registering '' also catches differently-cased
    -- group names and full NIF text keys.
    I.AnimationController.addTextKeyHandler('', function(groupname, key)
        noteVanillaSpellcastKey(groupname, key)
    end)
    if type(I.AnimationController.addPlayBlendedAnimationHandler) == 'function' then
        I.AnimationController.addPlayBlendedAnimationHandler(function(groupname, options)
            if type(groupname) ~= 'string' or type(options) ~= 'table' then return end
            local startKey = options.startKey or options.startkey
            if type(startKey) == 'string'
                and vanillaSpellcast.keyKind(groupname, startKey) == 'start' then
                noteVanillaSpellcastKey(groupname, startKey)
                return
            end
            -- A weapon ready / unready is the actor's own stance transition: an
            -- item cast in flight keeps its casting hand through it (same rule
            -- as ossc_player / ossc_npc).
            if vanillaSpellcast.isSpellcastGroup(groupname) then return end
            castRules.noteTransition(drawTransition, groupname, options)
            if isCasting and castRules.isEquipPlay(options) then
                local mask = options.blendMask
                if type(mask) == 'table' then
                    if mask[anim.BONE_GROUP.LeftArm] ~= nil then
                        mask[anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Default
                    end
                elseif type(mask) == 'number'
                    and mask % (2 * anim.BLEND_MASK.LeftArm) >= anim.BLEND_MASK.LeftArm then
                    options.blendMask = mask - anim.BLEND_MASK.LeftArm
                end
            end
        end)
    end
end

--- Keep Mercy yielded for the whole item cast. Mercy's own onUpdate can run
--- before or after this script, and its state:clear() resets some controls
--- every frame, so the yield is reasserted until cleanup().
local function onUpdate(dt)
    expireVanillaCastCycle()
    if not mercyWindowSnapshot and not mercyWindowLocal then return end
    local now = core.getSimulationTime()
    if now > mercyWindowUntil then
        cleanup()
        return
    end
    -- A local takeover has no Mercy state to maintain; just keep Weapon stance.
    if not mercyWindowLocal and not mercy.maintainYield() then
        cleanup()
        return
    end
    if isCasting and types.Actor.getStance(self) == STANCE.Spell then
        local controls, attackTypes = self.controls, self.ATTACK_TYPE
        if controls then
            controls.use = attackTypes and attackTypes.NoAttack or 0
        end
        types.Actor.clearSelectedCastable(self)
        types.Actor.setStance(self, STANCE.Weapon)
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
    -- A Mercy yield is session state: a save made mid-window must never leave
    -- Mercy's combat trees switched off after the load.
    cleanup()
    -- NGarde control must not survive a load.
    setNgardeParryControl(false)
    -- A vanilla spellcast key hold is session state; the animation that
    -- produced it is gone after the load.
    vanillaSpellcast.reset(vanillaSpellState)
    nextCastAllowedTime = data and data.nextCastAllowedTime or 0
end

-- Stop casting; ack once all timers have fired.
local function onCombatEnded()
    cleanup()
    vanillaSpellcast.reset(vanillaSpellState)
    armDetachAck()
end

local function isItemCasting()
    return isCasting
end

return {
    -- Item listing/casting for the caster scripts.
    interfaceName = 'OSSC_ActorItems',
    interface = {
        version = 1,
        findItems = findItems,
        startCast = startCast,
        isCasting = isItemCasting,
    },
    engineHandlers = {
        onInit = onInit,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
    eventHandlers = {
        OSSC_CombatEnded = onCombatEnded,
    },
}
