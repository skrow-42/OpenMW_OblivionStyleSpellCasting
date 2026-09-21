---@omw-context local
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_npc.lua (ACTOR SCRIPT — attached to combat NPCs and eligible creatures)
-- Tactical quick-casting for AI-controlled actors.
-- ============================================================================
local self    = require('openmw.self')
local core    = require('openmw.core')
local types   = require('openmw.types')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')
local util    = require('openmw.util')
local nearby  = require('openmw.nearby')
local I       = require('openmw.interfaces')
local async   = require('openmw.async')
-- Friendlier Fire gate. Quick-casts go through Spell Framework Plus, which
-- applies spells from Lua and bypasses FF's sweep, so OSSC detects friendly
-- fire itself before a follower quick-casts a harmful spell at the player or
-- another follower.
local friendlyFire = require('scripts.ossc.ossc_friendlyfire')
local Penalty = require('scripts.ossc.ossc_penalty')
-- Per-animation launch offsets (user-editable data file).
local launchOffsets = require('scripts.ossc.ossc_launch_offsets')

local STANCE     = types.Actor.STANCE
local SLOT       = types.Actor.EQUIPMENT_SLOT
local RANGE      = core.magic.RANGE
local SPELL_TYPE = core.magic.SPELL_TYPE
local spellRecords  = core.magic.spells.records
local effectRecords = core.magic.effects.records

local generalSettings   = storage.globalSection('SettingsOSSC_General')
local npcSettings       = storage.globalSection('SettingsOSSC_NPC')
local animationSettings = storage.globalSection('SettingsOSSC_Animations')
local animSpeedSettings = storage.globalSection('SettingsOSSC_AnimSpeeds')
-- The player's VFX toggles, mirrored into global storage by ossc_settings.lua
-- (actor scripts cannot read player storage).
local keysSettings      = storage.globalSection('SettingsOSSC_Keys')

local function settingOr(section, key, default)
    local value = section:get(key)
    if value == nil then return default end
    return value
end

-- Powers never pay the Quick Cast Effect Penalty.  The only other exemption
-- is the QuickCastEffectPenaltyScrollsExempt toggle, and it covers scrolls
-- alone — those are cast through scripts/ossc/ossc_actor_items.lua, which
-- honours the toggle itself.  Every spell that reaches this path is a regular
-- spell from the actor's spell list, so it is always penalised.  Data-driven
-- so the decision matches the player script.  NPCs/creatures never carry
-- powers unless they were explicitly allowed, so the power check is inert
-- for them.
local function effectPenaltyExempt(spell)
    if not spell then return false end
    if spell.item then return false end
    if spell.type == SPELL_TYPE.Power then return true end
    local rec = (spell.id and spellRecords[spell.id]) or nil
    if not rec and spell.enchantment then rec = spell.enchantment end
    if rec and rec.type == SPELL_TYPE.Power then return true end
    return false
end

-- ── Debug logging ──────────────────────────────────────────────────────────
local LOG_PREFIX = '[OSSC-NPC ' .. tostring(self.recordId) .. '] '
local cfg_debugMode = false

local function parseDebugMode(value)
    if value == true then return true end
    if value == false or value == nil then return false end
    if type(value) == 'number' then return value ~= 0 end
    local text = tostring(value):lower():match('^%s*(.-)%s*$')
    return text == 'true' or text == 'yes' or text == 'enabled' or text == 'on' or text == '1'
end

local function refreshDebugMode()
    cfg_debugMode = parseDebugMode(npcSettings:get('NPCQuickCastDebugLog'))
end

local function debugLog(msg)
    if not cfg_debugMode then return end
    print(LOG_PREFIX .. tostring(msg))
end

local function debugLogf(fmt, ...)
    if not cfg_debugMode then return end
    print(LOG_PREFIX .. fmt:format(...))
end

-- ── Cast state ─────────────────────────────────────────────────────────────
local isCasting                = false
local hasFiredThisCast         = false
-- Cast id whose school cast sound has already been played: startQuickcast()
-- plays it immediately (heard even when a skeleton's animation carries no
-- 'start' text key) and the 'start' text key must not play it a second time.
local castSoundPlayedForCastId = nil
local currentSpell             = nil
local currentAnimGroup         = nil
local currentRange             = RANGE.Target
local currentCastId            = 0
-- Timers cannot carry arguments, so the cast they belong to is identified by
-- the cast id captured when they were armed.
local armedCastId              = 0
local nextActionTime           = 0.0
local nextCastAllowedTime      = 0.0
local lastNonSpellStance       = STANCE.Weapon
local cachedKnownSpells        = {}
local spellsTemporarilyRemoved = false
local hasActiveVfx             = false
local inCombat                 = false
local isBound2HWeaponCast      = false
local suppressedShield         = nil   -- shield item unequipped during cast
local shieldGhostVfxActive     = false -- the ghost VFX was actually spawned
local SHIELD_GHOST_VFX_ID      = 'OSSC_ShieldGhost'

-- Cell re-entry guard. The engine can restore STANCE.Spell/SelectedSpell after
-- onActive/onLoad, so suppress that transient state without adding permanent
-- per-frame work after the actor has settled back into the cell.
local REENTRY_GUARD_DURATION = 1.0
local reentryGuardUntil      = 0.0

-- ── Safe detach support ────────────────────────────────────────────────────
-- ossc_global.lua removes this script when combat ends. Unsaved timers keep a
-- reference to functions inside this script, so it must not be removed while
-- a cast timer can still fire (a removed script's callbacks fail with
-- "callTimer failed"). The script tracks when its newest timer drains
-- (pendingTimersUntil) and only reports "ready to detach" once it is idle.
--
-- The gate every cast path reads (Pause.suspended) stays true from the detach
-- request until the script is really removed (or combat resumes): no new casts
-- and no re-stripping of engine spells may happen in that window, or the
-- removal race comes right back.
--
-- It is true when EITHER a detach is pending OR another mod has paused this
-- caster through the pause interface.  The two reasons are kept apart because
-- they end differently: combat resuming cancels a detach, a load clears both,
-- and an unpause must never clear a detach that has not finished yet.
--
-- One table rather than a handful of locals: this script sits on the Lua 5.1
-- limit for main-chunk locals, so new state comes out of an existing local
-- (this table replaces the old `castSuspended` local).
local pendingTimersUntil = 0.0
local Pause = {
    detachPending = false,   -- the global script asked for a detach
    reasons       = {},      -- [reason] = true, one entry per requesting mod
    suspended     = false,   -- gate every cast path reads
}

function Pause.refresh()
    Pause.suspended = Pause.detachPending or next(Pause.reasons) ~= nil
end

-- Settings mirrored into global storage are re-read periodically so menu
-- changes reach already-attached actor scripts without a reload.
local nextSettingsRefresh = 0.0
local nextDebugTick       = 0.0

local cfg_enabled      = true
local cfg_pollInterval = 1.0
local cfg_minDist      = 500
local cfg_maxDist      = 700
local cfg_baseChance   = 1.00
local cfg_cooldownMin  = 3.5
local cfg_cooldownMax  = 8.5
local cfg_allowPowers  = false
local cfg_randomAnims  = true
-- Gameplay-group settings the actor casts honour for player parity — the MCP
-- fatigue usage and the quick-cast chance penalty — plus the cost/chance
-- formulas themselves (see the CastCosts block below
-- getQuickCastEffectScale).  Everything lives in ONE table because this main
-- chunk sits at Lua's 200-active-locals limit; each additional top-level
-- local would overflow it.
local CastCosts = {
    useFatigue    = true,
    fatigueScale  = 5.0,
    chancePenalty = 'off',
}

local function refreshSettings()
    refreshDebugMode()
    -- Fallback values mirror the registered settings-menu defaults exactly.
    cfg_enabled      = settingOr(npcSettings, 'NPCQuickCastEnabled', true)
    cfg_pollInterval = settingOr(npcSettings, 'NPCQuickCastPollInterval', 1.0)
    if cfg_pollInterval <= 0 then cfg_pollInterval = 1.0 end
    cfg_minDist      = settingOr(npcSettings, 'NPCQuickCastMinDistance', 500)
    cfg_maxDist      = settingOr(npcSettings, 'NPCQuickCastMaxDistance', 700)
    cfg_baseChance   = settingOr(npcSettings, 'NPCQuickCastBaseChance', 100) / 100
    cfg_cooldownMin  = settingOr(npcSettings, 'NPCQuickCastCooldownMin', 3.5)
    cfg_cooldownMax  = math.max(cfg_cooldownMin, settingOr(npcSettings, 'NPCQuickCastCooldownMax', 8.5))
    cfg_allowPowers  = settingOr(npcSettings, 'NPCQuickCastAllowPowers', false)
    cfg_randomAnims  = settingOr(npcSettings, 'NPCQuickCastRandomAnims', true)
    CastCosts.useFatigue   = settingOr(generalSettings, 'UseFatigue', true) == true
    -- Same read order as the player script (UseFatigueScale, legacy
    -- FatigueScale); unsynced/corrupt values fall back to the registered
    -- default of 5.0.
    CastCosts.fatigueScale = tonumber(settingOr(generalSettings, 'UseFatigueScale', nil))
        or tonumber(settingOr(generalSettings, 'FatigueScale', nil)) or 5.0
    CastCosts.chancePenalty = settingOr(generalSettings, 'QuickCastChancePenalty', 'off')
end

-- ── Static tables ──────────────────────────────────────────────────────────
local SCHOOL_STRS = {
    [0] = 'alteration', [1] = 'conjuration', [2] = 'destruction',
    [3] = 'illusion', [4] = 'mysticism', [5] = 'restoration',
}

local function getQuickCastEffectScale(spell)
    if effectPenaltyExempt(spell) then
        return 1.0
    end
    -- 'skill_based' follows the actor's skill in the spell's school; anything
    -- else is a flat percentage (or off).
    local mode = settingOr(generalSettings, 'QuickCastEffectPenalty', 'off')
    if Penalty.isSkillBased(mode) then
        local firstEffect = spell and spell.effects and spell.effects[1]
        local mgef = firstEffect and effectRecords[firstEffect.id]
        local school = mgef and mgef.school
        if type(school) == 'number' then school = SCHOOL_STRS[school] end
        local accessor = self.type == types.NPC and type(school) == 'string'
            and types.NPC.stats.skills[school] or nil
        local skill = accessor and accessor(self)
        return Penalty.skillScale(skill and skill.modified or 0)
    end
    return Penalty.scale(mode)
end

-- ── Fatigue usage + Quick Cast Chance Penalty (player parity) ──────────────
-- The Gameplay-group settings UseFatigue / Fatigue Usage Scale Multiplier and
-- QuickCastChancePenalty apply to NPC and eligible-creature quick-casts too,
-- with exactly the player-side formulas.  Everything hangs off the CastCosts
-- table (declared with the cfg block above) to stay inside Lua's 200-local
-- limit for this main chunk.
--
-- Fatigue (MCP formula), paid together with the magicka at the release and
-- kept when the cast then fails its chance roll — like the player's costs:
--   fatigue loss = magickaCost * (fFatigueSpellBase + enc% * fFatigueSpellMult) * scale
-- Vanilla ships both fFatigueSpell* GMSTs as 0 (which made UseFatigue a
-- silent no-op), so untuned GMSTs fall back to the player script's built-in
-- 0.5/0.5 pair: half the magicka cost at zero encumbrance up to the full
-- cost at full encumbrance.
--
-- Chance: QuickCastChancePenalty ('off' / 'reduce_<pct>' / 'skill_based')
-- multiplies the success chance of an actor's quick-cast exactly like the
-- player's; the base is the vanilla cast-chance formula
--   (2*schoolSkill - cost + castBonus + 0.2*willpower + 0.1*luck) * fatigueTerm
-- resolved on the lowest-margin effect school (the same computation Spell
-- Framework Plus' getSpellCastChance helper performs for the player), and the
-- fatigue term only bites while UseFatigue is on.  While the setting is
-- 'off', actor quick-casts land unconditionally as before; enabling it is
-- what starts the roll.  Silence never reaches this code — the release gate
-- (isActorIncapacitated) already vetoes a silenced caster.
--
-- Powers are sure casts: never rolled, never penalised (player parity).
-- Creatures have no magic school skills: their base chance is 100 (the engine
-- never fails a creature's cast) and a skill-based penalty resolves at
-- skill 0 — the same creature rule the shield and effect penalties use.

-- GMST constants for the formulas (the same reads the player script and
-- Spell Framework Plus' helper make).
CastCosts.GMST = {
    fFatigueSpellBase = core.getGMST('fFatigueSpellBase') or 0,
    fFatigueSpellMult = core.getGMST('fFatigueSpellMult') or 0,
    fFatigueBase      = core.getGMST('fFatigueBase') or 1.25,
    fFatigueMult      = core.getGMST('fFatigueMult') or 0.5,
    fEffectCostMult   = core.getGMST('fEffectCostMult') or 1.0,
}

function CastCosts.payFatigue(magickaCost)
    if not CastCosts.useFatigue then return end
    if type(magickaCost) ~= 'number' or magickaCost <= 0 then return end
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    if not fatigue then return end
    local gmst = CastCosts.GMST
    local fBase = gmst.fFatigueSpellBase
    local fMult = gmst.fFatigueSpellMult
    if not (fBase > 0 or fMult > 0) then fBase, fMult = 0.5, 0.5 end
    local enc = 0
    local encumbrance = types.Actor.getEncumbrance(self)
    local capacity = types.Actor.getCapacity(self)
    if type(encumbrance) == 'number' and type(capacity) == 'number' and capacity > 0 then
        enc = math.max(0, math.min(1, encumbrance / capacity))
    end
    local fatigueCost = magickaCost * (fBase + enc * fMult) * math.max(0, CastCosts.fatigueScale)
    if fatigueCost > 0 then
        fatigue.current = math.max(0, fatigue.current - fatigueCost)
        debugLogf('Fatigue cost %.2f paid (encumbrance %.0f%%, scale %.2f)',
            fatigueCost, enc * 100, CastCosts.fatigueScale)
    end
end

function CastCosts.penaltyActive()
    local mode = CastCosts.chancePenalty
    if mode == nil then return false end
    if Penalty.isSkillBased(mode) then return true end
    return Penalty.scale(mode) < 1.0
end

-- The vanilla fatigue term of the cast-chance formula; ignoreFatigue mirrors
-- the player's getCastChance option: it only applies while UseFatigue is on.
function CastCosts.fatigueTerm()
    if not CastCosts.useFatigue then return 1 end
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local normalized = 1
    if fatigue and fatigue.base ~= 0 then
        normalized = math.max(0, fatigue.current / fatigue.base)
    end
    local gmst = CastCosts.GMST
    return gmst.fFatigueBase - gmst.fFatigueMult * (1 - normalized)
end

function CastCosts.skillValue(school)
    if self.type ~= types.NPC or type(school) ~= 'string' then return 0 end
    local accessor = types.NPC.stats.skills[school]
    if not accessor then return 0 end
    local stat = accessor(self)
    return stat and stat.modified or 0
end

-- The vanilla base cast chance (0..100) for this actor's current spell, plus
-- the effective (lowest-margin) school a skill-based penalty resolves
-- against.  Transcribed from Spell Framework Plus' Helpers.getSpellCastChance
-- so the actor roll and the player roll can never disagree about the formula.
function CastCosts.baseChance(spell)
    local record = spell and spell.id and spellRecords[spell.id] or nil
    local firstEffect = (spell and spell.effects and spell.effects[1])
        or (record and record.effects and record.effects[1])
    local firstMgef = firstEffect and effectRecords[firstEffect.id]
    local firstSchool = firstMgef and firstMgef.school
    if type(firstSchool) == 'number' then firstSchool = SCHOOL_STRS[firstSchool] end
    if not record or record.type ~= SPELL_TYPE.Spell then
        return 100, firstSchool -- powers (and anything else) are sure casts
    end
    if self.type ~= types.NPC then
        return 100, firstSchool -- creatures: no skill roll, engine parity
    end
    local activeEffects = types.Actor.activeEffects(self)
    local gmst = CastCosts.GMST
    local total = 0
    local lowestMargin = math.huge
    local lowestSkill = 0
    local effectiveSchool = firstSchool
    for _, eff in ipairs(record.effects or {}) do
        local mgef = effectRecords[eff.id]
        if mgef then
            local x = mgef.hasDuration and eff.duration or 1
            if not mgef.isAppliedOnce then x = math.max(x, 1) end
            x = x * 0.1 * mgef.baseCost
            x = x * 0.5 * ((eff.magnitudeMin or 0) + (eff.magnitudeMax or 0))
            x = x + 0.05 * mgef.baseCost * (eff.area or 0)
            if eff.range == RANGE.Target then x = x * 1.5 end
            x = x * gmst.fEffectCostMult
            total = total + x
            local school = mgef.school
            if type(school) == 'number' then school = SCHOOL_STRS[school] end
            local s = 2 * CastCosts.skillValue(school)
            if (s - x) < lowestMargin then
                lowestMargin = s - x
                lowestSkill = s
                effectiveSchool = school
            end
        end
    end
    if record.alwaysSucceedFlag then return 100, effectiveSchool end
    local cost = total
    if not record.autocalcFlag then
        cost = record.cost or total
    else
        cost = math.max(1, math.floor(total + 0.5))
    end
    local castBonus = 0
    if activeEffects then
        local soundEffect = activeEffects:getEffect(core.magic.EFFECT_TYPE.Sound)
        castBonus = -(soundEffect and soundEffect.magnitude or 0)
    end
    local willpower = types.NPC.stats.attributes.willpower(self).modified
    local luck = types.NPC.stats.attributes.luck(self).modified
    local chance = (lowestSkill - util.round(cost) + castBonus
        + 0.2 * willpower + 0.1 * luck) * CastCosts.fatigueTerm()
    chance = math.max(0, math.min(100, chance))
    return math.floor(chance), effectiveSchool
end

-- The QuickCastChancePenalty multiplier for this cast; a skill-based value
-- resolves against the actor's skill in the cast's effective school (0 for a
-- creature — no magic school skills).
function CastCosts.chanceScale(effectiveSchool)
    if Penalty.isSkillBased(CastCosts.chancePenalty) then
        return Penalty.skillScale(CastCosts.skillValue(effectiveSchool))
    end
    return Penalty.scale(CastCosts.chancePenalty)
end

local RANGE_STRS = {
    [RANGE.Self] = 'Self', [RANGE.Touch] = 'Touch', [RANGE.Target] = 'Target',
}

local ANIM_BY_SCHOOL_AND_RANGE = {
    destruction = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qcdrain', [RANGE.Target] = 'quickcast' },
    restoration = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qcdrain', [RANGE.Target] = 'quickcast' },
    alteration  = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'qcalt' },
    illusion    = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'qcill' },
    conjuration = { [RANGE.Self] = 'qcconj',    [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'qcconj' },
    mysticism   = { [RANGE.Self] = 'qcsnap',    [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'quickcast' },
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
    'quickcast', 'quickbuff', 'qcconj', 'qctouch', 'qcalt', 'qcalts', 'qcill', 'qcsnap', 'qcdrain', 'qcskrow',
}

local SPEED_KEYS = {
    quickcast = 'AnimSpeed_Quickcast', quickbuff = 'AnimSpeed_Quickbuff', qcconj = 'AnimSpeed_Qcconj',
    qctouch = 'AnimSpeed_Qctouch', qcalt = 'AnimSpeed_Qcalt', qcalts = 'AnimSpeed_Qcalts',
    qcill = 'AnimSpeed_Qcill', qcsnap = 'AnimSpeed_Qcsnap', qcdrain = 'AnimSpeed_Qcdrain',
    qcskrow = 'AnimSpeed_Qcskrow', eqcastr = 'AnimSpeed_Quickcast',
}

-- ── Per-entity rolled cast animations ──────────────────────────────────────
-- When the script attaches, a personal animation set is rolled for every
-- spell school (NPCQuickCastRandomAnims, on by default), so different casters
-- fight with different casting animations:
--   * Self-range     → quickbuff or qcconj — the only self/buff-style groups.
--   * Touch / Target → every other cast animation.
-- The rolled set replaces the Cast Animations page for this actor; the player
-- keeps their configured animations. Persisted through onSave/onLoad.
local ROLL_SELF_POOL = { 'quickbuff', 'qcconj' }
local ROLL_POOL      = { 'quickcast', 'qctouch', 'qcalt', 'qcill', 'qcsnap', 'qcdrain', 'qcskrow' }
local rolledAnims    = nil

local function rollAnimSet()
    -- Seed from something actor-unique plus the attach time, so two actors
    -- attached at the same moment still roll different sets.
    local seed = 0
    local idStr = tostring(self.id) .. '/' .. tostring(self.recordId)
    for i = 1, #idStr do seed = (seed * 33 + idStr:byte(i)) % 2147483647 end
    seed = (seed + math.floor(core.getSimulationTime() * 1000)) % 2147483647
    math.randomseed(seed > 0 and seed or 1)
    -- The first outputs right after a reseed are weakly distributed; burn a few.
    for _ = 1, 3 do math.random() end

    local rolled = {}
    for _, school in pairs(SCHOOL_STRS) do
        rolled[school] = {
            [RANGE.Self]   = ROLL_SELF_POOL[math.random(#ROLL_SELF_POOL)],
            [RANGE.Touch]  = ROLL_POOL[math.random(#ROLL_POOL)],
            [RANGE.Target] = ROLL_POOL[math.random(#ROLL_POOL)],
        }
    end
    rolledAnims = rolled
    if not cfg_debugMode then return end
    local parts = {}
    for _, school in pairs(SCHOOL_STRS) do
        local r = rolled[school]
        parts[#parts + 1] = string.format('%s(self=%s,touch=%s,target=%s)',
            school, r[RANGE.Self], r[RANGE.Touch], r[RANGE.Target])
    end
    table.sort(parts)
    debugLog('Rolled cast animations: ' .. table.concat(parts, ' '))
end

local INCAPACITATED_GROUPS = {
    'knockdown', 'knockout', 'swimknockdown', 'swimknockout',
    'hit1', 'hit2', 'hit3', 'hit4', 'hit5',
    'swimhit1', 'swimhit2', 'swimhit3',
}

local function toSet(list)
    local set = {}
    for i = 1, #list do set[list[i]] = true end
    return set
end

-- Animation groups that block quick-casting when BlockDuringCombatAnims is on
-- (same list as the player script). A bow/crossbow shot blocks for its WHOLE
-- duration — draw/aim and the follow-through — so a quick 1-tap is treated
-- exactly like a held attack.
local COMBAT_ANIM_GROUPS    = { 'shield', 'weapontwohand', 'weapontwowide', 'bowandarrow', 'crossbow' }
local COMBAT_ANIM_GROUP_SET = toSet(COMBAT_ANIM_GROUPS)

-- A held attack charge parks the weapon animation on a text key ("min attack"
-- / "max attack"), so anim.isPlaying() returns false while the actor is
-- winding up or holding a charged attack. Track that hold window through the
-- combat animation text keys instead: charge keys open it, release/follow
-- keys close it, and a short safety cap bounds a missed release key so a
-- stale window can never permanently block casts.
local combatChargeUntil = 0
local COMBAT_CHARGE_HOLD_WINDOW = 1.5

-- Attack animation groups blocked by BlockWeaponDuringQuickcast while a
-- quickcast is playing (the same heavy weapon classes the player script
-- guards). Shield blocking is not an attack, so 'shield' is left out.
local HEAVY_ATTACK_GROUPS    = { 'weapontwohand', 'weapontwowide', 'bowandarrow', 'crossbow' }
local HEAVY_ATTACK_GROUP_SET = toSet(HEAVY_ATTACK_GROUPS)

-- Self-heal bookkeeping for a dead-locked engine attack input (see
-- releaseEngineAttack below): simulation time since the engine attack input
-- was first seen continuously held while no heavy attack animation plays.
local stuckAttackInputSince = nil
local STUCK_ATTACK_INPUT_TIMEOUT = 2.0

-- One-handed / hand-to-hand / thrown attack groups. Never cancelled mid-cast,
-- and the cast must not steal their RightArm/Torso bones (see the matching
-- list + buildCastBlendOptions in ossc_player.lua).
local LIGHT_ATTACK_GROUPS = { 'weapononehand', 'weapononehand1', 'handtohand', 'throwweapon' }

-- Weapon record types whose attack animations live in the heavy groups above.
-- A quickcast only blocks a heavy-weapon attack when the actor actually HAS
-- one of these equipped: one-handed weapons, hand-to-hand and an empty hand
-- stay usable mid-cast — the cast animation is deliberately played below
-- PRIORITY.Weapon so those swings blend over the cast naturally.
local EXCLUDED_WEAPON_TYPE_TO_GROUP = {
    [types.Weapon.TYPE.LongBladeTwoHand] = 'weapontwohand',
    [types.Weapon.TYPE.BluntTwoClose]    = 'weapontwohand',
    [types.Weapon.TYPE.AxeTwoHand]       = 'weapontwohand',
    [types.Weapon.TYPE.SpearTwoWide]     = 'weapontwowide',
    [types.Weapon.TYPE.BluntTwoWide]     = 'weapontwowide',
    [types.Weapon.TYPE.MarksmanBow]      = 'bowandarrow',
    [types.Weapon.TYPE.MarksmanCrossbow] = 'crossbow',
}

-- Bounded cast window: `isCasting` is normally cleared by the cast animation's
-- 'stop' text key or by the finish timer. Both can be LOST (an actor leaving
-- the active cells freezes its timers, a script reload drops them), and a
-- wedged `isCasting` would keep every 2H / bow / crossbow attack vetoed FOR
-- EVER. Every cast therefore carries an absolute deadline: past it the cast
-- resolves itself (firing the spell if it has not fired yet) and the block
-- ends, whatever happened to the timers.
local CAST_DEADLINE_MARGIN = 0.35
local castDeadline = 0.0

-- Set whenever this cast actually suppressed the engine attack input (vetoed
-- play / released input); the input is handed back when the cast ends.
local attackSuppressedDuringCast = false

local FORWARD = util.vector3(0, 1, 0)
local LEFT    = util.vector3(-1, 0, 0)
local UP      = util.vector3(0, 0, 1)
local TARGET_AIM_OFFSET = util.vector3(0, 0, 70)
local LOS_TARGET_OFFSET = util.vector3(0, 0, 60)

-- Spell vendors are completely outside OSSC NPC casting.
local function isSpellVendor()
    if self.type ~= types.NPC then return false end
    local services = types.NPC.record(self).servicesOffered
    return services ~= nil and services.Spells == true
end
local IS_SPELL_VENDOR   = isSpellVendor()
local IS_BIPED_CREATURE = self.type == types.Creature and types.Creature.record(self).isBiped == true
-- NPCs (including beast races) always use the biped skeleton; creatures only
-- when their record carries the biped flag. Everything hand-anchored (VFX on
-- 'Bip01 L Hand', cast animations from the biped quickcast sets) must consult
-- this: non-biped skeletons lack those bones/groups and the engine reports a
-- DelayedAction error for the lookup. Non-bipeds therefore cast without
-- hand-anchored effects — body swirl + cast sound + timers only.
local IS_BIPED = self.type == types.NPC or IS_BIPED_CREATURE
local SCRIPT_PATH = self.type == types.Creature and 'scripts/ossc/ossc_creature.lua' or 'scripts/ossc/ossc_npc.lua'

-- ── Animation / attack helpers ─────────────────────────────────────────────
-- First group of `groups` that is currently playing, or nil.
local function playingGroup(groups)
    for i = 1, #groups do
        if anim.isPlaying(self, groups[i]) then return groups[i] end
    end
    return nil
end

-- Excluded (2H / bow / crossbow) animation group of the weapon in the actor's
-- right hand, or nil when the hand holds an allowed weapon (1H, hand-to-hand,
-- nothing). Mirrors getExcludedWeaponGroup() in the player script.
local function getExcludedWeaponGroup()
    local weapon = types.Actor.getEquipment(self, SLOT.CarriedRight)
    if not weapon or weapon.type ~= types.Weapon then return nil end
    return EXCLUDED_WEAPON_TYPE_TO_GROUP[types.Weapon.record(weapon).type]
end

local BOUND_2H_EFFECT_IDS = {
    [core.magic.EFFECT_TYPE.BoundSpear]     = true,
    [core.magic.EFFECT_TYPE.BoundBattleAxe] = true,
    [core.magic.EFFECT_TYPE.BoundLongsword] = true,
    [core.magic.EFFECT_TYPE.BoundLongbow]   = true,
    ['boundspear']     = true,
    ['boundbattleaxe'] = true,
    ['boundlongsword'] = true,
    ['boundlongbow']   = true,
}

local function hasBound2HWeaponEffect(spell)
    if not spell then return false end
    if spell.effects then
        for _, eff in ipairs(spell.effects) do
            if eff and eff.id and BOUND_2H_EFFECT_IDS[eff.id] then return true end
        end
    end
    local rec = spellRecords[spell.id]
    if rec and rec.effects then
        for _, eff in ipairs(rec.effects) do
            if eff and eff.id and BOUND_2H_EFFECT_IDS[eff.id] then return true end
        end
    end
    return false
end

-- Unequip the shield to prevent blocking, but attach its mesh to the left-hand
-- bone via addVfx so it stays visually in place during the quickcast window.
local function suppressShieldDuringCast()
    if not settingOr(generalSettings, 'BlockShieldDuringQuickcast', false) then return end
    if not IS_BIPED then return end -- the ghost VFX anchors to 'Bip01 L Hand'
    if type(anim.hasBone) == 'function' and not anim.hasBone(self, 'Bip01 L Hand') then return end
    if suppressedShield then return end
    local eq = types.Actor.getEquipment(self)
    local item = eq[SLOT.CarriedLeft]
    if item and item.type == types.Armor and types.Armor.record(item).type == types.Armor.TYPE.Shield then
        local armorRec = types.Armor.record(item)
        if armorRec.model and armorRec.model ~= '' then
            anim.addVfx(self, armorRec.model, {
                loop            = true,
                vfxId           = SHIELD_GHOST_VFX_ID,
                boneName        = 'Bip01 L Hand',
                useAmbientLight = false,
            })
            shieldGhostVfxActive = true
            debugLog('Shield ghost VFX added: ' .. armorRec.model)
        end
        suppressedShield = item
        eq[SLOT.CarriedLeft] = nil
        types.Actor.setEquipment(self, eq)
        debugLog('Shield unequipped for blocking suppression: ' .. tostring(item.recordId))
    end
end

--- Removes a VFX only while there is still an animation to remove it from.
---
--- `anim.removeVfx` raises "Object has no animation" on an actor whose
--- animation object is gone, and this cleanup is exactly where that happens:
--- resetAfterActivation / onCombatEnded are sent by the global attachment
--- manager immediately before it detaches the script, by which point a dying,
--- unloaded or otherwise finished actor can already have lost its animation.
--- The VFX hangs off that same object, so when the animation is gone there is
--- nothing left to remove and skipping is the correct answer - not an error to
--- be swallowed.
local function removeVfxSafely(vfxId)
    if not anim.hasAnimation(self) then return false end
    anim.removeVfx(self, vfxId)
    return true
end

local function restoreShieldAfterCast()
    -- Only reach for the VFX when one was actually spawned: the shield is
    -- unequipped even when its record has no model, in which case there was
    -- never anything to remove.
    if shieldGhostVfxActive then
        if removeVfxSafely(SHIELD_GHOST_VFX_ID) then
            shieldGhostVfxActive = false
        end
    end
    if suppressedShield then
        if suppressedShield:isValid() then
            local eq = types.Actor.getEquipment(self)
            if not eq[SLOT.CarriedLeft] then
                eq[SLOT.CarriedLeft] = suppressedShield
                types.Actor.setEquipment(self, eq)
                debugLog('Shield re-equipped after quickcast: ' .. tostring(suppressedShield.recordId))
            end
        end
        suppressedShield = nil
    end
end

-- True while the quickcast window counts as "hands busy" and the setting asks
-- for heavy attacks to be blocked. The cast-state flags are used rather than
-- anim.isPlaying: a cast animation can momentarily report not playing between
-- text keys / while blended, which would let a 2H swing through.
local function shouldBlockHeavyAttack()
    if isBound2HWeaponCast then return false end
    if not isCasting or currentAnimGroup == nil then return false end
    -- Never let the block outlive the cast window it belongs to, even if
    -- `isCasting` itself got wedged (see the deadline comment above).
    if core.getSimulationTime() > castDeadline then return false end
    if not settingOr(generalSettings, 'BlockWeaponDuringQuickcast', false) then return false end
    return getExcludedWeaponGroup() ~= nil
end

-- Releasing the engine attack input is the ONLY safe way to abort an
-- engine-driven (AI) attack from Lua. Setting self.controls.use to NoAttack
-- clears the engine's "attacking or spell" flag on the next mechanics frame,
-- which lets the character controller walk its own upper-body state machine
-- out of the wind-up (AttackWindUp -> AttackRelease -> AttackEnd ->
-- WeaponEquipped) — exactly what the engine does when running out of ammo.
--
-- A bare anim.cancel() on an AI actor's mid-swing attack PERMANENTLY breaks
-- its attacks: the character controller keeps mUpperBodyState = AttackWindUp,
-- and with the animation state gone the AI reads a wind-up progress of 0
-- forever, never releases the attack input and never swings again.
local function releaseEngineAttack()
    if self.controls.use == self.ATTACK_TYPE.NoAttack then return end
    self.controls.use = self.ATTACK_TYPE.NoAttack
end

-- For non-player actors openmw mirrors the "attacking or spell" flag into
-- self.controls.use every mechanics frame, so this is a reliable read.
local function isEngineAttackInputHeld()
    return self.controls.use ~= self.ATTACK_TYPE.NoAttack
end

-- NGarde parry block: while NGarde has this actor actively parrying (guard
-- raised, or in the wind-up to raise it) the hands are committed to the
-- weapon block. I.NGardeFencer only exists while NGarde's fencer script is
-- attached to this actor.
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

-- Parry-after-cast lock (mirror of the player script's setNgardeParryControl):
-- while a quickcast owns the hands, NGarde must refuse new guard raises.
-- NGarde guards play custom animation groups, so OSSC's vanilla shield /
-- heavy-attack cancels can never intercept them — externalParryControl is the
-- only mechanism. Nothing inside NGarde resets it on its own, so every
-- cast-end path (cleanupCast) and every re-entry path (resetAfterActivation)
-- must release it. Gated on BlockDuringNGardeParry; silent no-op without
-- NGarde. Engaging also lowers any guard NGarde still has up through
-- forceLowerGuard (the start gate already passed, so this only catches
-- races) — the same order the player script uses.
local ngardeParryControlActive = false

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
        debugLog('NGarde parry control ' .. (active and 'engaged' or 'released'))
    else
        ngardeParryControlActive = false
        if active and fencer ~= nil then
            debugLog('WARNING: BlockDuringNGardeParry is on but I.NGardeFencer.externalParryControl is missing — update NGarde')
        end
    end
end

local function isChargeKey(key)
    return key:find('min attack', 1, true) ~= nil or key:find('max attack', 1, true) ~= nil
end

local function onCombatAnimTextKey(groupname, key)
    local k = tostring(key):lower()
    if isChargeKey(k) then
        combatChargeUntil = core.getSimulationTime() + COMBAT_CHARGE_HOLD_WINDOW
        debugLog('Attack charge hold detected: ' .. tostring(groupname) .. ' / ' .. tostring(key))
        return
    end
    if k:find('release', 1, true) or k:find('min hit', 1, true)
        or k:find('follow', 1, true) or k:find('stop', 1, true) then
        combatChargeUntil = 0
    end
end

-- BlockDuringCombatAnims: no quick-cast while a shield block, two-handed
-- attack or bow/crossbow shot plays, or while an attack charge is held.
local function combatAnimBlocksCast(now)
    if not settingOr(generalSettings, 'BlockDuringCombatAnims', false) then return false end
    local group = playingGroup(COMBAT_ANIM_GROUPS)
    if group then
        debugLog('Cast blocked — combat animation playing: ' .. group)
        return true
    end
    if now < combatChargeUntil then
        debugLog('Cast blocked — attack charge is being held')
        return true
    end
    return false
end

-- ── Cast VFX ───────────────────────────────────────────────────────────────
local vfxOptions = { loop = false, vfxId = nil, boneName = nil, particleTextureOverride = nil }
local vfxSeen = {}

local function clearTable(t)
    for k in pairs(t) do t[k] = nil end
end

local function addCastStaticVfx(boneName, vfxId)
    clearTable(vfxSeen)
    for i, effect in ipairs(currentSpell.effects) do
        local mgef = effectRecords[effect.id]
        local static = mgef and mgef.castStatic and types.Static.records[mgef.castStatic]
        local model = static and static.model
        if model and not vfxSeen[model] then
            vfxSeen[model] = true
            vfxOptions.vfxId = vfxId .. '_' .. i
            vfxOptions.boneName = boneName
            vfxOptions.particleTextureOverride = nil
            anim.addVfx(self, model, vfxOptions)
        end
    end
end

local function addHandSwirlVfx()
    -- Non-biped skeletons have no 'Bip01 L Hand' bone: skip the element ball
    -- there (the body swirl still plays) instead of erroring. The hasBone
    -- probe is the second layer: a biped-flagged actor with a modded skeleton
    -- that lacks the bone is skipped too. (No pcall: a missing engine
    -- function simply falls back to the record flag.)
    if not IS_BIPED then return end
    if type(anim.hasBone) == 'function' and not anim.hasBone(self, 'Bip01 L Hand') then return end
    clearTable(vfxSeen)
    for i, effect in ipairs(currentSpell.effects) do
        local mgef = effectRecords[effect.id]
        if mgef then
            local texture = mgef.particle
            if not texture or texture == '' or texture:find('blank', 1, true) then texture = 'vfx_starglow.tga' end
            if not vfxSeen[texture] then
                vfxSeen[texture] = true
                vfxOptions.vfxId = 'OSSC_HandSwirl_' .. i
                vfxOptions.boneName = 'Bip01 L Hand'
                vfxOptions.particleTextureOverride = texture
                anim.addVfx(self, 'meshes/magichand/spellvfx.nif', vfxOptions)
            end
        end
    end
end

local function addHandGlowVfx()
    -- Same biped contract as addHandSwirlVfx: no hand bone, no hand glow.
    if not IS_BIPED then return end
    if type(anim.hasBone) == 'function' and not anim.hasBone(self, 'Bip01 L Hand') then return end
    local effect = currentSpell.effects[1]
    local mgef = effect and effectRecords[effect.id]
    local static = mgef and mgef.castStatic and types.Static.records[mgef.castStatic]
    if not static or not static.model then return end
    vfxOptions.vfxId = 'OSSC_HandGlow'
    vfxOptions.boneName = 'Bip01 L Hand'
    vfxOptions.particleTextureOverride = nil
    anim.addVfx(self, static.model, vfxOptions)
end

-- The same three VFX toggles that gate the player's cast effects.
local function addSpellVfx()
    local swirls = settingOr(keysSettings, 'EnablePlayerSwirls', true)
    local hands  = settingOr(keysSettings, 'EnableHandSwirls', true)
    local glow   = settingOr(keysSettings, 'EnableCastGlow', false)
    hasActiveVfx = swirls or hands or glow
    if swirls then addCastStaticVfx(nil, 'OSSC_ActorSwirl') end
    if hands then addHandSwirlVfx() end
    if glow then addHandGlowVfx() end
end

local function stopAllVfx()
    if not hasActiveVfx then return end
    hasActiveVfx = false
    -- See removeVfxSafely: the same cleanup runs while the actor is being
    -- detached, and removeVfx raises on an actor with no animation. One check
    -- covers the whole batch.
    if not anim.hasAnimation(self) then return end
    for i = 1, 10 do
        anim.removeVfx(self, 'OSSC_ActorSwirl_' .. i)
        anim.removeVfx(self, 'OSSC_HandSwirl_' .. i)
    end
    anim.removeVfx(self, 'OSSC_HandGlow')
end

-- ── Engine spell list (combat loophole) ────────────────────────────────────
-- While OSSC owns the actor's casting, its castable spells are hidden from the
-- engine AI so vanilla casting cannot run in parallel; they are handed back
-- when the target leaves the quick-cast range, the actor becomes ineligible
-- or combat ends.
local function isCastableSpellType(record)
    if record == nil then return false end
    if record.type == SPELL_TYPE.Spell then return true end
    return record.type == SPELL_TYPE.Power and cfg_allowPowers == true
end

local function cacheCastableSpells(actorSpells)
    for _, spell in pairs(actorSpells) do
        if isCastableSpellType(spellRecords[spell.id]) then cachedKnownSpells[spell.id] = true end
    end
end

local function updateKnownSpellsCache()
    if IS_SPELL_VENDOR or spellsTemporarilyRemoved then return end
    cacheCastableSpells(types.Actor.spells(self))
end

local function removeAllCastableSpells()
    if IS_SPELL_VENDOR or spellsTemporarilyRemoved then return end
    local actorSpells = types.Actor.spells(self)
    cacheCastableSpells(actorSpells)
    types.Actor.clearSelectedCastable(self)
    local count = 0
    for spellId in pairs(cachedKnownSpells) do
        if actorSpells[spellId] then
            actorSpells:remove(spellId)
            count = count + 1
        end
    end
    spellsTemporarilyRemoved = true
    if count > 0 then debugLogf('Combat Loophole: Stripped %d castable spells from engine AI (Passives kept)', count) end
end

local function restoreAllCastableSpells()
    if not spellsTemporarilyRemoved then return end
    local actorSpells = types.Actor.spells(self)
    local count = 0
    for spellId in pairs(cachedKnownSpells) do
        if not actorSpells[spellId] then
            actorSpells:add(spellId)
            count = count + 1
        end
    end
    spellsTemporarilyRemoved = false
    debugLogf('Combat Loophole: Restored %d spells to engine', count)
end

-- Eligibility is re-checked live so a settings change takes effect even when
-- the caster script is already attached mid-combat: while ineligible this
-- script starts no cast, forces no stance and strips no spells, and onUpdate
-- hands the spell list back to the engine AI. The global script re-checks the
-- same toggles on the next combat-target change and then detaches.
local function isActorEligible()
    if IS_SPELL_VENDOR then return false end
    if self.type == types.NPC then
        if settingOr(npcSettings, 'NPCQuickCastEnabled', true) then return true end
        debugLog('NPC quick-casting disabled by settings')
        return false
    end
    if self.type ~= types.Creature then return false end
    -- The master toggle gates creatures too (mirrors the global attach gate in
    -- isCasterEligible), so flipping it mid-combat stops attached creatures.
    if not settingOr(npcSettings, 'NPCQuickCastEnabled', true) then
        debugLog('NPC quick-casting disabled by settings (master toggle)')
        return false
    end
    if not settingOr(npcSettings, 'NPCQuickCastCreatures', true) then
        debugLog('Creature quick-casting disabled by settings')
        return false
    end
    if IS_BIPED_CREATURE or settingOr(npcSettings, 'NPCQuickCastNonBipedCreatures', true) then return true end
    debugLog('Non-biped creature quick-casting disabled by settings')
    return false
end

local function isOverEncumbered(actor)
    local encumbrance = types.Actor.getEncumbrance(actor)
    local capacity = types.Actor.getCapacity(actor)
    return type(encumbrance) == 'number'
        and type(capacity) == 'number'
        and encumbrance > capacity
end

local function isActorIncapacitated()
    if types.Actor.isDead(self) then return true end
    -- Actor.canMove is also false while overencumbered. Over capacity prevents
    -- locomotion, not spellcasting; treating it as incapacitation silently
    -- failed every quick-cast (start gate, mid-cast check and release re-check
    -- all funnel through here). Keep canMove for real knockdowns/paralysis,
    -- but exclude encumbrance — an over-loaded caster must still cast.
    if not types.Actor.canMove(self) and not isOverEncumbered(self) then
        debugLog('Cast blocked — canMove=false (paralyzed/knocked down)')
        return true
    end
    local silence = types.Actor.activeEffects(self):getEffect('silence')
    if silence and silence.magnitude > 0 then
        debugLog('Cast blocked — silenced')
        return true
    end
    local group = playingGroup(INCAPACITATED_GROUPS)
    if group then
        debugLog('Cast blocked — incapacitated anim: ' .. group)
        return true
    end
    return false
end

-- Hand the engine attack input back after a cast that suppressed an attack.
-- An attack OSSC vetoes mid-cast never gets an animation: the character
-- controller sits in AttackWindUp with nothing to progress and the AI never
-- releases the attack input by itself. Without this release the actor only
-- recovers through the 2s self-heal in onUpdate, i.e. it stands in front of
-- you doing nothing for two seconds after every quick-cast.
local function rearmSuppressedAttack()
    if not attackSuppressedDuringCast then return end
    attackSuppressedDuringCast = false
    -- Never touch a vanilla spell cast: in Spell stance the held input is the
    -- engine's own cast, not a weapon attack OSSC suppressed.
    if types.Actor.getStance(self) ~= STANCE.Weapon then return end
    -- Releasing a wind-up that is actually playing would skip straight to its
    -- release section (an instant swing).
    if playingGroup(HEAVY_ATTACK_GROUPS) then return end
    if not isEngineAttackInputHeld() then return end
    debugLog('Re-arm: releasing the attack input this cast suppressed')
    releaseEngineAttack()
end

-- Play the school cast sound at most once per quickcast (both the cast start
-- and the animation's 'start' text key route through here).
local function playCastSoundOnce(spell)
    if castSoundPlayedForCastId == currentCastId then return end
    local effect = spell.effects[1]
    local mgef = effect and effectRecords[effect.id]
    if not mgef or not mgef.castSound or mgef.castSound == '' then return end
    castSoundPlayedForCastId = currentCastId
    core.sound.playSound3d(mgef.castSound, self)
end

local snapSoundOptions = { volume = 0.45 }

local function playSnapSound()
    local volume = settingOr(animationSettings, 'SnapSoundVolume', 0.45)
    if volume <= 0 then return end
    snapSoundOptions.volume = volume
    core.sound.playSoundFile3d('sound/ossc/qcsnap.mp3', self, snapSoundOptions)
end

local function cleanupCast(reason)
    debugLog('Cleanup cast: ' .. tostring(reason))
    if ngardeParryControlActive then setNgardeParryControl(false) end
    stopAllVfx()
    isCasting = false
    hasFiredThisCast = false
    currentSpell = nil
    currentAnimGroup = nil
    castDeadline = 0.0
    isBound2HWeaponCast = false
    restoreShieldAfterCast()
    rearmSuppressedAttack()
end

local function resetAfterActivation(reason)
    currentCastId = currentCastId + 1
    stopAllVfx()
    isCasting = false
    hasFiredThisCast = false
    currentSpell = nil
    currentAnimGroup = nil
    castDeadline = 0.0
    isBound2HWeaponCast = false
    restoreShieldAfterCast()
    attackSuppressedDuringCast = false
    nextActionTime = 0.0
    nextCastAllowedTime = 0.0
    -- A (re)load wipes all unsavable timers, so any pending detach suspension
    -- is stale — self-heal back to normal casting.  External pauses are
    -- session state as well: the requesting mod asks again after the load.
    Pause.detachPending = false
    Pause.reasons = {}
    Pause.refresh()
    pendingTimersUntil = 0.0
    -- External NGarde control is transient engine state: a save made mid-cast
    -- must never keep guards locked after the load. Unconditional — the
    -- lifecycle reset always leaves the guard released.
    setNgardeParryControl(false)
    reentryGuardUntil = core.getSimulationTime() + REENTRY_GUARD_DURATION
    types.Actor.clearSelectedCastable(self)
    if types.Actor.getStance(self) == STANCE.Spell then types.Actor.setStance(self, STANCE.Weapon) end
    debugLogf('Cell re-entry reset (%s), spell stance suppressed for %.1fs', tostring(reason), REENTRY_GUARD_DURATION)
end

-- ── Casting pause (external request) ───────────────────────────────────────
-- Other mods can hold this actor's spellcasting through the same-actor
-- interface (`I.OSSC_Caster`) or by sending OSSC_SetCasterPaused to the actor,
-- which is what the global route (I.OSSC_Casters in ossc_global.lua) forwards.
-- A pause gates casting exactly like a pending detach - no new casts, no
-- re-stripping - and additionally hands the engine's spell list back and stops
-- an in-flight cast, so a mod that wants to drive the actor itself is not
-- fighting OSSC over the same animation, stance and spell list.
--
-- Requests are keyed by reason, so two mods can pause independently and one
-- unpausing does not resume the actor for the other.  A pause is session
-- state, like every other unsavable bit of this script: a save/load clears it
-- (the mod that asked for it is responsible for asking again).

--- Set or release one pause and refresh the gate.  Returns true when the
--- request changed something, so a caller can tell a redundant request from a
--- real one.  A pause with no reason is filed under the generic 'external'
--- reason; a resume with no reason releases every pause.
function Pause.set(paused, reason)
    local releaseAll = (not paused) and (type(reason) ~= 'string' or reason == '')
    if type(reason) ~= 'string' or reason == '' then reason = 'external' end

    if paused then
        if Pause.reasons[reason] then return false end
        Pause.reasons[reason] = true
        Pause.refresh()
        -- Hand the engine its spell list back and stop any in-flight cast:
        -- while paused this actor is not OSSC's to drive.
        restoreAllCastableSpells()
        if isCasting then cleanupCast('paused (' .. reason .. ')') end
        debugLogf('Caster paused by %s', reason)
        return true
    end

    if releaseAll then
        if next(Pause.reasons) == nil then return false end
        Pause.reasons = {}
        Pause.refresh()
        debugLogf('Caster resumed: every pause released')
        return true
    end

    if not Pause.reasons[reason] then return false end
    Pause.reasons[reason] = nil
    Pause.refresh()
    debugLogf('Caster resumed (%s)', reason)
    return true
end

-- ── Targeting ──────────────────────────────────────────────────────────────
-- ── Follow protection ──────────────────────────────────────────────────────
-- A Combat target can go stale and point at the actor's own leader, which
-- would have a follower quick-cast hostile spells at the player it is
-- following. The Follow package is snapshotted at init and kept current by the
-- Start/RemoveAIPackage events. It is deliberately never re-scanned from
-- onUpdate: walking the AI package stack every frame is exactly the cost those
-- events exist to avoid.
local followTargetKey = nil

-- Actors are compared by a stable key rather than by object identity: the
-- engine hands out fresh proxies for the same actor, so `==` is not reliable
-- across calls.
local function actorKey(obj)
    if not obj then return nil end
    return obj.id or obj.recordId
end

local function isFollowPackage(pkg)
    return type(pkg) == 'table' and pkg.type == 'Follow'
end

-- Only used at init. Everything after that is driven by the package events,
-- so onUpdate never walks the AI stack.
local function scanFollowPackage()
    followTargetKey = nil
    if not (I.AI and type(I.AI.forEachPackage) == 'function') then return end
    I.AI.forEachPackage(function(pkg)
        if isFollowPackage(pkg) and pkg.target then
            followTargetKey = actorKey(pkg.target)
        end
    end)
end

local function getCombatTarget()
    -- Never quickcast while the engine is casting.
    if types.Actor.getStance(self) == STANCE.Spell then return nil end
    local target = I.AI.getActiveTarget('Combat')
    if not target or not target:isValid() or types.Actor.isDead(target) then return nil end
    return target
end

-- True when the combat target is the actor's own leader. Deliberately NOT
-- folded into getCombatTarget: a protected follower is still in combat, and
-- reporting "no target" would make onUpdate hand the spells back to the engine,
-- which would then cast at the leader through the vanilla path. Keeping the
-- spells stripped is what actually protects the player; this only stops OSSC
-- from quick-casting.
local function isFollowProtected(target)
    return followTargetKey ~= nil and actorKey(target) == followTargetKey
end

-- Per-animation launch offsets (see scripts/ossc/ossc_launch_offsets.lua).
-- Actors always use the 'third' table applied from the actor origin along
-- the actor's facing.
local function getCasterSpawnPos(animGroup)
    local offset = launchOffsets.get(animGroup, false)
    local rotation = self.rotation
    return self.position
        + (rotation * FORWARD) * offset.forward
        + (rotation * LEFT) * offset.left
        + UP * offset.up
end

local rayOptions = { ignore = self }

local function hasLineOfSight(startPos, endPos, target)
    local hit = nearby.castRay(startPos, endPos, rayOptions)
    if not hit.hit then return true end
    if hit.hitObject == target then return true end
    return (hit.hitPos - endPos):length() < 60
end

-- ── Spell selection ────────────────────────────────────────────────────────
local function schoolName(mgef)
    local school = mgef and mgef.school
    if type(school) == 'string' then return school:lower() end
    return SCHOOL_STRS[school] or 'destruction'
end

local function isRestorationSchool(mgef)
    return mgef.school == 5 or mgef.school == 'restoration'
end

-- True when any effect of the spell heals/restores at Touch or Target range
-- (restoration school, or a Restore-Health-style effect id). Such spells are
-- never quick-cast: the cast is aimed at the combat target, so a touch/target
-- Restore Health would HEAL the player (reported with Fair Care's touch-heal
-- spells on Ordinators). Deliberately narrow on ids: Absorb/Drain Health are
-- damage effects that must remain quick-castable.
local function healsAtNonSelfRange(record)
    for _, effect in ipairs(record.effects) do
        if effect.range ~= RANGE.Self then
            local mgef = effectRecords[effect.id]
            if mgef and isRestorationSchool(mgef) then return true end
            if tostring(effect.id):lower():find('restorehealth', 1, true) then return true end
        end
    end
    return false
end

local healSpells, buffSpells, touchSpells, targetSpells = {}, {}, {}, {}

-- ── Public actor API: spell filter + on-demand cast (I.OSSC_Caster) ───────
-- One table for both features, because this file sits close to Lua's limit of
-- 200 active locals per chunk: everything below lives inside the closure, so
-- the script gains exactly one local.
--
--   * Spell filter (isIgnored).  The authoritative list lives in the global
--     script (I.OSSC_Casters) — that is where a mod registers a veto — and
--     every caster mirrors it.  A caster asks for the current copy the first
--     time it picks spells, because a script that attaches mid-game would
--     otherwise never hear about vetoes registered before it existed.  A
--     filtered spell stays usable: a hotkey press, another mod's explicit
--     cast, and castSpellAtTarget all still cast it.  It is only skipped when
--     OSSC itself is choosing (categorizeSpells below).
--
--   * castSpellAtTarget.  The same request I.OSSC_Casters.castSpellAtTarget
--     sends for an actor without an OSSC script, built and paid here instead
--     so the actor's own quick-cast penalty settings decide the strength.
--     The cast animation is not played: the caller drives its own sequence
--     and only wants the spell launched through Spell Framework Plus.
--     `isFree` mirrors OSSC's launch path - nil = this script pays the
--     magicka and marks the launch prepaid, true = the caller already paid,
--     false = leave the charge to Spell Framework Plus' launch-time guard.
local OSSCExternal = (function()
    local ignored, asked = {}, false

    local function requestIgnored()
        if asked then return end
        asked = true
        core.sendGlobalEvent('OSSC_RequestIgnoredSpells', { actor = self })
    end

    local function setIgnoredList(ids)
        ignored = {}
        for _, spellId in ipairs(ids or {}) do
            if type(spellId) == 'string' and spellId ~= '' then
                ignored[spellId:lower()] = true
            end
        end
        asked = true
    end

    local function isIgnored(spellId)
        if type(spellId) ~= 'string' or spellId == '' then return false end
        requestIgnored()
        return ignored[spellId:lower()] == true
    end

    local function setIgnored(spellId, ignoredFlag)
        if type(spellId) ~= 'string' or spellId == '' then
            return false, 'spellId must be a record id string'
        end
        ignored[spellId:lower()] = (ignoredFlag ~= false) or nil
        core.sendGlobalEvent('OSSC_SetSpellIgnored',
            { spellId = spellId, ignored = ignoredFlag ~= false })
        return true
    end

    local function resolveTarget(target)
        if target == nil then return nil, nil end
        local kind = type(target)
        if kind == 'userdata' or kind == 'table' then
            if target.isValid and not target:isValid() then return nil, nil end
            if target.position then return target, target.position end
        end
        if target.x ~= nil and target.y ~= nil and target.z ~= nil then return nil, target end
        return nil, nil
    end

    local function castSpellAtTarget(args)
        if type(args) ~= 'table' then return false, 'a request table is required' end
        local spellId = args.spellId
        if type(spellId) ~= 'string' or spellId == '' then
            return false, 'spellId must be a record id string'
        end
        local record = spellRecords[spellId]
        if not record then
            return false, 'unknown spell record: ' .. tostring(spellId)
        end
        if self and self.isValid and not self:isValid() then
            return false, 'the actor is not valid'
        end
        if isActorIncapacitated() then return false, 'the actor is incapacitated' end

        local targetObj, targetPos = resolveTarget(args.target)
        if args.target ~= nil and targetObj == nil and targetPos == nil then
            return false, 'target must be an actor, an object or a util.vector3'
        end

        local firstEffect = record.effects and record.effects[1]
        local spell = {
            id      = spellId,
            type    = record.type,
            cost    = record.cost or 0,
            effects = record.effects,
            area    = firstEffect and firstEffect.area or 0,
            range   = firstEffect and firstEffect.range or RANGE.Self,
        }

        local startPos = getCasterSpawnPos(currentAnimGroup)
        local direction = self.rotation * FORWARD
        local hitObject, hitPos = nil, nil
        if spell.range == RANGE.Self then
            targetObj, targetPos = self, self.position
            hitObject, hitPos = self, self.position
        elseif targetPos then
            local aim = targetPos + TARGET_AIM_OFFSET
            direction = (aim - startPos):normalize()
            hitPos = aim
            if spell.range == RANGE.Touch then hitObject = targetObj end
        end

        if hitObject and hitObject ~= self
            and friendlyFire.isFriendlyFireBlocked(self, hitObject, spell.effects) then
            return false, 'the cast would hit a friendly target'
        end

        local wePay = args.isFree == nil
        local payloadIsFree = args.isFree ~= false
        local cost = spell.cost or 0
        if wePay and cost > 0 then
            local magicka = types.Actor.stats.dynamic.magicka(self)
            if magicka.current < cost then return false, 'not enough magicka' end
            magicka.current = math.max(0, magicka.current - cost)
        end

        local effectScale = tonumber(args.effectScale) or getQuickCastEffectScale(spell)
        local userData = { OSSC = true, NPC = true, External = true }
        if type(args.userData) == 'table' then
            for key, value in pairs(args.userData) do userData[key] = value end
        end

        debugLogf('EXTERNAL CAST: spell=%s target=%s effectScale=%.2f prepaid=%s',
            spellId, hitObject and tostring(hitObject.recordId) or 'position',
            effectScale, tostring(payloadIsFree))
        core.sendGlobalEvent('MagExp_CastRequest', {
            attacker       = self,
            caster         = self,
            spellId        = spellId,
            startPos       = startPos,
            direction      = direction,
            area           = spell.area,
            isFree         = payloadIsFree,
            hitObject      = hitObject,
            hitPos         = hitPos,
            spawnOffset    = 80,
            isGodMode      = false,
            effectScale    = effectScale,
            showAllCastVfx = true,
            userData       = userData,
        })
        return true
    end

    return {
        requestIgnored    = requestIgnored,
        setIgnoredList    = setIgnoredList,
        isIgnored         = isIgnored,
        setIgnored        = setIgnored,
        castSpellAtTarget = castSpellAtTarget,
    }
end)()

local function clearList(list)
    for i = #list, 1, -1 do list[i] = nil end
end

local function categorizeSpells()
    updateKnownSpellsCache()
    clearList(healSpells)
    clearList(buffSpells)
    clearList(touchSpells)
    clearList(targetSpells)
    local magicka = types.Actor.stats.dynamic.magicka(self).current
    for spellId in pairs(cachedKnownSpells) do
        local record = spellRecords[spellId]
        local firstEffect = record and record.effects[1]
        -- Spells a mod filtered out (I.OSSC_Casters.ignoreSpell) are never
        -- picked.  Skipped silently: the mod that asked for it knows why.
        if firstEffect and not OSSCExternal.isIgnored(spellId)
            and isCastableSpellType(record) and magicka >= record.cost then
            local range = firstEffect.range
            if range == RANGE.Self then
                -- Don't re-cast a self spell whose effects are still running
                -- (e.g. a shield/fortify buff that hasn't expired yet).
                if types.Actor.activeSpells(self):isSpellActive(spellId) then
                    debugLog('Self spell skipped — effects still active: ' .. spellId)
                else
                    local mgef = effectRecords[firstEffect.id]
                    local bucket = buffSpells
                    if (mgef and isRestorationSchool(mgef)) or tostring(firstEffect.id):lower():find('heal', 1, true) then
                        bucket = healSpells
                    end
                    bucket[#bucket + 1] = record
                end
            elseif healsAtNonSelfRange(record) then
                -- Healing is self-only: never quick-cast a heal at the combat
                -- target (it would heal the player).
                debugLog(RANGE_STRS[range] .. ' heal spell skipped — healing spells are self-only: ' .. spellId)
            elseif range == RANGE.Touch then
                touchSpells[#touchSpells + 1] = record
            else
                targetSpells[#targetSpells + 1] = record
            end
        end
    end
end

local function pick(list)
    return list[math.random(#list)]
end

local function selectTacticalSpell(distance)
    categorizeSpells()
    local health = types.Actor.stats.dynamic.health(self)
    local healthPct = health.current / math.max(1, health.base) * 100
    if healthPct < settingOr(npcSettings, 'NPCQuickCastHealThreshold', 40) and #healSpells > 0 then
        return pick(healSpells), 'heal'
    end
    if distance <= cfg_minDist then
        if #touchSpells > 0 then return pick(touchSpells), 'touch' end
        if #buffSpells > 0 and math.random(100) <= 40 then return pick(buffSpells), 'buff' end
        if #targetSpells > 0 then return pick(targetSpells), 'target_fallback' end
        return nil, 'none'
    end
    if #targetSpells > 0 then return pick(targetSpells), 'target' end
    if #buffSpells > 0 and math.random(100) <= 50 then return pick(buffSpells), 'buff' end
    return nil, 'none'
end

-- ── Firing ─────────────────────────────────────────────────────────────────
local CAST_USER_DATA = { OSSC = true, NPC = true }

local function fireSpellPayload()
    if hasFiredThisCast or not isCasting then return end
    -- Re-check incapacitation at the release moment: a stagger, a knock,
    -- paralysis or death that lands mid-cast cancels the cast instead of
    -- launching the spell — same rule vanilla applies to the player.
    if isActorIncapacitated() then
        debugLog('Cast interrupted at release — staggered/knocked/incapacitated')
        cleanupCast('interrupted at release')
        return
    end
    -- Do not fire into a cell transition window; the projectile would be
    -- created into an unloading/reloading cell and MagExp can't clean it up.
    if core.getSimulationTime() < reentryGuardUntil then
        debugLog('fireSpellPayload suppressed — inside reentry guard window')
        cleanupCast('reentry guard')
        return
    end
    hasFiredThisCast = true
    local spell = currentSpell
    local range = currentRange
    local startPos = getCasterSpawnPos(currentAnimGroup)
    local direction = self.rotation * FORWARD
    local target, hitObject = nil, nil
    if range == RANGE.Self then
        target, hitObject = self, self
    else
        target = getCombatTarget()
        if target then
            direction = (target.position + TARGET_AIM_OFFSET - startPos):normalize()
            if range == RANGE.Touch then hitObject = target end
            if friendlyFire.isFriendlyFireBlocked(self, target, spell.effects) then
                debugLog('QUICKCAST VETOED — friendly fire: ' .. spell.id .. ' -> ' .. tostring(target.recordId))
                cleanupCast('friendly fire veto')
                return
            end
        end
    end
    local magicka = types.Actor.stats.dynamic.magicka(self)
    local cost = spell.cost
    if magicka.current < cost then
        debugLogf('Insufficient magicka at fire time (%s/%s)', tostring(magicka.current), tostring(cost))
        cleanupCast('out of magicka')
        return
    end
    magicka.current = math.max(0, magicka.current - cost)
    -- UseFatigue (Gameplay settings): when enabled, the actor's quick-cast
    -- pays the same MCP fatigue cost as the player's.
    CastCosts.payFatigue(cost)
    -- QuickCastChancePenalty (Gameplay settings): when enabled, the release
    -- is rolled exactly like the player's — vanilla base cast chance times
    -- the penalty scale. A failure keeps magicka and fatigue consumed and
    -- fizzles with the vanilla failure sound (player parity: the gesture
    -- played, the costs were paid, the spell does not land). While the
    -- setting is 'off' the cast lands unconditionally, as before.
    if CastCosts.penaltyActive() then
        local baseChance, effectiveSchool = CastCosts.baseChance(spell)
        local chanceScale = CastCosts.chanceScale(effectiveSchool)
        local chance = math.max(0, math.min(100, util.round(baseChance * chanceScale)))
        local okCast = chance >= 100 or math.random(0, 99) < chance
        debugLogf('Cast chance roll: base=%s scale=%.2f final=%s ok=%s (%s)',
            tostring(baseChance), chanceScale, tostring(chance), tostring(okCast), spell.id)
        if not okCast then
            core.sound.playSound3d('Spell Failure', self, { volume = 1.0 })
            cleanupCast('cast failed the chance roll')
            return
        end
    end
    local effectScale = getQuickCastEffectScale(spell)
    debugLogf('QUICKCAST DISPATCHED: Spell=%s Range=%d MagickaRemaining=%.0f/%.0f Target=%s',
        spell.id, range, magicka.current, magicka.base, target and tostring(target.recordId) or 'none')
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker       = self,
        caster         = self,
        spellId        = spell.id,
        startPos       = startPos,
        direction      = direction,
        area           = 0,
        isFree         = true,
        hitObject      = hitObject,
        isGodMode      = false,
        effectScale    = effectScale,
        showAllCastVfx = true,
        userData       = CAST_USER_DATA,
    })
end

-- ── Shield Casting Penalty (mirrors the player-side formula) ──────────────
-- Optional slowdown for quick-casting while a shield is equipped.
-- Carry-Capacity Ratio:
--   capacity = (Strength + Proficiency) / 2
--   penalty  = W * 45 / (capacity + 45)
--   mult     = 1 - (penalty / 100) * v
-- v is the strength the 'ShieldCastingPenalty' setting picks (Off / 10%..100%
-- / Skill based — Penalty.shield in scripts/ossc/ossc_penalty.lua; the
-- skill-based strength follows Proficiency: 0 → 1.0, 100+ → 0). Proficiency
-- is the cast spell school's skill; creatures have no magic school skills, so
-- they get Strength-only (P = 0) and, skill based, the whole slowdown. Never
-- below 0.55x.
local function getShieldCastingPenaltyMult(school)
    local mode = settingOr(generalSettings, 'ShieldCastingPenalty', 'off')
    local skillBased = Penalty.isSkillBased(mode)
    if not skillBased and Penalty.shield.strength(mode) <= 0 then return 1.0 end
    local shield = types.Actor.getEquipment(self, SLOT.CarriedLeft)
    if not shield or shield.type ~= types.Armor then return 1.0 end
    local weight = types.Armor.record(shield).weight
    if not weight or weight <= 0 then return 1.0 end
    if weight > 45 then weight = 45 end

    local strength = types.Actor.stats.attributes.strength(self).modified
    local proficiency = 0
    if self.type == types.NPC then
        local skill = types.NPC.stats.skills[school]
        if skill then proficiency = skill(self).modified end
    end
    local v = Penalty.shield.resolve(mode, proficiency)
    if v <= 0 then return 1.0 end
    local capacity = (strength + proficiency) / 2
    local penalty  = weight * 45 / (capacity + 45)
    local mult = 1 - (penalty / 100) * v
    if mult < 0.55 then mult = 0.55 end
    debugLogf('Shield penalty: W=%s S=%s P=%s (%s) → penalty=%s mult=%s',
        tostring(weight), tostring(strength), tostring(proficiency), school, tostring(penalty), tostring(mult))
    return mult
end

-- ── Cast start ─────────────────────────────────────────────────────────────
local function chooseAnimGroup(school, range)
    -- Per-entity rolled animation set (rolled when the script attached):
    -- takes precedence over the Cast Animations page when enabled.
    if cfg_randomAnims then
        if not rolledAnims then rollAnimSet() end
        local rolled = rolledAnims[school]
        local group = rolled and rolled[range]
        if group and group ~= '' then return group end
    end
    local keys = ANIM_SETTING_KEYS[school]
    local group = keys and animationSettings:get(keys[range])
    if group and group ~= '' then return group end
    local bySchool = ANIM_BY_SCHOOL_AND_RANGE[school]
    if bySchool and bySchool[range] then return bySchool[range] end
    if range == RANGE.Self then return 'quickbuff' end
    return 'quickcast'
end

local function getCastSpeed(group, school)
    local speed = (animSpeedSettings:get(SPEED_KEYS[group] or 'AnimSpeed_Quickcast') or 1.0)
        * (animSpeedSettings:get('AnimSpeedScale') or 1.0)
        * getShieldCastingPenaltyMult(school)
    if speed <= 0 then return 1.0 end
    -- Clamp so the finish timer can never grow past ~12s (the global script's
    -- safe-detach window assumes bounded cast timers).
    if speed < 0.1 then return 0.1 end
    return speed
end

-- Upper-body-only cast blend, tuned so all three rules hold at once:
--   * Arms + Torso = PRIORITY.Hit (6) when no 1H swing is in flight. Beats
--     weapon-stance idles so a two-hander's grip cannot pin the casting arm,
--     but stays BELOW PRIORITY.Weapon (7) so a real weapon attack that starts
--     mid-cast still wins.
--   * When a 1H / H2H / thrown attack is already playing, RightArm + Torso
--     are left out of the mask so the cast cannot steal those bones and
--     freeze the swing mid-animation.
--   * LowerBody is deliberately NOT in the blend mask. NPC/creature movement
--     is driven by the active LowerBody animation's root motion; with no
--     LowerBody claim at all, the weapon locomotion group keeps the legs/root
--     for the whole quickcast.
-- Every group in the blend mask is listed explicitly: playBlended seeds an
-- unlisted group with PRIORITY.Default (0). The table is reused across casts;
-- playBlended reads it synchronously.
local castPlayOptions = {
    priority = { [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Hit },
    startKey = 'start',
    stopKey = 'stop',
    blendMask = anim.BLEND_MASK.LeftArm,
    speed = 1.0,
}

local function prepareCastPlayOptions(speed)
    local priority = castPlayOptions.priority
    local blendMask = anim.BLEND_MASK.LeftArm
    if playingGroup(LIGHT_ATTACK_GROUPS) then
        priority[anim.BONE_GROUP.RightArm] = nil
        priority[anim.BONE_GROUP.Torso] = nil
    else
        priority[anim.BONE_GROUP.RightArm] = anim.PRIORITY.Hit
        priority[anim.BONE_GROUP.Torso] = anim.PRIORITY.Hit
        blendMask = blendMask + anim.BLEND_MASK.RightArm + anim.BLEND_MASK.Torso
    end
    castPlayOptions.blendMask = blendMask
    castPlayOptions.speed = speed
end

local function playCastAnimation(group)
    castPlayOptions.skip = nil
    I.AnimationController.playBlendedAnimation(group, castPlayOptions)
end

-- A skeleton without the rolled/configured group plays nothing: fall back to
-- the two groups every OSSC animation set ships.
local function onFallbackTimer()
    if not isCasting or currentCastId ~= armedCastId then return end
    if anim.isPlaying(self, currentAnimGroup) then return end
    currentAnimGroup = currentRange == RANGE.Self and 'quickbuff' or 'quickcast'
    playCastAnimation(currentAnimGroup)
end

local function onReleaseTimer()
    if not isCasting or currentCastId ~= armedCastId or hasFiredThisCast then return end
    fireSpellPayload()
end

local function onFinishTimer()
    if not isCasting or currentCastId ~= armedCastId then return end
    if not hasFiredThisCast then fireSpellPayload() end
    cleanupCast('finished')
end

local function hasTargetRangeEffect(spell)
    for _, effect in ipairs(spell.effects) do
        if effect.range == RANGE.Target then return true end
    end
    return false
end

-- No target-range quick-casts while the actor is swimming (whole body in the
-- water, not merely feet wading). Self and Touch casts stay allowed.
local function swimmingBlocksCast(spell)
    if not settingOr(generalSettings, 'BlockTargetSpellsWhileSwimming', true) then return false end
    return hasTargetRangeEffect(spell) and types.Actor.isSwimming(self)
end

local function startQuickcast(spell, target)
    if isCasting then return end
    if swimmingBlocksCast(spell) then
        debugLog('Cast blocked — swimming: target spells cannot be quick-cast')
        return
    end
    local firstEffect = spell.effects[1]
    local range = firstEffect.range
    local school = schoolName(effectRecords[firstEffect.id])
    local group = chooseAnimGroup(school, range)
    local speed = getCastSpeed(group, school)

    isCasting = true
    hasFiredThisCast = false
    currentSpell = spell
    currentAnimGroup = group
    currentRange = range
    currentCastId = currentCastId + 1
    armedCastId = currentCastId
    attackSuppressedDuringCast = false

    local now = core.getSimulationTime()
    local releaseDelay, finishDelay = 0.5 / speed, 1.2 / speed
    pendingTimersUntil = math.max(pendingTimersUntil, now + finishDelay + 0.3)
    -- Hard deadline for the whole cast (and for the heavy-attack block it
    -- arms): if the finish timer is lost, the watchdog in onUpdate resolves
    -- the cast here instead of leaving the actor unable to swing again.
    castDeadline = now + finishDelay + CAST_DEADLINE_MARGIN

    local stance = types.Actor.getStance(self)
    if stance == STANCE.Weapon or stance == STANCE.Nothing then lastNonSpellStance = stance end
    types.Actor.clearSelectedCastable(self)
    types.Actor.setStance(self, STANCE.Weapon)
    isBound2HWeaponCast = hasBound2HWeaponEffect(spell)
    suppressShieldDuringCast()
    -- The start gate in evaluateCombatQuickcast has already passed: lock
    -- NGarde now so a guard cannot be raised over this cast.
    setNgardeParryControl(true)
    debugLogf("QUICKCAST START: Spell='%s' AnimGroup=%s Speed=%.2f Target=%s Stance=%d",
        spell.id, group, speed, target and tostring(target.recordId) or 'none', stance)

    playCastSoundOnce(spell)
    if group == 'qcsnap' then playSnapSound() end
    addSpellVfx()
    if IS_BIPED then
        prepareCastPlayOptions(speed)
        playCastAnimation(group)
        async:newUnsavableSimulationTimer(0.01, onFallbackTimer)
    else
        -- Non-biped skeletons carry none of the quickcast animation groups:
        -- the release/finish timers below drive the cast on their own.
        debugLog('Non-biped cast — no cast animation available, timers drive the cast')
    end
    async:newUnsavableSimulationTimer(releaseDelay, onReleaseTimer)
    async:newUnsavableSimulationTimer(finishDelay, onFinishTimer)
end

local function onTextKey(groupname, key)
    if not isCasting or groupname ~= currentAnimGroup then return end
    local k = tostring(key):lower()
    if k == 'start' or k == 'equip start' then
        playCastSoundOnce(currentSpell)
    elseif k == 'release' then
        fireSpellPayload()
    elseif k == 'stop' then
        if not hasFiredThisCast then fireSpellPayload() end
        cleanupCast('stop key')
    end
end

-- ── Combat evaluation ──────────────────────────────────────────────────────
local function castChance(distance)
    if distance <= cfg_minDist then return cfg_baseChance end
    if distance > cfg_maxDist then return 0 end
    local ratio = (distance - cfg_minDist) / math.max(1, cfg_maxDist - cfg_minDist)
    return cfg_baseChance * (1 - ratio)
end

local function evaluateCombatQuickcast(now, target)
    if isCasting or isActorIncapacitated() then return end
    if combatAnimBlocksCast(now) then return end
    if shouldBlockDuringNgardeParry() then
        debugLog('Cast blocked — NGarde parry is active')
        return
    end
    local distance = (target.position - self.position):length()
    local chance = castChance(distance)
    if cfg_debugMode then
        local magicka = types.Actor.stats.dynamic.magicka(self)
        debugLogf('Eval tick: Dist=%.1f Chance=%.1f%% Cooldown=%.2fs Target=%s Magicka=%.0f/%.0f Stance=%s',
            distance, chance * 100, math.max(0, nextCastAllowedTime - now), tostring(target.recordId),
            magicka.current, magicka.base, tostring(types.Actor.getStance(self)))
    end
    if core.isWorldPaused() or now < nextCastAllowedTime or not cfg_enabled or chance <= 0 then return end
    local roll = math.random()
    if roll > chance then return end
    local spell, strategy = selectTacticalSpell(distance)
    if not spell then return end
    if spell.effects[1].range ~= RANGE.Self
        and not hasLineOfSight(getCasterSpawnPos(nil), target.position + LOS_TARGET_OFFSET, target) then
        return
    end
    local cooldown = cfg_cooldownMin + math.random() * (cfg_cooldownMax - cfg_cooldownMin)
    nextCastAllowedTime = now + cooldown
    debugLogf("Eval tick: Dist=%.1f Chance=%.1f%% Rolled=%.1f%% -> SUCCESS! Selected spell='%s' (strategy=%s, cd=%.1fs)",
        distance, chance * 100, roll * 100, spell.id, strategy, cooldown)
    startQuickcast(spell, target)
end

-- The play handler vetoes heavy-attack plays while the cast owns the hands,
-- but an attack can already be in flight when the cast starts. Abort it the
-- SAFE way: release the engine attack input first (so the character
-- controller can leave its wind-up state on its own), then cancel the
-- animation.
local function abortHeavyAttack()
    releaseEngineAttack()
    attackSuppressedDuringCast = true
    local group = playingGroup(HEAVY_ATTACK_GROUPS)
    if not group then return end
    debugLog('Aborted ' .. group .. ' attack during quickcast (update)')
    anim.cancel(self, group)
end

-- Self-heal for a dead-locked engine attack (defence in depth, e.g. for
-- actors already stuck by an older OSSC build in this session): a heavy
-- weapon is equipped, the actor is in Weapon stance, no heavy attack
-- animation is playing, yet the engine attack input has been held for
-- seconds — the upper-body state machine is stranded in its wind-up.
local function healStuckAttackInput(now)
    if isCasting or not isEngineAttackInputHeld()
        or types.Actor.getStance(self) ~= STANCE.Weapon
        or getExcludedWeaponGroup() == nil
        or playingGroup(HEAVY_ATTACK_GROUPS) then
        stuckAttackInputSince = nil
        return
    end
    if stuckAttackInputSince == nil then
        stuckAttackInputSince = now
        return
    end
    if now - stuckAttackInputSince <= STUCK_ATTACK_INPUT_TIMEOUT then return end
    debugLog('Self-heal: releasing stuck engine attack input (dead-locked wind-up)')
    releaseEngineAttack()
    stuckAttackInputSince = now -- re-arm in case it sticks again
end

-- Debug heartbeat, independent from combat/cast logic: one line per poll
-- interval while debug logging is enabled.
local function debugHeartbeat(now, dt)
    nextDebugTick = now + math.max(0.1, cfg_pollInterval)
    local target = getCombatTarget()
    local targetId, distance = 'NONE', -1
    if target then
        targetId = tostring(target.recordId)
        distance = (target.position - self.position):length()
    end
    local magicka = types.Actor.stats.dynamic.magicka(self)
    debugLogf('DEBUG TICK | dt=%.3f | sim=%.2f | combat=%s | casting=%s | target=%s | dist=%.1f | stance=%s | magicka=%.0f/%.0f | nextCast=%.2f',
        dt, now, tostring(inCombat), tostring(isCasting), targetId, distance,
        tostring(types.Actor.getStance(self)), magicka.current, magicka.base, nextCastAllowedTime)
end

local function onUpdate(dt)
    if IS_SPELL_VENDOR then return end
    local now = core.getSimulationTime()

    -- Cast watchdog: a cast whose 'stop' text key AND finish timer never
    -- arrived would otherwise stay "casting" for the rest of the fight.
    if isCasting and now > castDeadline then
        debugLog('Cast watchdog — cast outlived its window, resolving it')
        if not hasFiredThisCast then fireSpellPayload() end
        cleanupCast('watchdog')
    end

    if shouldBlockHeavyAttack() then abortHeavyAttack() end
    healStuckAttackInput(now)

    if isCasting and not hasFiredThisCast and isActorIncapacitated() then
        debugLog('Quickcast cancelled — incapacitated mid-cast')
        cleanupCast('incapacitated mid-cast')
        return
    end

    if cfg_debugMode and now >= nextDebugTick then debugHeartbeat(now, dt) end

    if not isActorEligible() or types.Actor.isDead(self) then
        -- No new casts, and hand the spell list back to the engine AI so it
        -- is not left stripped.
        restoreAllCastableSpells()
        return
    end

    -- Pick up settings changes mirrored into global storage (cheap, 1 Hz).
    if now >= nextSettingsRefresh then
        nextSettingsRefresh = now + 1.0
        refreshSettings()
    end

    -- OSSC owns casting inside Maximum Cast Distance. Outside that distance,
    -- the vanilla engine is allowed to use its normal spell stance.
    local target = getCombatTarget()
    inCombat = target ~= nil
    if not target or (target.position - self.position):length() > cfg_maxDist then
        if not isCasting then restoreAllCastableSpells() end
        return
    end

    if reentryGuardUntil > now then types.Actor.clearSelectedCastable(self) end
    -- While a detach is pending (combat ended, timers draining or waiting for
    -- removal) never start a new cast and never re-strip engine spells: new
    -- timers would re-create the removal race, and re-stripped spells would
    -- stay hidden once the script is gone.
    if not spellsTemporarilyRemoved and not Pause.suspended then removeAllCastableSpells() end
    if types.Actor.getStance(self) == STANCE.Nothing then types.Actor.setStance(self, STANCE.Weapon) end
    if Pause.suspended or now < nextActionTime then return end
    nextActionTime = now + cfg_pollInterval
    if isFollowProtected(target) then return end
    evaluateCombatQuickcast(now, target)
end

-- ── Engine attack plays ────────────────────────────────────────────────────
-- Never veto equip / unequip plays: the engine needs them to re-attach the
-- weapon (the "equip attach" text key) — vetoing them would leave the weapon
-- hidden and desync the draw state. Only the attack sections (wind-up /
-- release / follow-through) are blocked.
local function isEquipPlay(options)
    local startKey = options.startKey or options.startkey
    if type(startKey) == 'string' and startKey:find('equip start', 1, true) then return true end
    local stopKey = options.stopKey or options.stopkey
    return type(stopKey) == 'string' and stopKey:find('equip stop', 1, true) ~= nil
end

-- Mid-cast heavy-weapon attack block (BlockWeaponDuringQuickcast): if the
-- engine starts a 2H / bow / crossbow attack while the cast animation has the
-- hands busy, VETO the play (options.skip — the built-in animation controller
-- then never plays it) and release the engine attack input so the character
-- controller immediately drops back out of its wind-up state. One-handed /
-- hand-to-hand / thrown groups are never touched.
local function onPlayBlendedAnimation(groupname, options)
    if type(groupname) ~= 'string' then return end
    -- Engine attack wind-ups are started with a blended play whose stop key
    -- ends in "min attack"/"max attack": open the charge window (the text
    -- key handler closes it once the attack is released). The engine passes
    -- the keys as stopKey; Lua callers may use the lowercase spelling.
    if COMBAT_ANIM_GROUP_SET[groupname] then
        local stopKey = options.stopKey or options.stopkey
        if type(stopKey) == 'string' and isChargeKey(stopKey) then
            combatChargeUntil = core.getSimulationTime() + COMBAT_CHARGE_HOLD_WINDOW
        end
    end
    if not HEAVY_ATTACK_GROUP_SET[groupname] then return end
    if not shouldBlockHeavyAttack() then return end
    if isEquipPlay(options) then return end
    debugLog('Vetoed ' .. groupname .. ' attack play during quickcast')
    -- Remember that this cast took an attack away from the actor: the input
    -- has to be handed back when the cast ends (rearmSuppressedAttack),
    -- otherwise the AI is left holding it with a wind-up that can never
    -- progress.
    attackSuppressedDuringCast = true
    options.skip = true
    -- The engine switches to its attack wind-up state even for a vetoed
    -- play; without this release the AI would be stranded in that state.
    releaseEngineAttack()
end

for i = 1, #QUICKCAST_GROUPS do
    I.AnimationController.addTextKeyHandler(QUICKCAST_GROUPS[i], onTextKey)
end
for i = 1, #COMBAT_ANIM_GROUPS do
    I.AnimationController.addTextKeyHandler(COMBAT_ANIM_GROUPS[i], onCombatAnimTextKey)
end
I.AnimationController.addPlayBlendedAnimationHandler(onPlayBlendedAnimation)

-- ── Hit / Death animation abort ────────────────────────────────────────────
-- If the caster takes a hit or dies while quickcasting, abort the cast
-- immediately so the hit / death animation is not fighting the cast anim.
local function onHitDeathTextKey(groupname, key)
    if not isCasting then return end
    local lowerKey = tostring(key):lower()
    if lowerKey ~= 'start' then return end
    debugLog('Hit/death animation \'' .. groupname .. '\' started — aborting quickcast')
    local castGroup = currentAnimGroup  -- capture before cleanupCast clears it
    cleanupCast('hit/death interrupt [' .. groupname .. ']')
    if castGroup then
        anim.cancel(self, castGroup)
        debugLog('Cancelled cast animation group: ' .. castGroup)
    end
end

local HIT_DEATH_GROUPS = {
    'hit1','hit2','hit3','hit4','hit5',
    'death1','death2','death3','death4','death5',
    'swimhit','swimdeath1',
}
for i = 1, #HIT_DEATH_GROUPS do
    I.AnimationController.addTextKeyHandler(HIT_DEATH_GROUPS[i], onHitDeathTextKey)
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────
local function logCachedSpells(stage)
    if not cfg_debugMode then return end
    local ids = {}
    for spellId in pairs(cachedKnownSpells) do ids[#ids + 1] = spellId end
    debugLogf('%s: cached %d castable spells: [%s]', stage, #ids, table.concat(ids, ', '))
end

local function onSave()
    restoreShieldAfterCast()
    return {
        nextCastAllowedTime = nextCastAllowedTime,
        lastNonSpellStance = lastNonSpellStance,
        cachedKnownSpells = cachedKnownSpells,
        spellsTemporarilyRemoved = spellsTemporarilyRemoved,
        rolledAnims = rolledAnims,
    }
end

local function onLoad(data)
    refreshSettings()
    if IS_SPELL_VENDOR then
        -- Older saves may contain OSSC state from before vendor exclusion was
        -- added: restore those spells, but do not otherwise touch the vendor.
        if data then
            cachedKnownSpells = data.cachedKnownSpells or {}
            spellsTemporarilyRemoved = data.spellsTemporarilyRemoved or false
        end
        restoreAllCastableSpells()
        return
    end
    resetAfterActivation('onLoad')
    if data then
        nextCastAllowedTime = data.nextCastAllowedTime or 0
        lastNonSpellStance = data.lastNonSpellStance or STANCE.Weapon
        cachedKnownSpells = data.cachedKnownSpells or {}
        spellsTemporarilyRemoved = data.spellsTemporarilyRemoved or false
        rolledAnims = data.rolledAnims
    end
    -- Keep the animation set rolled before the save; only roll a fresh one
    -- for saves made by an older OSSC version that never stored it.
    if not rolledAnims then rollAnimSet() end
    if not isActorEligible() then return end
    removeAllCastableSpells()
    logCachedSpells('onLoad')
end

local function onActive()
    if IS_SPELL_VENDOR then
        restoreAllCastableSpells()
        return
    end
    if not isActorEligible() then return end
    refreshSettings()
    resetAfterActivation('onActive')
    if not rolledAnims then rollAnimSet() end -- rolled at attach, kept while attached
    removeAllCastableSpells()
    logCachedSpells('onActive')
end

local function onInit()
    if not isActorEligible() then return end
    refreshSettings()
    scanFollowPackage()
    resetAfterActivation('onInit')
    -- Fresh script instance = fresh attach: roll this entity's personal cast
    -- animation set.
    rollAnimSet()
    removeAllCastableSpells()
    logCachedSpells('onInit')
end

-- ── Safe detach ────────────────────────────────────────────────────────────
-- The cast timers cannot be cancelled, so wait (re-arming) until the newest
-- timer has certainly drained and no cast is running, and only then tell the
-- global script it is safe to detach.
local readyToDetachEvent = { actor = self, script = SCRIPT_PATH }

local function detachAckTick()
    -- Combat resumed before we were removed: stop waiting entirely.
    -- (An external pause does not own the detach: it must still complete.)
    if not Pause.detachPending then return end
    -- A dead actor can never start a new cast; release any stale lock so the
    -- ack is still sent after the last pending timer drains.
    if isCasting and types.Actor.isDead(self) then cleanupCast('dead') end
    if isCasting or core.getSimulationTime() < pendingTimersUntil then
        async:newUnsavableSimulationTimer(0.25, detachAckTick)
        return
    end
    -- The gate stays on: no new cast may start until the global script
    -- has actually removed this script (or combat resumes).
    debugLog('All cast timers drained — reporting safe to detach')
    core.sendGlobalEvent('OSSC_ReadyToDetach', readyToDetachEvent)
end

local function armDetachAck()
    Pause.detachPending = true
    Pause.refresh()
    async:newUnsavableSimulationTimer(math.max(0.05, pendingTimersUntil - core.getSimulationTime() + 0.05), detachAckTick)
end

-- Sent by the global attachment manager immediately before detaching the
-- script: restore the spells hidden from the vanilla AI, stop any in-flight
-- cast and ack once the unsavable cast timers have drained.
local function onCombatEnded()
    restoreAllCastableSpells()
    if isCasting then cleanupCast('combat ended') end
    resetAfterActivation('combat ended')
    armDetachAck()
end

-- Sent by the global script when combat resumes and the pending detach is
-- cancelled: go back to normal quickcasting.
local function onCombatResumed()
    Pause.detachPending = false
    -- An external pause, if any, keeps its own hold on the gate.
    Pause.refresh()
end

refreshSettings()
debugLog('Script loaded for actor')

return {
    -- Other local scripts on this actor can pause/resume its spellcasting
    -- through `I.OSSC_Caster`; global scripts use I.OSSC_Casters (ossc_global)
    -- or send OSSC_SetCasterPaused to the actor.  The interface only exists
    -- while this script is attached - check hasScript(scriptPath) - because
    -- OSSC detaches out of combat.
    interfaceName = 'OSSC_Caster',
    interface = {
        version     = 1,
        isPaused    = function() return next(Pause.reasons) ~= nil end,
        isCasting   = function() return isCasting end,
        isSuspended = function() return Pause.suspended end,
        -- `unpause()` with no reason releases every pause; `unpause('scene')`
        -- releases only that one, so a mod cannot resume an actor another mod
        -- is still holding.
        pause   = function(reason) return Pause.set(true, reason) end,
        unpause = function(reason) return Pause.set(false, reason) end,

        -- Settings read-out for same-actor scripts: the distance (game units)
        -- at or below which this actor's quick-cast probability is at its
        -- maximum — the "100% chance distance" of the NPC settings
        -- (NPCQuickCastMinDistance, default 500).  This is the live value
        -- castChance() rolls against, refreshed from the settings mirror
        -- once a second, so it tracks menu changes without a reload.
        getQuickCastFullChanceDistance = function() return cfg_minDist end,

        -- Every NPC/creature quick-cast setting (the SettingsOSSC_NPC group)
        -- as a live snapshot table — the same read-out as
        -- I.OSSC_Casters.getNPCSettings(), from this actor script's view of
        -- the settings mirror. Unset keys answer with their registered
        -- defaults; the result is a fresh copy, safe to keep or mutate.
        -- (The shared schema module is required inline — this main chunk is
        -- at Lua's 200-local limit and cannot spare a top-level local.)
        getNPCSettings = function()
            return require('scripts.ossc.ossc_caster_utils').readNPCSettings(npcSettings)
        end,

        -- ── On-demand cast + spell filter (see OSSCExternal above) ─────────
        -- `castSpellAtTarget{ spellId = 'x', target = actorOrPosition }`
        -- launches the spell through Spell Framework Plus without playing the
        -- quick-cast animation; `isSpellIgnored` / `setSpellIgnored` mirror
        -- the global list (I.OSSC_Casters owns it, this actor applies it).
        castSpellAtTarget = function(args) return OSSCExternal.castSpellAtTarget(args) end,
        isSpellIgnored    = function(spellId) return OSSCExternal.isIgnored(spellId) end,
        setSpellIgnored   = function(spellId, ignored) return OSSCExternal.setIgnored(spellId, ignored) end,
        ignoreSpell       = function(spellId) return OSSCExternal.setIgnored(spellId, true) end,
        unignoreSpell     = function(spellId) return OSSCExternal.setIgnored(spellId, false) end,
    },
    engineHandlers = {
        onActive = onActive,
        onInit = onInit,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    },
    eventHandlers = {
        OSSC_CombatEnded = onCombatEnded,
        OSSC_CombatResumed = onCombatResumed,
        -- Spell filter pushed by the global script: on every change, and as
        -- the answer to the request this script sends from OSSCExternal.
        OSSC_SetIgnoredSpells = function(data)
            if type(data) ~= 'table' then return end
            OSSCExternal.setIgnoredList(data.ids)
        end,
        -- Pause/unpause request (same-actor interface, global route, or any
        -- mod sending it directly).  See Pause.set above.
        OSSC_SetCasterPaused = function(data)
            if type(data) ~= 'table' then return end
            Pause.set(data.paused == true, data.reason)
        end,
        -- Follow state is event-driven. Adding or dropping a Follow package is
        -- an explicit transition, so re-scan then and only then - which is what
        -- keeps onUpdate off the package stack.
        StartAIPackage = function(pkg)
            -- The engine passes the package itself, so read the leader straight
            -- off it. Falling back to a scan for a bare type name keeps the
            -- handler usable either way.
            if isFollowPackage(pkg) then
                followTargetKey = actorKey(pkg.target)
            elseif pkg == 'Follow' then
                scanFollowPackage()
            end
        end,
        RemoveAIPackage = function(pkg)
            if isFollowPackage(pkg) or pkg == 'Follow' then
                followTargetKey = nil
            end
        end,
    },
}
