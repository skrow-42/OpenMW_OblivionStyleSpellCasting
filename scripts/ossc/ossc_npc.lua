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
-- Friendlier Fire gate: SFP quick-casts bypass FF's sweep, so OSSC checks itself.
local friendlyFire = require('scripts.ossc.ossc_friendlyfire')
local Penalty = require('scripts.ossc.ossc_penalty')
-- Per-animation launch offsets (user-editable data file).
local launchOffsets = require('scripts.ossc.ossc_launch_offsets')
-- Moving-target lead for target-range quick-casts: a Lua clone of the OpenMW
-- engine's AI spell leading (mwmechanics/aicombat.cpp AimDirToMovingTarget).
-- OSSC's own launcher aims at the target's CURRENT position, which dropped
-- the leading the engine's AiCombat used to apply; this restores it. Feeds on
-- combat-target position samples taken in onUpdate and is consulted at the
-- fire moment. Nothing inside reads the stance, so leading behaves the same
-- whatever stance the actor is in when the cast starts.
local targetLead = require('scripts.ossc.ossc_target_lead')
-- Rules shared with the player script (touch reach, cast animation blending):
-- every OSSC caster — player, NPC, creature — applies the same ones.
local castRules = require('scripts.ossc.ossc_cast_rules')
-- Where an impact's hit statics are drawn (OSSC owns the placement).
local impactVfx = require('scripts.ossc.ossc_impact_vfx')
-- Shared spell classification (the sure-cast rule, castable-spell rule and
-- the SettingsOSSC_NPC schema); see scripts/ossc/ossc_caster_utils.lua.
local casterUtils = require('scripts.ossc.ossc_caster_utils')
-- Real engine spellcast detection: only the nine vanilla spellcast Start /
-- Release / Stop text keys should block actor quick-casts. See the module
-- header for why anim.isPlaying('spellcast') is too broad.
local vanillaSpellcast = require('scripts.ossc.ossc_vanilla_spellcast')
-- Mercy CAO (Combat AI Overhaul, Max Yari) bridge: a second AI driver on this
-- very actor. Required from a LOCAL script on purpose — I.MercyCAO is a local
-- interface, so the `openmw.interfaces` this module captures is this actor's.
-- See the header of that file for why OSSC has to stand down from the draw
-- state and the attack input instead of fighting Mercy for them.
local mercy = require('scripts.ossc.ossc_mercy')

local STANCE     = types.Actor.STANCE
local SLOT       = types.Actor.EQUIPMENT_SLOT
local RANGE      = core.magic.RANGE
local SPELL_TYPE = core.magic.SPELL_TYPE
local spellRecords  = core.magic.spells.records
local effectRecords = core.magic.effects.records

-- ── Settings + cast state live in tables, not in plain file-scope locals ───
-- A Lua chunk is compiled as ONE function and Lua refuses more than 200 active
-- local variables in a function ("main function has more than 200 local
-- variables" — a script over that limit never loads at all), so shared state is
-- grouped into a handful of tables. The OSSC player script documents the same
-- rule for the other limit these tables keep us clear of: LuaJIT allows a
-- function at most 60 upvalues, and every file-scope local a function
-- references costs it one, which the big handlers (onUpdate especially) nearly
-- reach on their own. Please add new shared state as a field of one of these
-- tables rather than as a new `local`.
local Cfg = {
    general      = storage.globalSection('SettingsOSSC_General'),
    npc          = storage.globalSection('SettingsOSSC_NPC'),
    -- NPC Spell Decision AI group (mirrored into global storage by
    -- ossc_settings.lua; refreshSettings keeps the cached fields in sync).
    -- The decision settings now live in the NPC & Creature Quick-Casting group.
    -- Same section as `npc` on purpose: one group, one read. The NPCAI* keys
    -- keep their names, so saves and the mirror need no migration.
    ai           = storage.globalSection('SettingsOSSC_NPC'),
    anim         = storage.globalSection('SettingsOSSC_Animations'),
    animSpeed    = storage.globalSection('SettingsOSSC_AnimSpeeds'),
    -- The player's VFX toggles, mirrored into global storage by ossc_settings.lua
    -- (actor scripts cannot read player storage).
    keys         = storage.globalSection('SettingsOSSC_Keys'),
    -- Fallback values mirror the registered settings-menu defaults exactly;
    -- refreshSettings() (below) keeps them in sync while the script is attached.
    debugMode    = false,
    enabled      = true,
    pollInterval = 1.0,
    minDist      = 500,
    maxDist      = 700,
    baseChance   = 1.00,
    cooldownMin  = 3.5,
    cooldownMax  = 8.5,
    allowPowers  = false,
    randomAnims  = true,
    -- NPC Spell Decision AI (refreshed with the rest below):
    trace             = false,
    magickaReservePct = 25,
    -- Unified heal threshold (% of health): Self-heal priority, follower heal
    -- and the LowHealth reaction all read this one value.
    healThresholdPct  = 40,
    -- Combo casting is always a strict Weakness → matching damage sequence
    -- (there is no setting any more). Weakness minimum magnitude must meet
    -- this inclusive percentage.
    weaknessMinMagnitude = 15,
    -- NPCAIReactions: 'Off' | 'LowHealth' | 'Broad'. Read in refreshSettings;
    -- 'Off' keeps the actor purely offensive.
    reactions         = 'LowHealth',
    beneficialBuffMinDuration = 15,
    -- Same-buff recast lockout (NPCAIBuffRecastCooldown, seconds): after an
    -- NPC/creature quick-casts a buff (on itself or its leader), that exact
    -- spell stays out of its buff picks for this long, on top of the
    -- still-active no-recast rule. 0 disables the lockout.
    buffRecastCooldown = 30,
    declinedRaw       = nil,
    declinedSpells    = {},
    -- Tactical spell selection (NPC settings group, refreshed with the rest).
    -- Touch/Target weights apply only after heals and missing Self buffs.
    tactics = {
        touchChance       = 60,  -- in touch reach: Touch spell
        touchTargetChance = 10,  -- in touch reach: Target spell
    },
    -- Self Restore Fatigue spells are maintenance, not buffs: they are only
    -- considered while the actor's fatigue is strictly below this percentage.
    -- Fixed policy, not a menu setting.
    restoreFatigueThreshold = 50,
    -- Mercy CAO compatibility is fixed to Cooperate: OSSC casts the actor's
    -- own spells while yielding body writes whenever Mercy is driving it.
    mercyDriving = false,
    -- Seconds a vanilla cast queued under a Mercy pause stays protected
    -- after Mercy releases the pause (NPCMercyVanillaCastWindow setting,
    -- refreshed in refreshSettings; 0 disables the protection).
    mercyVanillaCastWindow = 5.0,
    -- Mercy CAO quick-cast windows: while Mercy uses Spell stance as a
    -- posture, OSSC may borrow the body for one blended quick-cast. Refreshed
    -- from NPCMercyQuickcastWindow / NPCMercyQuickcastWindowCooldown.
    mercyQuickcastWindow = true,
    mercyWindowCooldown = 2.0,
    -- Safety bounds for a window; not user-facing. Each stage gets its own
    -- short deadline so a window where no spell is chosen cannot keep Mercy
    -- yielded; once a cast starts the deadline follows its own cast deadline.
    mercyWindowPrepareTimeout = 0.35,
    mercyWindowArmedTimeout = 0.35,
    -- Seconds a vanilla cast queued while a mod had this caster paused
    -- stays protected after the pause is released — Mercy CAO included
    -- (NPCPauseResumeGrace setting, refreshed in refreshSettings; 0
    -- disables the protection and re-strips the spells on resume at once).
    pauseResumeGrace = 5.0,
    -- Vanilla-cast allowance (NPCVanillaCastsAllowedMin/Max): how many engine
    -- (vanilla) casts the actor may finish after another mod hands the spell
    -- list back, before OSSC strips it again and resumes quick-casts. The count
    -- is rolled per hand-back, so equal min/max pins the rate and min < max
    -- varies it. Both 0 disables the allowance entirely.
    -- vanillaCastAllowanceTimeout (NPCVanillaCastAllowanceTimeout) bounds each
    -- of those casts; 0 waits indefinitely for the engine.
    vanillaCastsAllowedMin = 1,
    vanillaCastsAllowedMax = 2,
    vanillaCastAllowanceTimeout = 6.0,
    -- Seconds an untouched allowance waits for the engine to even READY magic
    -- (enter Spell stance). Mercy CAO pauses and releases OSSC around every one
    -- of its own routines, so without this the budget was re-armed every couple
    -- of seconds and OSSC never quick-cast again. 0 waits the full timeout.
    vanillaCastAllowanceReadiness = 1.5,
    -- A quick-cast ALWAYS out-ranks weapon attacks (no setting any more): it
    -- plays above PRIORITY.Weapon so an attack animation running at the same
    -- time (Mercy CAO's swings, the engine AI's own swing) cannot out-rank the
    -- cast on the arms.
    -- NPCQuickCastEquipReadiness: seconds the FIRST quick-cast waits after OSSC
    -- itself puts the actor into Weapon stance (taking the body back from
    -- Mercy, or taking over a bare Spell posture). That stance flip is what
    -- makes the engine draw the weapon, and casting over the draw is what the
    -- user saw: the act of taking control back instantly quick-cast while the
    -- weapon was still coming out. 0 disables the wait.
    equipReadiness = 0.75,
    -- NPCProjectilesPassThroughBystanders: a Target quick-cast flies THROUGH
    -- actors that are not its target (vanilla parity) instead of being eaten by
    -- whoever stands in the line of fire. On = those actors are handed to the
    -- Spell Framework Plus launch as per-cast target exclusions and are
    -- transparent to the visibility check. Off = physics decides: the first
    -- living actor the bolt meets takes the spell.
    projectilesPassThroughBystanders = true,
    logPrefix    = '[OSSC-NPC ' .. tostring(self.recordId) .. '] ',
    -- Gameplay-group settings the actor casts honour for player parity — the MCP
    -- fatigue usage and the quick-cast chance penalty — plus the cost/chance
    -- formulas themselves (see the Cfg.costs block below getQuickCastEffectScale).
    costs = {
        useFatigue    = true,
        fatigueScale  = 5.0,
        chancePenalty = 'off',
    },
}

-- ── Cast state, animation data, combat data, geometry, spell pools ─────────
-- The same table-for-state rule as Cfg, declared up here because the section
-- headers below fill them in and the chunk already writes fields while loading.
local Cast = {
    -- Shield VFX played while the real one is unequipped for a cast.
    shieldGhostVfxId = 'OSSC_ShieldGhost',
    -- Same-buff recast lockout: lowercased spell id -> simulation time of
    -- this actor's last quick-cast of that buff (Self or ally). Persisted
    -- in onSave/onLoad alongside the other cast clocks.
    buffLastCastAt   = {},
    -- NPC Spell Decision AI derived state (Tactics.refreshDerived rebuilds
    -- the derived flags whenever knownSpells grows; the dirty bit is set by
    -- cacheCastableSpells, the underwater grant and save-load restore).
    knownSpellsDirty = true,
    sustainCaster    = false,
    wbKnown          = false,
    wbValidated      = false,
    wbExhausted      = false,
    lastTraceKey     = nil,
    -- Strict combo sequence, armed when a qualifying Weakness setup is
    -- committed and cleared by its matching damage follow-up, target change,
    -- expiry, settings disable, or a lifecycle reset. The tag table is reused.
    comboTargetKey   = nil,
    comboTags        = {},
    comboUntil       = 0.0,
}
-- Animation data: the school/range → group tables, the per-actor rolled sets
-- and the timings that shape a cast (see the sections below).
local Anim = {}
-- Animation groups and weapon classes the cast gates consult. The reusable
-- target lists live here too: this chunk is close to Lua's 200-local limit.
local Combat = {
    targets        = {},
    targetKeys     = {},
    visibleTargets = {},
}
-- Unit vectors a third-person launch is built from, and the aim offsets.
local Vec = {
    FORWARD = util.vector3(0, 1, 0),
    LEFT    = util.vector3(-1, 0, 0),
    UP      = util.vector3(0, 0, 1),
    TARGET_AIM_OFFSET = util.vector3(0, 0, 70),
    LOS_TARGET_OFFSET = util.vector3(0, 0, 60),
}
-- The tactical pools categorizeSpells() fills and selectTacticalSpell() picks
-- from. The priority-damage pools are subsets of the ordinary range pools:
-- Damage Health, Fire/Frost/Shock Damage and Poison must win over utility
-- damage such as Damage Attribute whenever at least one is currently legal.
local Spells = {
    heal = {}, buff = {}, touch = {}, target = {},
    priorityTouch = {}, priorityTarget = {},
    -- Strict combo setup candidates never enter the ordinary offense pools.
    comboTouch = {}, comboTarget = {},
    -- Reused filters for range-aware setup pairing and the locked follow-up.
    comboPickTouch = {}, comboPickTarget = {},
    damageTagsTouch = {}, damageTagsTarget = {},
}

local function settingOr(section, key, default)
    local value = section:get(key)
    if value == nil then return default end
    return value
end

--- A REAL engine vanilla cast opens a cycle on any of the nine vanilla
--- spellcast Start / Release / Stop text keys. `anim.isPlaying(self,
--- 'spellcast')` also reports equip, unequip and idle-posture animations from
--- the same group, and a selected castable stays sticky after
--- ActionSpell::prepare(); neither is proof of a cast. The shared module owns
--- the key list, the SpellCast Unequip Stop handshake and the fallback
--- timeout.
function Combat.noteVanillaSpellcastKey(groupname, key)
    -- Quick-cast mode: the spells are stripped, so the engine cannot be casting
    -- and the key is not a hand-back. Ignoring it keeps OSSC casting instead of
    -- being pushed back into vanilla mode by every animation key.
    if Combat.osscOwnsSpellList() then
        if Cfg.debugMode
            and vanillaSpellcast.keyKind(groupname, key) ~= nil then
            print(Cfg.logPrefix .. string.format(
                'Vanilla spellcast key ignored: %s — OSSC owns the spell list, '
                .. 'quick-casts only', tostring(key)))
        end
        return nil
    end
    local now = core.getSimulationTime()
    local kind, newCycle = vanillaSpellcast.noteKey(Cast, groupname, key, now,
        vanillaSpellcast.KEY_HOLD)
    if kind and Cfg.debugMode then
        -- Defined before debugLogf() below; use print directly so this early
        -- helper has no forward dependency.
        print(Cfg.logPrefix .. string.format(
            'Vanilla spellcast key: %s (%s, cycle=%s, newCycle=%s, wait=%.2fs)',
            tostring(key), kind,
            tostring(vanillaSpellcast.cyclePending(Cast)), tostring(newCycle),
            vanillaSpellcast.remaining(Cast, now, Cfg.vanillaCastUnequipTimeout)))
    end
    return kind, newCycle
end

--- THE mode switch of the whole cooperation.
---
--- The actor's castable spells have exactly one owner at a time, and the strip
--- state is what says which:
---
---  * OSSC owns them (`Cast.spellsTemporarilyRemoved`) — ONLY quick-casts.
---    The engine has nothing to cast from, so a spellcast text key here is a
---    leftover of a cast OSSC already ended (or an animation-only fake) and
---    must never hand the list back or hold a quick-cast.
---  * the engine owns them — vanilla casting only. OSSC does not quick-cast,
---    does not strip, does not clear the selected castable and does not take
---    the stance back. The phase ends when the vanilla cast cycle finishes, or
---    when the readiness grace says the engine is not going to use the list.
function Combat.osscOwnsSpellList()
    return Cast.spellsTemporarilyRemoved == true
end

function Combat.vanillaCastGestureActive()
    return vanillaSpellcast.active(Cast, core.getSimulationTime(),
        Cfg.vanillaCastUnequipTimeout)
end

--- Kept as the single call used by every stand-down / window gate. A key hold
--- left over from a cast OSSC already ended must not silence quick-casts once
--- OSSC owns the spell list again.
function Combat.realVanillaSpellcastActive()
    if Combat.osscOwnsSpellList() then return false end
    return Combat.vanillaCastGestureActive()
end

--- The engine's ordinary magic stance. While a REAL vanilla cast cycle is
--- pending the engine owns the selected castable, spell list and gesture, so
--- OSSC stands down.
---
--- A bare Spell stance is NEVER taken over (user directive: "Take Over Bare
--- Spell Stance" is permanently off, the setting is gone). Spell stance is the
--- engine's own posture — Mercy's warning stance, a waiting spellcaster, the
--- AI idling after a cast — and the actor keeps it: OSSC starts no quick-cast,
--- writes no stance and does not strip the spell list from under it.
function Combat.vanillaSpellStanceActive()
    local stance = types.Actor.getStance(self)
    if stance ~= STANCE.Spell then
        Cast.spellStanceSince = 0.0
        return false
    end
    -- During an OSSC window the stance is being swapped to Weapon. If it is
    -- still Spell for a frame, OSSC owns it, not the engine.
    if Cast.mercyWindowActive then return false end
    -- Quick-cast mode: the spells are stripped, so the engine has nothing to
    -- cast and this stance is a stale posture. Take it over at once (no
    -- takeover delay) and quick-cast. Vanilla casting only exists while the
    -- actor actually holds the spells.
    if Combat.osscOwnsSpellList() then
        Cast.spellStanceSince = 0.0
        return false
    end
    if Combat.realVanillaSpellcastActive() then
        Cast.spellStanceSince = 0.0
        return true
    end
    -- Vanilla-cast allowance: the engine was handed its spell list back and
    -- owes this actor vanilla casts. Its Spell stance is the cast it readied
    -- from that list — never take it over, never strip it.
    if Combat.vanillaCastAllowanceActive() then
        Cast.spellStanceSince = 0.0
        return true
    end
    -- A bare Spell posture is protected unconditionally: OSSC never takes it
    -- over. Only the diagnostic age of the stance is kept (debug heartbeat's
    -- `bareFor`), so a field log can still show how long the engine has been
    -- sitting in it.
    if Cast.spellStanceSince == 0.0 then
        Cast.spellStanceSince = core.getSimulationTime()
    end
    return true
end

-- ── Sure casts ─────────────────────────────────────────────────────────────
-- Abilities (SPELL_TYPE.Ability), lesser/greater powers (SPELL_TYPE.Power)
-- and "Always Succeeds" spells (alwaysSucceedFlag) are sure casts: vanilla
-- never rolls to see whether one of these goes off — it simply lands — so
-- the Quick Cast Chance Penalty must never roll one either. The Quick Cast
-- Effect Penalty keeps its own, separate rule: Powers — and Powers alone —
-- never pay it (effectPenaltyExempt below). The UseFatigue fatigue cost and
-- the Shield Casting Penalty slowdown apply to every cast. Enchanted-item
-- casts are never sure casts (an enchantment record's `type` is an
-- EnchantmentType whose numbers overlap SpellType's — never read it as a
-- spell type). Data-driven so the decision matches the player script.
local function isSureCastSpell(spell)
    if not spell then return false end
    if spell.item or spell.enchantment then return false end
    if casterUtils.isSureCastRecord(spell) then return true end
    local rec = spell.id and spellRecords[spell.id] or nil
    return casterUtils.isSureCastRecord(rec)
end

-- Powers never pay the Quick Cast Effect Penalty (unconditional — a Power
-- burning its once-a-day use must land at full strength). Abilities and
-- "Always Succeeds" spells are NOT covered: their only exemption is the
-- chance penalty (isSureCastSpell above). The scroll exclusion
-- (QuickCastEffectPenaltyScrollsExempt) covers scrolls alone, and those are
-- cast through scripts/ossc/ossc_actor_items.lua, which honours the toggle
-- itself — every spell that reaches this path is a regular spell from the
-- actor's spell list and is penalised unless it is a power. An enchanted
-- item's records are never read as SPELL records (the `type` numbers
-- overlap).
local function effectPenaltyExempt(spell)
    if not spell then return false end
    if spell.item or spell.enchantment then return false end
    if spell.type == SPELL_TYPE.Power then return true end
    local rec = spell.id and spellRecords[spell.id] or nil
    return rec ~= nil and rec.type == SPELL_TYPE.Power
end

-- ── Debug logging ──────────────────────────────────────────────────────────
local function parseDebugMode(value)
    if value == true then return true end
    if value == false or value == nil then return false end
    if type(value) == 'number' then return value ~= 0 end
    local text = tostring(value):lower():match('^%s*(.-)%s*$')
    return text == 'true' or text == 'yes' or text == 'enabled' or text == 'on' or text == '1'
end

local function refreshDebugMode()
    Cfg.debugMode = parseDebugMode(Cfg.npc:get('NPCQuickCastDebugLog'))
end

local function debugLog(msg)
    if not Cfg.debugMode then return end
    print(Cfg.logPrefix .. tostring(msg))
end

local function debugLogf(fmt, ...)
    if not Cfg.debugMode then return end
    print(Cfg.logPrefix .. fmt:format(...))
end

--- One diagnostic line per second for the otherwise silent onUpdate gates.
--- The user-side symptom "NPC never quick-casts" can come from range, pause,
--- poll timing, an empty spell cache or follow protection; without this the
--- heartbeat only proves that onUpdate is running.
local function debugGate(now, fmt, ...)
    if not Cfg.debugMode or now < Cast.nextGateLog then return end
    Cast.nextGateLog = now + 1.0
    debugLogf('CAST GATE | ' .. fmt, ...)
end

-- ── Cast state ─────────────────────────────────────────────────────────────
-- Everything the cast paths share, in Cast (declared with Cfg above); the
-- fields below are its initial values.
Cast.isCasting                = false
Cast.hasFiredThisCast         = false
-- Cast id whose school cast sound has already been played: startQuickcast()
-- plays it immediately (heard even when a skeleton's animation carries no
-- 'start' text key) and the 'start' text key must not play it a second time.
Cast.castSoundPlayedForCastId = nil
Cast.currentSpell             = nil
Cast.currentAnimGroup         = nil
Cast.currentRange             = RANGE.Target
Cast.currentCastId            = 0
-- Timer callbacks capture Cast.currentCastId when armed, so a stale timer
-- cannot act on a newer cast.
Cast.nextActionTime           = 0.0
Cast.nextCastAllowedTime      = 0.0
-- Self buffs have their OWN clock: buffing is exempt from the random
-- NPCQuickCastCooldownMin/Max cooldown and spaces itself flat instead.
Cast.nextBuffAllowedTime      = 0.0
Cast.lastNonSpellStance       = STANCE.Weapon
Cast.knownSpells              = {}
-- Invisible-and-seen hold (see Combat.updateHidden): the player's line of
-- sight is re-tested a few times a second, `hiddenHold` is the state the cast
-- gate reads and `hiddenHoldYielding` records that Mercy's attack trees are
-- switched off for it.
Cast.hiddenSeen               = false
Cast.nextHiddenCheck          = 0.0
Cast.hiddenHold               = false
Cast.hiddenHoldYielding       = false
-- What the hold is hiding from (the player, see Combat.threatActor) and when
-- the engine-driven retreat may be re-issued (Combat.retreatFrom).
Cast.hiddenThreat             = nil
Cast.nextRetreatAt            = 0.0
-- Reactions (NPCAIReactions): the last incoming hit (Broad) and the cooldown
-- that keeps an escape spell from being recast every poll.
Cast.lastIncomingHitAt        = nil
Cast.nextReactionAt           = 0.0
Cast.spellsTemporarilyRemoved = false
Cast.hasActiveVfx             = false
Cast.inCombat                 = false
Cast.isBound2HWeaponCast      = false
Cast.suppressedShield         = nil   -- shield item unequipped during cast
Cast.shieldGhostVfxActive     = false -- the ghost VFX was actually spawned

-- Cell re-entry guard. The engine can restore STANCE.Spell/SelectedSpell after
-- onActive/onLoad, so suppress that transient state without adding permanent
-- per-frame work after the actor has settled back into the cell.
Anim.reentryGuardDuration = 1.0
Cast.reentryGuardUntil    = 0.0

-- Fixed spacing between Self-buff quick-casts. Buffing has no cooldown: the
-- random NPCQuickCastCooldownMin/Max setting never applies to it, so a full
-- buff routine runs on a flat 2.2 s rhythm (the natural cast cycle: ~1.2 s
-- cast + up to 1 s of combat polling) instead of 3.5–8.5 s of random wait.
Anim.buffSpacing = 2.2

-- ── Safe detach support ────────────────────────────────────────────────────
-- ossc_global.lua removes this script when combat ends. Unsaved timers keep a
-- reference to functions inside this script, so it must not be removed while
-- a cast timer can still fire (a removed script's callbacks fail with
-- "callTimer failed"). The script tracks when its newest timer drains
-- (Cast.pendingTimersUntil) and only reports "ready to detach" once it is idle.
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
-- One table rather than a handful of locals, for the same reason as every
-- other table at the top of this file; `pendingTimersUntil` lives in Cast
-- because it is cast state, while the pause gate is its own table because the
-- global detach manager reads and writes it as a unit.
Cast.pendingTimersUntil = 0.0
-- Mercy CAO bridge state (see scripts/ossc/ossc_mercy.lua):
--   mercyCast      - this cast started while Mercy was driving, so Mercy keeps
--                    the body for its whole duration even if it stops driving
--                    mid-cast (it must not be handed back and forth mid-swing)
--   mercyHoldSince - simulation time Mercy's pause reasons were last seen while
--                    Mercy was NOT driving; 0 while it still drives
Cast.mercyCast      = false
Cast.mercyHoldSince = 0.0
--   mercyPauseDeferred - a Mercy hold that arrived while an OSSC quick-cast
--                    was still on screen. Mercy waits for the gesture to
--                    finish; the request is applied in cleanupCast.
Cast.mercyPauseDeferred = nil
--   mercyWindow* - one short OSSC-owned quick-cast window negotiated with
--                  Mercy (idle/prepare/armed/casting). Session state only.
Cast.mercyWindowActive        = false
Cast.mercyWindowStage         = 'idle'
Cast.mercyWindowSnapshot      = nil
Cast.mercyWindowSavedStance   = nil
Cast.mercyWindowStartedAt     = 0.0
Cast.mercyWindowUntil         = 0.0
Cast.mercyWindowCooldownUntil = 0.0
--   equipReadyUntil - the first quick-cast after OSSC put this actor into
--                    Weapon stance waits until then: the stance flip starts a
--                    weapon DRAW and the cast must not blend over it
--                    (NPCQuickCastEquipReadiness, 0 = no wait).
Cast.equipReadyUntil          = 0.0
--   equipArmed - the wait above already armed for the takeover in progress;
--                cleared as soon as the actor is seen in Weapon stance again.
Cast.equipArmed               = false
--   mercyWindowLocal - true when the window is OSSC's own takeover of a bare
--                      vanilla Spell posture and no Mercy yield was needed.
--   mercyWindowRestoreStance - restore the saved Spell posture on close.
--   spellStanceSince - first frame of a Spell stance with no real cast.
--   vanillaSpellcast* / vanillaCastCycle* - the real vanilla cast cycle:
--                    nine Start/Release/Stop keys restore the engine spell
--                    list and hold quick-casts; SpellCast Unequip Stop (or
--                    the configured timeout) strips them again and re-arms.
Cast.mercyWindowLocal         = false
Cast.mercyWindowRestoreStance = false
Cast.spellStanceSince         = 0.0
Cast.vanillaSpellcastUntil    = 0.0
Cast.vanillaSpellcastLastKey  = nil
Cast.awaitVanillaUnequipStop = false
Cast.vanillaCastCycleStartedAt = 0.0
Cast.vanillaCastCycleStartKey  = nil
Cast.vanillaCastCycleEndKey    = nil
Cast.vanillaCastTimedOut       = false
--   vanillaCastsLeft / vanillaCastsDone / vanillaCastAllowanceUntil /
--     vanillaCastAllowanceArmed - the vanilla-cast allowance. Handing the
--     engine its spell list back (a mod pause) is not enough for it to cast:
--     OSSC would re-strip the list on the first update after the release and
--     kill the cast it just made possible. After a release the engine may
--     therefore COMPLETE this many vanilla casts (rolled from
--     NPCVanillaCastsAllowedMin/Max on every hand-back) before OSSC takes the
--     list back; NPCVanillaCastAllowanceTimeout bounds each of them so an
--     actor that never presses the key cannot silence OSSC.
Cast.vanillaCastsLeft          = 0
Cast.vanillaCastsRolled        = 0
Cast.vanillaCastsDone          = 0
Cast.vanillaCastAllowanceUntil = 0.0
Cast.vanillaCastAllowanceArmed = false
--   vanillaCastSpellIds / vanillaCastEnsureAt - the exact castables the engine
--     is entitled to for the current window, and when it was last checked that
--     they are really on the actor. The window is not merely "OSSC does not
--     strip": the spells are actively handed back (added) when it opens and
--     re-added if anything removes them while it lasts. Without that an actor
--     whose list was stripped before the hand-back (or cleared by another mod
--     mid-window) stands in a vanilla window with nothing to cast.
Cast.vanillaCastSpellIds       = nil
Cast.vanillaCastEnsureAt       = 0.0
--   vanillaCastAllowanceArmedAt / vanillaCastAllowanceSawSpellStance - when the
--     current budget was handed over, and whether the engine has readied magic
--     (entered Spell stance) since. The engine has to select a spell before it
--     can cast one, so a budget it never readies anything for is dead weight:
--     it used to be re-armed on every Mercy pause release and silenced OSSC
--     for the whole fight even though Mercy was not driving.
Cast.vanillaCastAllowanceArmedAt        = 0.0
Cast.vanillaCastAllowanceSawSpellStance = false
--   mercyVanillaCastUntil - while simulation time is before this, a vanilla
--                    (engine) cast Mercy queued while it had OSSC paused is
--                    being protected: OSSC neither re-strips the spells nor
--                    takes Spell stance back (see Pause.set / onUpdate)
Cast.mercyVanillaCastUntil = 0.0
--   externalPauseGraceUntil - the universal resume grace: the same
--                    protection as the Mercy window for EVERY pause release
--                    through the interface (I.OSSC_Caster /
--                    OSSC_SetCasterPaused), Mercy's reasons included, and
--                    for a stranded Mercy hold OSSC drops itself. When the
--                    pause lifts while the actor stands in Spell stance, a
--                    vanilla cast was readied under it and would be killed
--                    the instant OSSC re-strips the list. Armed from
--                    Pause.set and releaseStaleMercyHold, using the
--                    NPCPauseResumeGrace setting; 0 disables it.
Cast.externalPauseGraceUntil = 0.0
local Pause = {
    detachPending = false,   -- the global script asked for a detach
    reasons       = {},      -- [reason] = true, one entry per requesting mod
    suspended     = false,   -- gate every cast path reads
}

function Pause.refresh()
    Pause.suspended = Pause.detachPending or next(Pause.reasons) ~= nil
end

-- ── Mercy CAO ──────────────────────────────────────────────────────────────
-- Mercy: Combat AI Overhaul (Max Yari) is a second AI driver on this very
-- actor. Its ImprovedAI.lua is a local script that writes the draw state
-- (selfActor:setStance) and the attack input (controls.use) every frame from
-- its own onUpdate, so OSSC's "I own the body" writes overwrite Mercy's — or
-- are overwritten by it, and which one survives is decided by the content-file
-- order, not by anything either mod can do (see the header of
-- scripts/ossc/ossc_mercy.lua). Every gate below is therefore a stand-down,
-- never a counter-write: while Mercy drives, OSSC leaves the body alone.
--
-- Nothing here changes the contract Mercy codes against: it still detects us by
-- content file, still holds us through I.OSSC_Caster.pause('MercyCAO'), still
-- asks us not to pick its own spell records, and still casts through
-- castSpellAtTarget. We only stop doing the three things it cannot stop us
-- doing (stance, attack input, and casting over its routines).

--- Refresh the live "Mercy drives this actor" flag. `hasCombatTarget` is what
--- OSSC itself sees on the actor, so the gate never rests on Mercy's state
--- alone.
local function refreshMercyDriver(hasCombatTarget)
    local driving = mercy.isDriving(hasCombatTarget == true) == true
    if driving ~= Cfg.mercyDriving then
        Cfg.mercyDriving = driving
        debugLogf('Mercy CAO %s this actor (fixed compatibility=cooperate)',
            driving and 'drives' or 'does not drive')
    end
end

--- True while Mercy owns this actor's body: either it drives right now, or it
--- drove when the cast now in flight started. A cast must never have its
--- stance and attack input handed back and forth half way through — so the
--- flag is latched for the duration of a cast rather than re-read per frame.
local function mercyOwnsBody()
    -- An OSSC window is the one interval where Mercy has explicitly yielded
    -- stance and attack ownership; Mercy's own cast-preservation helper must
    -- not restore the Spell stance over the quick-cast animation.
    if Cast.mercyWindowActive then return false end
    return Cfg.mercyDriving or (Cast.isCasting and Cast.mercyCast)
end

--- Why OSSC must not start a quick-cast of its own this evaluation, or nil
--- when it may.
---
--- Read live off Mercy's state rather than trusting the pause Mercy sends us.
--- That hold is sent from Mercy's own onUpdate, so it is always one frame
--- stale, and it never arrives at all when Mercy's onUpdate returns early —
--- which it does whenever another mod switched Mercy off, and both Fair Care
--- and NGarde do exactly that mid-fight to let the engine use a healing item.
--- Owning the read makes this gate independent of the frame order and of
--- Mercy running at all.
---
--- Under the fixed Cooperate policy, Mercy only blocks a cast while its body
--- is committed; OSSC continues choosing the actor's own spells between those
--- routines.
local function mercyCastBlockReason()
    if not Cfg.mercyDriving then return nil end
    -- Mercy yielded the body for this window; its saved busy fields are
    -- restored only when the cast finishes.
    if Cast.mercyWindowActive then return nil end
    return mercy.busyReason()
end

-- Mercy's hold is a pause reason like any other, but it is the one reason OSSC
-- drops on its own: Mercy only ever releases it from its own onUpdate, and if
-- that stops running (Mercy switched off by another mod, or never started on
-- this actor because it is blacklisted) the hold would silence this caster for
-- the rest of the fight. Only Mercy's own two reason keys are touched — a hold
-- another mod filed stays exactly where it is. The grace covers the ordinary
-- one-frame lag between the two scripts' updates.
local MERCY_HOLD_GRACE = 0.5

-- How long a vanilla cast queued during a Mercy pause stays protected after
-- Mercy releases that pause (the NPCMercyVanillaCastWindow setting, default
-- 5 s, read into Cfg.mercyVanillaCastWindow by refreshSettings; 0 disables
-- the protection). Mercy's hold can lift a fraction of a second after the
-- actor entered Spell stance, before the engine presses its cast input. The
-- universal Spell-stance stand-down already protects that cast; the grace
-- still stops an immediate re-strip when a pause lifts and the stance has not
-- been restored yet. It ends early the moment the stance leaves Spell.

local function isMercyPauseReason(reason)
    return reason == mercy.PAUSE_REASONS[1] or reason == mercy.PAUSE_REASONS[2]
end

--- True while a REAL vanilla spellcast key window (self/target/touch Start or
--- Release) that was active under a Mercy pause is still owed its window after
--- the pause lifted. Only ever true in Spell stance and only armed while that
--- key hold was open; a bare posture never starts this timer. Leaving the
--- stance ends the window at once so OSSC resumes on the very next update.
local function mercyVanillaCastActive(now)
    if Cast.mercyVanillaCastUntil == 0.0 then return false end
    if now > Cast.mercyVanillaCastUntil
        or types.Actor.getStance(self) ~= STANCE.Spell then
        Cast.mercyVanillaCastUntil = 0.0
        return false
    end
    return true
end

--- True while a REAL vanilla cast cycle active during an external pause is
--- still owed its resume grace after that pause lifted. Same stance rule as
--- the Mercy window: the grace only protects a cycle keyed in Spell stance,
--- and leaving that stance (or SpellCast Unequip Stop) ends it. It is armed by
--- Pause.set on releases where a real cast cycle was active and by
--- releaseStaleMercyHold only in that same case; a bare posture no longer
--- arms it.
local function externalPauseGraceActive(now)
    if Cast.externalPauseGraceUntil == 0.0 then return false end
    if now > Cast.externalPauseGraceUntil
        or types.Actor.getStance(self) ~= STANCE.Spell then
        Cast.externalPauseGraceUntil = 0.0
        return false
    end
    return true
end

--- Arm the resume grace after a pause lifts, but ONLY while a real vanilla
--- cast cycle is pending (waiting for SpellCast Unequip Stop). A bare Spell
--- posture, equip/idle spellcast animation, or sticky selected spell must not
--- arm a 5 s grace: that used to keep the engine spell list restored and
--- silence OSSC for the whole fight.
--- This is the single "do not remove the spells before the timer is off"
--- cooldown (NPCPauseResumeGrace, 0 = re-strip immediately). It backs every
--- release path; Mercy's own NPCMercyVanillaCastWindow stays in place
--- untouched and the two windows simply overlap while either is live.
local function armExternalPauseGrace()
    if Cfg.pauseResumeGrace <= 0 then return end
    -- Same exception: a release during an OSSC quick-cast window is part of
    -- the handshake, not a vanilla cast waiting in Spell stance.
    if Cast.mercyWindowActive then return end
    if types.Actor.getStance(self) ~= STANCE.Spell then return end
    -- Spell stance alone is NOT a queued vanilla cast. Only an active
    -- self/target/touch spellcast Start / Release key window counts.
    if not Combat.realVanillaSpellcastActive() then
        debugLog('Pause released in bare Spell stance — no vanilla cast key to protect')
        return
    end
    Cast.externalPauseGraceUntil = core.getSimulationTime() + Cfg.pauseResumeGrace
    debugLog('Pause released during a vanilla cast cycle — resume grace protects it')
end

local function releaseStaleMercyHold(now)
    local held = Pause.reasons[mercy.PAUSE_REASONS[1]] ~= nil
        or Pause.reasons[mercy.PAUSE_REASONS[2]] ~= nil
    if not held or Cfg.mercyDriving or Cast.mercyWindowActive then
        Cast.mercyHoldSince = 0.0
        return
    end
    if Cast.mercyHoldSince == 0.0 then
        Cast.mercyHoldSince = now
        return
    end
    if now - Cast.mercyHoldSince < MERCY_HOLD_GRACE then return end
    Pause.reasons[mercy.PAUSE_REASONS[1]] = nil
    Pause.reasons[mercy.PAUSE_REASONS[2]] = nil
    Cast.mercyHoldSince = 0.0
    Pause.refresh()
    -- This is a Mercy unpause just like an explicit release: if a real
    -- vanilla cast cycle is pending its cast gets the same resume grace
    -- instead of being re-stripped on the next update.
    armExternalPauseGrace()
    -- And the released actor is owed its vanilla casts: the spell list Mercy
    -- restored must survive until the engine has used it.
    Combat.armVanillaCastAllowance('Mercy hold released')
    debugLog('Mercy CAO hold released — Mercy is not driving this actor')
end

-- Settings mirrored into global storage are re-read periodically so menu
-- changes reach already-attached actor scripts without a reload.
Cast.nextSettingsRefresh = 0.0
Cast.nextDebugTick       = 0.0
Cast.nextGateLog         = 0.0

local function refreshSettings()
    refreshDebugMode()
    -- Fallback values mirror the registered settings-menu defaults exactly.
    Cfg.enabled      = settingOr(Cfg.npc, 'NPCQuickCastEnabled', true)
    Cfg.pollInterval = settingOr(Cfg.npc, 'NPCQuickCastPollInterval', 1.0)
    if Cfg.pollInterval <= 0 then Cfg.pollInterval = 1.0 end
    Cfg.minDist      = settingOr(Cfg.npc, 'NPCQuickCastMinDistance', 500)
    Cfg.maxDist      = settingOr(Cfg.npc, 'NPCQuickCastMaxDistance', 700)
    -- The pair is one formula: full chance at or below the Full Chance
    -- Distance, zero at or beyond the Maximum Cast Distance. The menu allows
    -- an inverted pair (Full Chance 50..600, Maximum 300..3500), and an
    -- inverted pair made the chance function and the hard "never cast past
    -- the Maximum Cast Distance" gate above disagree about where the
    -- full-chance band ends. Nest the bands (clamping the lower one only, so
    -- the hard distance gate keeps the value the user chose) and the two
    -- always describe the same range.
    if Cfg.minDist > Cfg.maxDist then Cfg.minDist = Cfg.maxDist end
    Cfg.baseChance   = settingOr(Cfg.npc, 'NPCQuickCastBaseChance', 100) / 100
    Cfg.cooldownMin  = settingOr(Cfg.npc, 'NPCQuickCastCooldownMin', 3.5)
    Cfg.cooldownMax  = math.max(Cfg.cooldownMin, settingOr(Cfg.npc, 'NPCQuickCastCooldownMax', 8.5))
    Cfg.allowPowers  = settingOr(Cfg.npc, 'NPCQuickCastAllowPowers', false)
    Cfg.randomAnims  = settingOr(Cfg.npc, 'NPCQuickCastRandomAnims', true)
    -- A hand-edited or corrupt value falls back to the registered default
    -- of 5 s; negative values clamp to 0 (protection disabled).
    Cfg.mercyVanillaCastWindow = math.max(0,
        tonumber(settingOr(Cfg.npc, 'NPCMercyVanillaCastWindow', 5.0)) or 5.0)
    -- Mercy quick-cast windows: the window itself is always used (hardcoded;
    -- the toggle is gone), the cooldown between windows is still a setting so
    -- Mercy's own behaviour is not interrupted every poll tick. Mercy keeps a
    -- spellcaster in Spell stance as a posture, which would otherwise make OSSC
    -- stand down for the whole fight; OSSC briefly asks Mercy to yield for one
    -- blended quick-cast and then restores Mercy and its stance.
    Cfg.mercyQuickcastWindow = true
    Cfg.mercyWindowCooldown = math.max(0.5,
        tonumber(settingOr(Cfg.npc, 'NPCMercyQuickcastWindowCooldown', 2.0)) or 2.0)
    -- After a real vanilla cast key, wait for SpellCast Unequip Stop before
    -- stripping spells / allowing quick-casts. Hardcoded at 5 s (the setting is
    -- gone): the authored keys arrive well inside it, and the fallback only
    -- exists for an animation whose Unequip Stop key is missing.
    Cfg.vanillaCastUnequipTimeout = 5.0
    -- Universal pause resume grace: how long a released pause keeps the actor's
    -- spells restored. Hardcoded at 2 s (the setting is gone).
    Cfg.pauseResumeGrace = 2.0
    -- Vanilla-cast allowance: how many engine casts a released actor may finish
    -- before OSSC re-strips the list, and the seconds each of them may take. A
    -- corrupt value falls back to the registered defaults (1..2 casts / 6 s);
    -- a max below the min is clamped up, so a hand-edited pair can never make
    -- the range negative.
    Cfg.vanillaCastsAllowedMin = math.floor(math.max(0,
        tonumber(settingOr(Cfg.npc, 'NPCVanillaCastsAllowedMin', 1)) or 1))
    Cfg.vanillaCastsAllowedMax = math.floor(math.max(0,
        tonumber(settingOr(Cfg.npc, 'NPCVanillaCastsAllowedMax', 2)) or 2))
    -- min < max randomises the count per hand-back; equal values pin it. A
    -- min of 0 with a larger max lets some hand-backs go straight to OSSC.
    if Cfg.vanillaCastsAllowedMax < Cfg.vanillaCastsAllowedMin then
        Cfg.vanillaCastsAllowedMax = Cfg.vanillaCastsAllowedMin
    end
    Cfg.vanillaCastAllowanceTimeout = math.max(0,
        tonumber(settingOr(Cfg.npc, 'NPCVanillaCastAllowanceTimeout', 6.0)) or 6.0)
    -- Readiness grace: how long an UNUSED allowance waits for the engine to
    -- ready magic before OSSC takes the spell list back. Hardcoded at 1.5 s
    -- (the setting is gone).
    Cfg.vanillaCastAllowanceReadiness = 1.5
    -- Weapon-ready delay after OSSC takes the body over. Hardcoded at 1.5 s
    -- (the setting is gone): a Mercy CAO yield that hands the body over out of
    -- a Spell stance makes the engine DRAW the weapon, and the first quick-cast
    -- waits this long so the gesture is not blended over a weapon still coming
    -- out of the sheath.
    Cfg.equipReadiness = 1.5
    -- Bystanders on the line of fire are passed through (default on).
    Cfg.projectilesPassThroughBystanders =
        settingOr(Cfg.npc, 'NPCProjectilesPassThroughBystanders', true) == true
    local t = Cfg.tactics
    t.touchChance       = settingOr(Cfg.npc, 'NPCQuickCastTouchChance', 60)
    t.touchTargetChance = settingOr(Cfg.npc, 'NPCQuickCastTouchTargetChance', 10)
    -- Allow Quick-Cast In Spell Stance (player setting, mirrored to global
    -- storage): with it on, an actor / creature may quick-cast from the
    -- engine's Spell stance too. Off (the registered default) keeps the
    -- original rule — no quick-cast, no animation, from Spell stance.
    Cfg.allowCastInSpellStance =
        settingOr(Cfg.general, 'AllowQuickCastInSpellStance', false) == true
    Cfg.costs.useFatigue   = settingOr(Cfg.general, 'UseFatigue', true) == true
    -- Same read order as the player script (UseFatigueScale, legacy
    -- FatigueScale); unsynced/corrupt values fall back to the registered
    -- default of 5.0.
    Cfg.costs.fatigueScale = tonumber(settingOr(Cfg.general, 'UseFatigueScale', nil))
        or tonumber(settingOr(Cfg.general, 'FatigueScale', nil)) or 5.0
    Cfg.costs.chancePenalty = settingOr(Cfg.general, 'QuickCastChancePenalty', 'off')
    -- NPC spell-decision settings (same group as the quick-cast settings).
    Cfg.trace             = settingOr(Cfg.ai, 'NPCAIDecisionTrace', false)
    Cfg.magickaReservePct = tonumber(settingOr(Cfg.ai, 'NPCAIMagickaReserve', 25)) or 25
    -- Heal threshold, ONE value for the whole decision: the Self-heal priority,
    -- the follower (ally) heal and the LowHealth reaction all read the same
    -- NPCQuickCastHealThreshold. (The retired 'Heal Critical Floor' setting was a
    -- second, never-read answer to the same question — see finding 66.)
    Cfg.healThresholdPct = tonumber(settingOr(Cfg.npc, 'NPCQuickCastHealThreshold', 40)) or 40
    Cfg.weaknessMinMagnitude = math.max(0,
        tonumber(settingOr(Cfg.ai, 'NPCAIWeaknessMinMagnitude', 15)) or 15)
    Cfg.beneficialBuffMinDuration = math.max(0,
        tonumber(settingOr(Cfg.ai, 'NPCAIBeneficialBuffMinDuration', 15)) or 15)
    -- Reactions (NPCAIReactions): 'Off' | 'LowHealth' | 'Broad'. An unknown or
    -- hand-edited value falls back to the registered default.
    local reactionItem = settingOr(Cfg.ai, 'NPCAIReactions', 'LowHealth')
    Cfg.reactions = (reactionItem == 'Off' or reactionItem == 'Broad')
        and reactionItem or 'LowHealth'
    local declined = settingOr(Cfg.ai, 'NPCAIDeclinedSpells', '')
    if type(declined) ~= 'string' then declined = '' end
    if declined ~= Cfg.declinedRaw then
        -- One parse per change (the raw string is the cache key); ids are
        -- stored lowercased and compared lowercased in Tactics.
        Cfg.declinedRaw = declined
        local set = {}
        for id in declined:gmatch('[^,]+') do
            local trimmed = id:match('^%s*(.-)%s*$')
            if trimmed ~= '' then set[trimmed:lower()] = true end
        end
        Cfg.declinedSpells = set
    end
    -- Same-buff recast lockout, in seconds (0 disables). A hand-edited or
    -- corrupt value falls back to the registered default of 30.
    Cfg.buffRecastCooldown = math.max(0,
        tonumber(settingOr(Cfg.ai, 'NPCAIBuffRecastCooldown', 30)) or 30)
    -- Ally support level. AllyCasting arrives as a select item string
    -- and is mapped to the internal 0..3 level once, here. (Target policy
    -- needs no read: EngineTargetsOnly is fixed, see pickCombatTarget.)
    local allyItem = settingOr(Cfg.ai, 'NPCAIAllyCasting', 'Moderate')
    Cfg.allyLevel = allyItem == 'Off' and 0 or allyItem == 'Cheap' and 1
        or allyItem == 'Rich' and 3 or allyItem == 'Moderate' and 2 or 2
end

-- ── Static tables ──────────────────────────────────────────────────────────
-- All animation data for this actor, in Anim (declared with Cfg above): the
-- school/range → group map, the settings keys behind it, the pools a per-actor
-- animation set is rolled from, and the timings that shape a cast.
Anim.SCHOOL_STRS = {
    [0] = 'alteration', [1] = 'conjuration', [2] = 'destruction',
    [3] = 'illusion', [4] = 'mysticism', [5] = 'restoration',
}

local function getQuickCastEffectScale(spell)
    if effectPenaltyExempt(spell) then
        return 1.0
    end
    -- 'skill_based' follows the actor's skill in the spell's school; anything
    -- else is a flat percentage (or off).
    local mode = settingOr(Cfg.general, 'QuickCastEffectPenalty', 'off')
    if Penalty.isSkillBased(mode) then
        local firstEffect = spell and spell.effects and spell.effects[1]
        local mgef = firstEffect and effectRecords[firstEffect.id]
        local school = mgef and mgef.school
        if type(school) == 'number' then school = Anim.SCHOOL_STRS[school] end
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
-- with exactly the player-side formulas.  Everything hangs off the Cfg.costs
-- table (declared with the settings block at the top) so this main chunk pays
-- for one field instead of a dozen locals.
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
Cfg.costs.GMST = {
    fFatigueSpellBase = core.getGMST('fFatigueSpellBase') or 0,
    fFatigueSpellMult = core.getGMST('fFatigueSpellMult') or 0,
    fFatigueBase      = core.getGMST('fFatigueBase') or 1.25,
    fFatigueMult      = core.getGMST('fFatigueMult') or 0.5,
    fEffectCostMult   = core.getGMST('fEffectCostMult') or 1.0,
}

function Cfg.costs.payFatigue(magickaCost)
    if not Cfg.costs.useFatigue then return end
    if type(magickaCost) ~= 'number' or magickaCost <= 0 then return end
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    if not fatigue then return end
    local gmst = Cfg.costs.GMST
    local fBase = gmst.fFatigueSpellBase
    local fMult = gmst.fFatigueSpellMult
    if not (fBase > 0 or fMult > 0) then fBase, fMult = 0.5, 0.5 end
    local enc = 0
    local encumbrance = types.Actor.getEncumbrance(self)
    local capacity = types.Actor.getCapacity(self)
    if type(encumbrance) == 'number' and type(capacity) == 'number' and capacity > 0 then
        enc = math.max(0, math.min(1, encumbrance / capacity))
    end
    local fatigueCost = magickaCost * (fBase + enc * fMult) * math.max(0, Cfg.costs.fatigueScale)
    if fatigueCost > 0 then
        fatigue.current = math.max(0, fatigue.current - fatigueCost)
        debugLogf('Fatigue cost %.2f paid (encumbrance %.0f%%, scale %.2f)',
            fatigueCost, enc * 100, Cfg.costs.fatigueScale)
    end
end

function Cfg.costs.penaltyActive()
    local mode = Cfg.costs.chancePenalty
    if mode == nil then return false end
    if Penalty.isSkillBased(mode) then return true end
    return Penalty.scale(mode) < 1.0
end

-- The vanilla fatigue term of the cast-chance formula; ignoreFatigue mirrors
-- the player's getCastChance option: it only applies while UseFatigue is on.
function Cfg.costs.fatigueTerm()
    if not Cfg.costs.useFatigue then return 1 end
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local normalized = 1
    if fatigue and fatigue.base ~= 0 then
        normalized = math.max(0, fatigue.current / fatigue.base)
    end
    local gmst = Cfg.costs.GMST
    return gmst.fFatigueBase - gmst.fFatigueMult * (1 - normalized)
end

function Cfg.costs.skillValue(school)
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
function Cfg.costs.baseChance(spell)
    local record = spell and spell.id and spellRecords[spell.id] or nil
    local firstEffect = (spell and spell.effects and spell.effects[1])
        or (record and record.effects and record.effects[1])
    local firstMgef = firstEffect and effectRecords[firstEffect.id]
    local firstSchool = firstMgef and firstMgef.school
    if type(firstSchool) == 'number' then firstSchool = Anim.SCHOOL_STRS[firstSchool] end
    if not record or record.type ~= SPELL_TYPE.Spell then
        return 100, firstSchool -- powers (and anything else) are sure casts
    end
    if self.type ~= types.NPC then
        return 100, firstSchool -- creatures: no skill roll, engine parity
    end
    local activeEffects = types.Actor.activeEffects(self)
    local gmst = Cfg.costs.GMST
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
            if type(school) == 'number' then school = Anim.SCHOOL_STRS[school] end
            local s = 2 * Cfg.costs.skillValue(school)
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
        + 0.2 * willpower + 0.1 * luck) * Cfg.costs.fatigueTerm()
    chance = math.max(0, math.min(100, chance))
    return math.floor(chance), effectiveSchool
end

-- The QuickCastChancePenalty multiplier for this cast; a skill-based value
-- resolves against the actor's skill in the cast's effective school (0 for a
-- creature — no magic school skills).
function Cfg.costs.chanceScale(effectiveSchool)
    if Penalty.isSkillBased(Cfg.costs.chancePenalty) then
        return Penalty.skillScale(Cfg.costs.skillValue(effectiveSchool))
    end
    return Penalty.scale(Cfg.costs.chancePenalty)
end

Anim.RANGE_STRS = {
    [RANGE.Self] = 'Self', [RANGE.Touch] = 'Touch', [RANGE.Target] = 'Target',
}

Anim.BY_SCHOOL_AND_RANGE = {
    destruction = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qcdrain', [RANGE.Target] = 'quickcast' },
    restoration = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qcdrain', [RANGE.Target] = 'quickcast' },
    alteration  = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'qcalt' },
    illusion    = { [RANGE.Self] = 'quickbuff', [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'qcill' },
    conjuration = { [RANGE.Self] = 'qcconj',    [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'qcconj' },
    mysticism   = { [RANGE.Self] = 'qcsnap',    [RANGE.Touch] = 'qctouch', [RANGE.Target] = 'quickcast' },
}

-- Settings key of the per-school/range animation choice, built once.
Anim.SETTING_KEYS = {}
for school in pairs(Anim.BY_SCHOOL_AND_RANGE) do
    local schoolKey = school:sub(1, 1):upper() .. school:sub(2)
    local keys = {}
    for range, rangeStr in pairs(Anim.RANGE_STRS) do
        keys[range] = 'Anim_' .. schoolKey .. '_' .. rangeStr .. '_3rd'
    end
    Anim.SETTING_KEYS[school] = keys
end

Anim.QUICKCAST_GROUPS = {
    'quickcast', 'quickbuff', 'qcconj', 'qctouch', 'qcalt', 'qcalts', 'qcill', 'qcsnap', 'qcdrain', 'qcskrow',
}

Anim.SPEED_KEYS = {
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
Anim.ROLL_SELF_POOL = { 'quickbuff', 'qcconj' }
Anim.ROLL_POOL      = { 'quickcast', 'qctouch', 'qcalt', 'qcill', 'qcsnap', 'qcdrain', 'qcskrow' }
Anim.rolled         = nil

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
    for _, school in pairs(Anim.SCHOOL_STRS) do
        rolled[school] = {
            [RANGE.Self]   = Anim.ROLL_SELF_POOL[math.random(#Anim.ROLL_SELF_POOL)],
            [RANGE.Touch]  = Anim.ROLL_POOL[math.random(#Anim.ROLL_POOL)],
            [RANGE.Target] = Anim.ROLL_POOL[math.random(#Anim.ROLL_POOL)],
        }
    end
    Anim.rolled = rolled
    if not Cfg.debugMode then return end
    local parts = {}
    for _, school in pairs(Anim.SCHOOL_STRS) do
        local r = rolled[school]
        parts[#parts + 1] = string.format('%s(self=%s,touch=%s,target=%s)',
            school, r[RANGE.Self], r[RANGE.Touch], r[RANGE.Target])
    end
    table.sort(parts)
    debugLog('Rolled cast animations: ' .. table.concat(parts, ' '))
end

-- ── Combat / attack data ───────────────────────────────────────────────────
-- Animation groups and weapon classes the cast gates consult, in Combat.
Combat.INCAPACITATED_GROUPS = {
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
Combat.ANIM_GROUPS    = { 'shield', 'weapontwohand', 'weapontwowide', 'bowandarrow', 'crossbow' }
Combat.ANIM_GROUP_SET = toSet(Combat.ANIM_GROUPS)

-- A held attack charge parks the weapon animation on a text key ("min attack"
-- / "max attack"), so anim.isPlaying() returns false while the actor is
-- winding up or holding a charged attack. Track that hold window through the
-- combat animation text keys instead: charge keys open it, release/follow
-- keys close it, and a short safety cap bounds a missed release key so a
-- stale window can never permanently block casts.
Cast.chargeUntil = 0
-- Separate hold window for 1H / H2H / thrown charges: the cast must blend
-- around them, NOT use them as a BlockDuringCombatAnims cast veto.
Cast.lightChargeUntil = 0
Anim.chargeHoldWindow = 1.5

-- Attack animation groups blocked by BlockWeaponDuringQuickcast while a
-- quickcast is playing (the same heavy weapon classes the player script
-- guards). Shield blocking is not an attack, so 'shield' is left out.
Combat.HEAVY_GROUPS    = { 'weapontwohand', 'weapontwowide', 'bowandarrow', 'crossbow' }
Combat.HEAVY_GROUP_SET = toSet(Combat.HEAVY_GROUPS)

-- Self-heal bookkeeping for a dead-locked engine attack input (see
-- releaseEngineAttack below): simulation time since the engine attack input
-- was first seen continuously held while no heavy attack animation plays.
Cast.stuckAttackInputSince = nil
Anim.stuckAttackInputTimeout = 2.0

-- Which heavy group is currently DRAWING a weapon (equip), not attacking. The
-- engine attaches the weapon mesh on that play's 'equip attach' text key, so a
-- cancel before it fires leaves the actor holding an equipped but INVISIBLE
-- weapon — it then attacks the player with nothing in its hands. The player
-- script has carried this guard for its own draws for a long time
-- (Stance.collapsedDrawGroup); the actor side could still cancel the draw from
-- the per-frame abort below.
Cast.drawTracker = castRules.newDrawTracker()
--   drawTransition - which way the actor's last ready / unready went and what
--                    it is playing on. A cast in flight must survive it.
Cast.drawTransition = castRules.newDrawTransition()

-- One-handed / hand-to-hand / thrown attack groups. Never cancelled mid-cast,
-- and the cast must not steal their RightArm/Torso bones (see the matching
-- list + buildCastBlendOptions in ossc_player.lua).
Combat.LIGHT_GROUPS    = { 'weapononehand', 'weapononehand1', 'handtohand', 'throwweapon' }
Combat.LIGHT_GROUP_SET = toSet(Combat.LIGHT_GROUPS)

-- Weapon record types whose attack animations live in the heavy groups above.
-- A quickcast only blocks a heavy-weapon attack when the actor actually HAS
-- one of these equipped: one-handed weapons, hand-to-hand and an empty hand
-- stay usable mid-cast — the cast animation is deliberately played below
-- PRIORITY.Weapon so those swings blend over the cast naturally.
Combat.EXCLUDED_WEAPON_TYPE_TO_GROUP = {
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
Anim.deadlineMargin = 0.35
Cast.deadline = 0.0

-- Set whenever this cast actually suppressed the engine attack input (vetoed
-- play / released input); the input is handed back when the cast ends.
Cast.attackSuppressedDuringCast = false

-- Vanilla magic bolt base speed (see ProjectileManager::launchMagicBolt and
-- Spell Framework Plus' auto speed): fTargetSpellMaxSpeed × effect speed.
local F_TARGET_SPELL_MAX_SPEED = core.getGMST('fTargetSpellMaxSpeed') or 1000

-- Spell vendors are completely outside OSSC NPC casting.
local function isSpellVendor()
    if self.type ~= types.NPC then return false end
    local services = types.NPC.record(self).servicesOffered
    return services ~= nil and services.Spells == true
end
local IS_SPELL_VENDOR   = isSpellVendor()
local IS_BIPED_CREATURE = self.type == types.Creature and types.Creature.record(self).isBiped == true
-- Non-biped skeletons lack hand bones/quickcast groups (lookups raise DelayedAction errors): no hand-anchored effects.
local IS_BIPED = self.type == types.NPC or IS_BIPED_CREATURE
local SCRIPT_PATH = self.type == types.Creature and 'scripts/ossc/ossc_creature.lua' or 'scripts/ossc/ossc_npc.lua'

-- ── Animation / attack helpers ──
local function playingGroup(groups)
    for i = 1, #groups do
        if anim.isPlaying(self, groups[i]) then return groups[i] end
    end
    return nil
end

-- Excluded (2H/bow/crossbow) group of the right-hand weapon, or nil. Mirrors the player script.
local function getExcludedWeaponGroup()
    local weapon = types.Actor.getEquipment(self, SLOT.CarriedRight)
    if not weapon or weapon.type ~= types.Weapon then return nil end
    return Combat.EXCLUDED_WEAPON_TYPE_TO_GROUP[types.Weapon.record(weapon).type]
end

Combat.BOUND_2H_EFFECT_IDS = {
    [core.magic.EFFECT_TYPE.BoundSpear]     = true,
    [core.magic.EFFECT_TYPE.BoundBattleAxe] = true,
    [core.magic.EFFECT_TYPE.BoundLongbow]   = true,
    ['boundspear']     = true,
    ['boundbattleaxe'] = true,
    ['boundlongbow']   = true,
}

local function hasBound2HWeaponEffect(spell)
    if not spell then return false end
    if spell.effects then
        for _, eff in ipairs(spell.effects) do
            if eff and eff.id and Combat.BOUND_2H_EFFECT_IDS[eff.id] then return true end
        end
    end
    local rec = spellRecords[spell.id]
    if rec and rec.effects then
        for _, eff in ipairs(rec.effects) do
            if eff and eff.id and Combat.BOUND_2H_EFFECT_IDS[eff.id] then return true end
        end
    end
    return false
end

-- Unequip the shield to prevent blocking, but attach its mesh to the left-hand
-- bone via addVfx so it stays visually in place during the quickcast window.
local function suppressShieldDuringCast()
    if not IS_BIPED then return end -- the ghost VFX anchors to 'Bip01 L Hand'
    if type(anim.hasBone) == 'function' and not anim.hasBone(self, 'Bip01 L Hand') then return end
    if Cast.suppressedShield then return end
    local eq = types.Actor.getEquipment(self)
    local item = eq[SLOT.CarriedLeft]
    local armorRec = item and item.type == types.Armor
        and types.Armor.record(item) or nil
    local isShield = armorRec ~= nil and armorRec.type == types.Armor.TYPE.Shield
    -- Shared rule with the player script (ossc_cast_rules.shouldGhostShield):
    -- the shield is only hidden when the cast frees a weapon grip. A bare-handed
    -- (hand-to-hand) caster keeps its shield and never gets the ghost mesh, and
    -- a two-handed weapon / bow / crossbow has no free hand for the shield.
    if not castRules.shouldGhostShield({
        rightWeapon    = types.Actor.getEquipment(self, SLOT.CarriedRight),
        excludedWeapon = getExcludedWeaponGroup() ~= nil,
        shield         = isShield and item or nil,
        setting        = settingOr(Cfg.general, 'BlockShieldDuringQuickcast', false),
    }) then
        return
    end
    if armorRec.model and armorRec.model ~= '' then
        anim.addVfx(self, armorRec.model, {
            loop            = true,
            vfxId           = Cast.shieldGhostVfxId,
            boneName        = 'Bip01 L Hand',
            useAmbientLight = false,
        })
        Cast.shieldGhostVfxActive = true
        debugLog('Shield ghost VFX added: ' .. armorRec.model)
    end
    Cast.suppressedShield = item
    eq[SLOT.CarriedLeft] = nil
    types.Actor.setEquipment(self, eq)
    debugLog('Shield unequipped for blocking suppression: ' .. tostring(item.recordId))
end

-- anim.removeVfx raises "Object has no animation" once the actor's animation is gone (common during detach).
local function removeVfxSafely(vfxId)
    if not anim.hasAnimation(self) then return false end
    anim.removeVfx(self, vfxId)
    return true
end

local function restoreShieldAfterCast()
    -- Only reach for the VFX when one was actually spawned: the shield is
    -- unequipped even when its record has no model, in which case there was
    -- never anything to remove.
    if Cast.shieldGhostVfxActive then
        if removeVfxSafely(Cast.shieldGhostVfxId) then
            Cast.shieldGhostVfxActive = false
        end
    end
    if Cast.suppressedShield then
        if Cast.suppressedShield:isValid() then
            local eq = types.Actor.getEquipment(self)
            if not eq[SLOT.CarriedLeft] then
                eq[SLOT.CarriedLeft] = Cast.suppressedShield
                types.Actor.setEquipment(self, eq)
                debugLog('Shield re-equipped after quickcast: ' .. tostring(Cast.suppressedShield.recordId))
            end
        end
        Cast.suppressedShield = nil
    end
end

-- True while the quickcast window counts as "hands busy" and the setting asks
-- for heavy attacks to be blocked. The cast-state flags are used rather than
-- anim.isPlaying: a cast animation can momentarily report not playing between
-- text keys / while blended, which would let a 2H swing through.
local function shouldBlockHeavyAttack()
    if Cast.isBound2HWeaponCast then return false end
    if not Cast.isCasting or Cast.currentAnimGroup == nil then return false end
    -- Never let the block outlive the cast window it belongs to, even if
    -- `isCasting` itself got wedged (see the deadline comment above).
    if core.getSimulationTime() > Cast.deadline then return false end
    if not settingOr(Cfg.general, 'BlockWeaponDuringQuickcast', false) then return false end
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
--
-- Mercy CAO writes self.controls.use itself, every frame, from its own
-- onUpdate (ImprovedAI.lua: omwself.controls.use = state.attack). Overwriting
-- it here cancels whatever attack Mercy is winding up or holding — a charged
-- swing, a bow draw — which is visible as the NPC stalling mid-burst and then
-- starting the attack over. So while Mercy drives this actor the input is
-- Mercy's, and this is a no-op (see scripts/ossc/ossc_mercy.lua).
local function releaseEngineAttack()
    if mercyOwnsBody() then return end
    local controls, attackTypes = self.controls, self.ATTACK_TYPE
    if not controls or not attackTypes then return end
    if controls.use == attackTypes.NoAttack then return end
    controls.use = attackTypes.NoAttack
end

-- For non-player actors openmw mirrors the "attacking or spell" flag into
-- self.controls.use every mechanics frame, so this is a reliable read — for an
-- actor driven by the ENGINE's AI. With Mercy CAO installed the flag is
-- whatever Mercy wrote last, so "the engine is holding an attack" is not a
-- question OSSC can answer and every heuristic built on it stands down.
local function isEngineAttackInputHeld()
    if mercyOwnsBody() then return false end
    local controls, attackTypes = self.controls, self.ATTACK_TYPE
    if not controls then return false end
    if not attackTypes then return controls.use ~= 0 end
    return controls.use ~= attackTypes.NoAttack
end

-- ── Mercy CAO / bare Spell-posture quick-cast windows ─────────────────────
-- Mercy often keeps a spellcaster in STANCE.Spell as a warning posture, and
-- the vanilla engine AI can also idle in Spell stance with a sticky selected
-- spell after a cast. The unconditional vanilla-stance stand-down silenced
-- OSSC for the whole fight. These helpers negotiate a short, explicitly owned
-- window instead: Mercy yields the combat trees when its interface is present,
-- OSSC swaps to Weapon stance, plays ONE blended quick-cast, and restores
-- Mercy's state and stance afterwards. A local takeover (no Mercy yield) keeps
-- Weapon stance instead of restoring the bare posture. No stance or pause
-- writes from another mod are overwritten.

function Combat.onlyMercyPauses()
    if Pause.detachPending then return false end
    for reason in pairs(Pause.reasons) do
        if not isMercyPauseReason(reason) then return false end
    end
    return true
end

--- During a window, Mercy's own hold is intentionally bypassed: Mercy has
--- already been asked to yield, and its state will release that hold through
--- its normal updateOSSCHold() path. Any other pause still wins.
function Combat.pauseBlocksOSSC()
    if not Pause.suspended then return false end
    if not Cast.mercyWindowActive then return true end
    return not Combat.onlyMercyPauses()
end

--- OSSC is putting this actor into Weapon stance itself: taking the body back
--- from Mercy, or taking over a bare vanilla Spell posture. That stance flip is
--- what makes the engine DRAW the weapon ('equip start' → 'equip attach'), and
--- the actor used to quick-cast on the very same frame — the gesture blended
--- over a weapon that was still on its way out of the sheath, so the first cast
--- after a Mercy hand-back looked like it happened mid-equip.
---
--- Arm the readiness deadline instead (NPCQuickCastEquipReadiness, default
--- 0.75 s, 0 disables it): the first quick-cast waits for the weapon to be out.
--- The wait survives the hand-back itself — a Mercy window lives through it —
--- and every fresh takeover gets its own, because the arm is released as soon
--- as the actor is seen standing in Weapon stance again.
function Combat.noteWeaponTakeover(now)
    if Cfg.equipReadiness <= 0 then return end
    -- One bounded wait per draw. `equipArmed` is cleared the moment the actor
    -- is actually seen standing in Weapon stance again, so a normal takeover
    -- re-arms every time; a stance fight — the engine AI (or Mercy) flipping
    -- the actor back to Spell every single frame — arms exactly once and then
    -- lets the cast through, because a rolling timer there would silence the
    -- caster for the whole fight.
    if Cast.equipArmed then return end
    Cast.equipArmed = true
    Cast.equipReadyUntil = now + Cfg.equipReadiness
    debugLogf('Weapon stance taken over — first quick-cast held %.2fs for the draw',
        Cfg.equipReadiness)
end

--- True while the draw OSSC started by taking the body over is still running
--- out. Clears the deadline once it has passed, so a stale arm can never hold
--- the caster forever.
function Combat.equipReadinessPending(now)
    if Cast.equipReadyUntil == 0.0 then return false end
    if now >= Cast.equipReadyUntil then
        Cast.equipReadyUntil = 0.0
        return false
    end
    return true
end

function Combat.endMercyWindow(reason)
    if not Cast.mercyWindowActive then return end
    local wasLocal = Cast.mercyWindowLocal
    local restoreStance = Cast.mercyWindowRestoreStance
    local savedStance = Cast.mercyWindowSavedStance
    mercy.endYield(Cast.mercyWindowSnapshot)
    Cast.mercyWindowActive        = false
    Cast.mercyWindowStage         = 'idle'
    Cast.mercyWindowSnapshot      = nil
    Cast.mercyWindowSavedStance   = nil
    Cast.mercyWindowLocal         = false
    Cast.mercyWindowRestoreStance = false
    Cast.mercyWindowStartedAt     = 0.0
    Cast.mercyWindowUntil         = 0.0
    Cast.mercyWindowCooldownUntil = core.getSimulationTime() + Cfg.mercyWindowCooldown
    -- Restore Mercy's visual posture immediately; its next update would do it
    -- anyway, but a one-frame Weapon flash after the cast looks wrong. Never
    -- restore over a real vanilla cast or an OSSC cast still in flight.
    if restoreStance and savedStance == STANCE.Spell and not Cast.isCasting
        and not Combat.realVanillaSpellcastActive() then
        types.Actor.setStance(self, STANCE.Spell)
    end
    -- A local takeover keeps the actor in Weapon stance and keeps the engine
    -- spell list hidden; do not let a stale pause grace restore the bare Spell
    -- posture we just took over.
    if wasLocal then
        Cast.externalPauseGraceUntil = 0.0
        Cast.mercyVanillaCastUntil = 0.0
        Cast.spellStanceSince = 0.0
        if types.Actor.getStance(self) == STANCE.Spell then
            if isEngineAttackInputHeld() then releaseEngineAttack() end
            types.Actor.clearSelectedCastable(self)
            types.Actor.setStance(self, STANCE.Weapon)
        end
    end
    debugLogf('OSSC quick-cast window closed (%s, %s)', tostring(reason),
        wasLocal and 'local takeover' or 'Mercy yield')
end

function Combat.maybeBeginMercyWindow(now, target)
    if not Cfg.mercyQuickcastWindow then return end
    if Cast.mercyWindowActive or Cast.isCasting or not target then return end
    if now < Cast.mercyWindowCooldownUntil then return end
    -- The weapon is still coming out after the last takeover: yielding Mercy
    -- now would just make the actor cast mid-draw, which is the thing the
    -- readiness delay exists to prevent.
    if Combat.equipReadinessPending(now) then return end
    -- Do not interrupt Mercy more often than OSSC's normal tactical poll.
    if now < Cast.nextActionTime then return end
    if Combat.realVanillaSpellcastActive() then return end
    -- The engine is owed vanilla casts: do not borrow the body for a
    -- quick-cast it is about to use itself.
    if Combat.vanillaCastAllowanceActive(now) then return end
    if not Combat.onlyMercyPauses() then return end
    -- A stale grace from an older arm must not veto the very window that is
    -- meant to clear it. An active real vanilla cast cycle still returns above.
    if mercyVanillaCastActive(now) or externalPauseGraceActive(now) then
        return
    end
    local stance = types.Actor.getStance(self)
    local posture = stance == STANCE.Spell
    local heldOutsideFight = Pause.suspended and Combat.onlyMercyPauses()
        and not mercy.isFightState()
    if not posture and not heldOutsideFight then return end
    -- A bare Spell posture needs Mercy to drive the actor AND the Mercy window
    -- toggle: OSSC no longer takes the posture over locally ("Take Over Bare
    -- Spell Stance" is permanently off), it only borrows the body when Mercy
    -- actually yields it. A NO_STATE / non-driving Mercy therefore leaves the
    -- posture alone.
    if posture and not Cfg.mercyDriving then return end
    local snapshot = mercy.beginYield()
    -- No yield, no window: a local takeover of the engine's Spell stance is
    -- exactly what the removed setting used to allow. Never force the stance
    -- over a posture OSSC was not given.
    if snapshot == nil then return end
    local localWindow = false
    Cast.mercyWindowActive        = true
    Cast.mercyWindowStage         = 'prepare'
    Cast.mercyWindowSnapshot      = snapshot
    Cast.mercyWindowSavedStance   = stance
    Cast.mercyWindowLocal         = localWindow
    Cast.mercyWindowRestoreStance = (snapshot ~= nil)
    Cast.mercyWindowStartedAt     = now
    Cast.mercyWindowUntil         = now + Cfg.mercyWindowPrepareTimeout
    debugLogf('OSSC quick-cast window opened (%s, %s, combat state=%s)',
        tostring(stance), localWindow and 'local takeover' or 'Mercy yield',
        snapshot and tostring(snapshot.combatState) or 'none')
end

function Combat.updateMercyWindow(now)
    if not Cast.mercyWindowActive then return end
    if now > Cast.mercyWindowUntil then
        Combat.endMercyWindow('window expired')
        return
    end
    -- A local takeover has no Mercy state to maintain; it simply reasserts
    -- Weapon stance below. A Mercy yield must be re-applied every frame.
    if not Cast.mercyWindowLocal and not mercy.maintainYield() then
        Combat.endMercyWindow('Mercy driver gone')
        return
    end
    if not Combat.onlyMercyPauses() then
        Combat.endMercyWindow('external pause appeared')
        return
    end
    if Cast.mercyWindowStage ~= 'casting' and Combat.realVanillaSpellcastActive() then
        Combat.endMercyWindow('real vanilla cast appeared')
        return
    end
    if Cast.mercyWindowStage == 'prepare' then
        -- setStance is ignored while an attack/spell input is held. Clear the
        -- stale selected castable too: Spell stance was armed by that castable
        -- and the local takeover must not leave it selected for the engine AI.
        if types.Actor.getStance(self) == STANCE.Spell then
            if isEngineAttackInputHeld() then releaseEngineAttack() end
            types.Actor.clearSelectedCastable(self)
            types.Actor.setStance(self, STANCE.Weapon)
        end
        if types.Actor.getStance(self) ~= STANCE.Spell then
            Cast.mercyWindowStage = 'armed'
            -- The stance flip above IS the weapon draw. Wait for the weapon to
            -- come out before casting, and keep the window open for that wait
            -- plus the usual evaluation grace — otherwise the armed deadline
            -- (0.35 s) would expire while the draw is still playing and the
            -- window would close without ever casting.
            Combat.noteWeaponTakeover(now)
            Cast.mercyWindowUntil = math.max(now + Cfg.mercyWindowArmedTimeout,
                Cast.equipReadyUntil + Cfg.mercyWindowArmedTimeout)
            -- Evaluate as soon as the weapon is out: the normal poll interval
            -- is longer than the window's prepare phase.
            Cast.nextActionTime = 0.0
            debugLog('OSSC quick-cast window armed — Weapon stance, waiting for the draw')
        elseif now - Cast.mercyWindowStartedAt > Cfg.mercyWindowPrepareTimeout then
            Combat.endMercyWindow('stance switch timed out')
        end
    elseif Cast.mercyWindowStage == 'casting' then
        if not Cast.isCasting then
            Combat.endMercyWindow('cast finished')
        elseif types.Actor.getStance(self) == STANCE.Spell then
            if isEngineAttackInputHeld() then releaseEngineAttack() end
            types.Actor.clearSelectedCastable(self)
            types.Actor.setStance(self, STANCE.Weapon)
        end
    end
end

--- Player-script parity (ossc_player.shouldPreserveLightAttackBones): while a
--- 1H / H2H / thrown swing is playing — or a 1H charge is held and parked on
--- its "min attack" / "max attack" text key — the quickcast must claim only
--- LeftArm. Taking RightArm/Torso makes OpenMW give both animations a fight
--- over the same bones: the weapon attack stops and the quickcast can vanish
--- entirely, leaving just VFX. Heavy weapons keep the full upper-body mask.
function Combat.shouldPreserveLightAttackBones(now)
    if playingGroup(Combat.LIGHT_GROUPS) then return true end
    if getExcludedWeaponGroup() ~= nil then return false end
    if now < Cast.lightChargeUntil then return true end
    -- ATTACK_TYPE has no 'Attack' key — OpenMW's enum is NoAttack=0, Any=1,
    -- Chop=2, Slash=3, Thrust=4. Reading .Attack raised "Key not found:
    -- Attack" inside prepareCastPlayOptions and aborted the whole quick-cast.
    -- Any use value other than NoAttack is a held or chained attack, which is
    -- exactly what the player script's isAttackUseHeld() check means here.
    return isEngineAttackInputHeld()
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
    if not settingOr(Cfg.general, 'BlockDuringNGardeParry', true) then return false end
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
Cast.ngardeParryControlActive = false

local function setNgardeParryControl(active)
    local settingOn = settingOr(Cfg.general, 'BlockDuringNGardeParry', true)
    active = (active == true) and (settingOn and true or false)
    local fencer = I.NGardeFencer
    if fencer and type(fencer.externalParryControl) == 'function' then
        if active and type(fencer.forceLowerGuard) == 'function' then
            fencer.forceLowerGuard()
        end
        fencer.externalParryControl(active)
        Cast.ngardeParryControlActive = active
        debugLog('NGarde parry control ' .. (active and 'engaged' or 'released'))
    else
        Cast.ngardeParryControlActive = false
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
    -- ── Weapon draw (equip) tracking ──
    -- A 2H draw and a 2H attack are the SAME animation group; the keys say
    -- which one is playing. 'equip start' / 'equip attach' mark the draw (the
    -- engine attaches the weapon mesh on the attach key), 'equip stop' /
    -- 'unequip detach' close it. Never cancel a group while it is drawing:
    -- that is how an actor ends up swinging an equipped but invisible weapon.
    if k:find('equip', 1, true) then
        if k:find('start', 1, true) or k:find('attach', 1, true) then
            castRules.noteDraw(Cast.drawTracker, groupname)
        elseif k:find('stop', 1, true) or k:find('detach', 1, true) then
            castRules.clearDraw(Cast.drawTracker, groupname)
        end
    end
    if isChargeKey(k) then
        local chargeUntil = core.getSimulationTime() + Anim.chargeHoldWindow
        if Combat.LIGHT_GROUP_SET[groupname] then
            -- A 1H charge is a blend hint, not a cast veto.
            Cast.lightChargeUntil = chargeUntil
        else
            Cast.chargeUntil = chargeUntil
        end
        debugLog('Attack charge hold detected: ' .. tostring(groupname) .. ' / ' .. tostring(key))
        return
    end
    if k:find('release', 1, true) or k:find('min hit', 1, true)
        or k:find('follow', 1, true) or k:find('stop', 1, true) then
        Cast.chargeUntil = 0
        Cast.lightChargeUntil = 0
    end
end

-- BlockDuringCombatAnims: no quick-cast while a shield block, two-handed
-- attack or bow/crossbow shot plays, or while an attack charge is held.
local function combatAnimBlocksCast(now)
    if not settingOr(Cfg.general, 'BlockDuringCombatAnims', false) then return false end
    local group = playingGroup(Combat.ANIM_GROUPS)
    if group then
        debugLog('Cast blocked — combat animation playing: ' .. group)
        return true
    end
    if now < Cast.chargeUntil then
        debugLog('Cast blocked — attack charge is being held')
        return true
    end
    return false
end

-- ── Cast VFX ───────────────────────────────────────────────────────────────
Cast.vfxOptions = { loop = false, vfxId = nil, boneName = nil, particleTextureOverride = nil }
Cast.vfxSeen = {}

local function clearTable(t)
    for k in pairs(t) do t[k] = nil end
end

local function addCastStaticVfx(boneName, vfxId)
    clearTable(Cast.vfxSeen)
    for i, effect in ipairs(Cast.currentSpell.effects) do
        local mgef = effectRecords[effect.id]
        local static = mgef and mgef.castStatic and types.Static.records[mgef.castStatic]
        local model = static and static.model
        if model and model ~= '' and not Cast.vfxSeen[model] then
            Cast.vfxSeen[model] = true
            Cast.vfxOptions.vfxId = vfxId .. '_' .. i
            Cast.vfxOptions.boneName = boneName
            Cast.vfxOptions.particleTextureOverride = nil
            anim.addVfx(self, model, Cast.vfxOptions)
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
    clearTable(Cast.vfxSeen)
    for i, effect in ipairs(Cast.currentSpell.effects) do
        local mgef = effectRecords[effect.id]
        -- An effect whose cast static is a real record with no model has
        -- declared "no cast mesh" (drawn another way, e.g. by BeamFX):
        -- the hand swirl substitutes for a *missing* cast visual, and
        -- this one is missing on purpose, so do not substitute.
        local castStatic = mgef and mgef.castStatic and types.Static.records[mgef.castStatic]
        local castSuppressed = castStatic ~= nil
            and (castStatic.model == nil or castStatic.model == '')
        if mgef and not castSuppressed then
            local texture = mgef.particle
            if not texture or texture == '' or texture:find('blank', 1, true) then texture = 'vfx_starglow.tga' end
            if not Cast.vfxSeen[texture] then
                Cast.vfxSeen[texture] = true
                Cast.vfxOptions.vfxId = 'OSSC_HandSwirl_' .. i
                Cast.vfxOptions.boneName = 'Bip01 L Hand'
                Cast.vfxOptions.particleTextureOverride = texture
                anim.addVfx(self, 'meshes/magichand/spellvfx.nif', Cast.vfxOptions)
            end
        end
    end
end

local function addHandGlowVfx()
    -- Same biped contract as addHandSwirlVfx: no hand bone, no hand glow.
    if not IS_BIPED then return end
    if type(anim.hasBone) == 'function' and not anim.hasBone(self, 'Bip01 L Hand') then return end
    local effect = Cast.currentSpell.effects[1]
    local mgef = effect and effectRecords[effect.id]
    local static = mgef and mgef.castStatic and types.Static.records[mgef.castStatic]
    if not static or not static.model or static.model == '' then return end
    Cast.vfxOptions.vfxId = 'OSSC_HandGlow'
    Cast.vfxOptions.boneName = 'Bip01 L Hand'
    Cast.vfxOptions.particleTextureOverride = nil
    anim.addVfx(self, static.model, Cast.vfxOptions)
end

-- The same three VFX toggles that gate the player's cast effects.
local function addSpellVfx()
    local swirls = settingOr(Cfg.keys, 'EnablePlayerSwirls', true)
    local hands  = settingOr(Cfg.keys, 'EnableHandSwirls', true)
    local glow   = settingOr(Cfg.keys, 'EnableCastGlow', false)
    Cast.hasActiveVfx = swirls or hands or glow
    if swirls then addCastStaticVfx(nil, 'OSSC_ActorSwirl') end
    if hands then addHandSwirlVfx() end
    if glow then addHandGlowVfx() end
end

local function stopAllVfx()
    if not Cast.hasActiveVfx then return end
    Cast.hasActiveVfx = false
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

-- ── Engine spell list (combat loophole) ──
-- Castable spells are hidden from the engine AI while OSSC drives casting.
local function isCastableSpellType(record)
    if record == nil then return false end
    if record.type == SPELL_TYPE.Spell then return true end
    return record.type == SPELL_TYPE.Power and Cfg.allowPowers == true
end

local function knownSpellCount()
    local n = 0
    for _ in pairs(Cast.knownSpells) do n = n + 1 end
    return n
end

--- Cache castable spells from an Actor.spells() collection. Use the shared
--- entry decoder: the list can contain records, plain id strings or be keyed
--- by id, depending on the OpenMW build and on which mod last wrote to it.
--- Returns how many NEW spells were learned, so a late/deferred spell add can
--- be discovered even after the script attached.
local function cacheCastableSpells(actorSpells)
    local added = 0
    local function remember(spellId)
        local record = spellId and spellRecords[spellId] or nil
        if record and isCastableSpellType(record)
            and Cast.knownSpells[spellId] == nil then
            Cast.knownSpells[spellId] = true
            Cast.knownSpellsDirty = true
            added = added + 1
        end
    end
    for key, value in pairs(actorSpells) do
        remember(casterUtils.spellIdFromEntry(key, value))
    end
    -- A read-only iterable can expose its records through numeric indexing
    -- while pairs() only reports its methods / keys. Plain reads, no pcall:
    -- an engine list that raises while being indexed is a real error and must
    -- surface instead of quietly leaving the actor spell-less.
    if type(actorSpells) == 'table' then
        for i = 1, #actorSpells do
            remember(casterUtils.spellIdFromEntry(i, actorSpells[i]))
        end
    end
    if added > 0 then
        debugLogf('Spell cache: discovered %d new castable spell(s)', added)
    end
    return added
end

--- Reconcile the cache with the live engine spell list. Critically this does
--- NOT early-return while spells are stripped: Mercy CAO and other mods add
--- spells at combat start with deferred add() calls that can land after
--- onInit. An empty cache marked "stripped" used to stay empty for the whole
--- fight, because no later pass was ever allowed to read Actor.spells().
local function updateKnownSpellsCache()
    if IS_SPELL_VENDOR then return end
    local actorSpells = types.Actor.spells(self)
    local added = cacheCastableSpells(actorSpells)
    if added > 0 and Cast.spellsTemporarilyRemoved and not Pause.suspended then
        -- Keep the engine list hidden while OSSC owns casting; re-queue the
        -- idempotent removes for everything that appeared mid-fight.
        for spellId in pairs(Cast.knownSpells) do
            if spellRecords[spellId] then actorSpells:remove(spellId) end
        end
    end
end

local function removeAllCastableSpells()
    if IS_SPELL_VENDOR or Cast.spellsTemporarilyRemoved then return end
    local actorSpells = types.Actor.spells(self)
    cacheCastableSpells(actorSpells)
    -- add/remove apply at frame end, so the map may still report the old
    -- contents during this callback. Both operations are idempotent; queue
    -- every known spell with a live record, and forget records a mod removed.
    local toStrip = {}
    for spellId in pairs(Cast.knownSpells) do
        if spellRecords[spellId] then
            toStrip[#toStrip + 1] = spellId
        else
            Cast.knownSpells[spellId] = nil
            Cast.knownSpellsDirty = true
        end
    end
    -- Nothing to hide yet (deferred spell adds, a spell-less mod-driven
    -- caster, or an Actor.spells() representation we could not decode): do
    -- NOT mark the list stripped and do NOT clear the selected castable. The
    -- periodic cache refresh below will pick the spells up when they appear.
    if #toStrip == 0 then
        Cast.spellsTemporarilyRemoved = false
        return
    end
    types.Actor.clearSelectedCastable(self)
    for i = 1, #toStrip do actorSpells:remove(toStrip[i]) end
    Cast.spellsTemporarilyRemoved = true
    debugLogf('Combat Loophole: Stripped %d castable spells from engine AI (Passives kept)', #toStrip)
end

local function restoreAllCastableSpells()
    if not Cast.spellsTemporarilyRemoved then return end
    local actorSpells = types.Actor.spells(self)
    local count = 0
    for spellId in pairs(Cast.knownSpells) do
        -- Presence queries can be stale until deferred add/remove operations
        -- apply. Queue an idempotent add for every record OSSC still knows.
        if spellRecords[spellId] then
            actorSpells:add(spellId)
            count = count + 1
        else
            Cast.knownSpells[spellId] = nil
            Cast.knownSpellsDirty = true
        end
    end
    Cast.spellsTemporarilyRemoved = false
    debugLogf('Combat Loophole: Restored %d spells to engine', count)
end

-- ── Vanilla-cast allowance ─────────────────────────────────────────────────
-- Restoring the engine spell list is not the same as letting the engine cast.
-- Mercy CAO pauses OSSC when it wants a vanilla spell, restores the list, and
-- then releases the pause — often a fraction of a second before the engine
-- presses its cast input. Stripping the list on the first update after that
-- release killed exactly the cast OSSC had just made possible, which is why
-- vanilla casting looked broken. The allowance is a cast COUNT rather than a
-- timer: after such a release the engine may COMPLETE N vanilla casts before
-- OSSC takes the list back. While an allowance is open OSSC keeps its hands
-- off stance, selected castable and spell list, and holds quick-casts. Once
-- the budget is spent (or NPCVanillaCastAllowanceTimeout runs out for the cast
-- in progress) OSSC re-strips the list and both modes can alternate again.

--- Why the open allowance is not holding OSSC back any more, or nil while it
--- still is. Kept separate so the close log can name the real reason.
---   'budget spent'  — the engine used every allowed vanilla cast
---   'timed out'     — no SpellCast Unequip Stop / cast key within the timeout
---   'not readied'   — the engine never even entered Spell stance
function Combat.vanillaCastAllowanceStopReason(now)
    if not Cast.vanillaCastAllowanceArmed then return nil end
    now = now or core.getSimulationTime()
    -- OSSC owns the spell list: quick-cast mode, nothing is owed to the engine.
    if Combat.osscOwnsSpellList() then return 'spell list stripped by OSSC' end
    -- A cast already in flight always finishes on its own handshake.
    if vanillaSpellcast.cyclePending(Cast) then return nil end
    if Cast.vanillaCastsLeft <= 0 then return 'budget spent' end
    local deadline = Cast.vanillaCastAllowanceUntil
    if deadline ~= 0.0 and now > deadline then return 'timed out' end
    -- The engine must SELECT a spell before it can cast one, which puts it in
    -- Spell stance. A budget that is still untouched and has not produced even
    -- that much is not going to be used: OSSC takes the list back instead of
    -- waiting out the whole timeout. Mercy CAO releases its pause around every
    -- routine it runs, so without this the actor was permanently inside a
    -- fresh allowance and never quick-cast while Mercy was not driving it.
    if not Cast.vanillaCastAllowanceSawSpellStance then
        local readiness = tonumber(Cfg.vanillaCastAllowanceReadiness) or 0
        if readiness > 0
            and now - Cast.vanillaCastAllowanceArmedAt >= readiness then
            return 'not readied'
        end
    end
    return nil
end

--- True while OSSC owes the engine vanilla casts and must stay out of the way.
function Combat.vanillaCastAllowanceActive(now)
    if not Cast.vanillaCastAllowanceArmed then return false end
    now = now or core.getSimulationTime()
    -- Remember that the engine readied magic: from then on the budget is
    -- genuinely live and only its deadline / the cast keys end it.
    if not Cast.vanillaCastAllowanceSawSpellStance
        and types.Actor.getStance(self) == STANCE.Spell then
        Cast.vanillaCastAllowanceSawSpellStance = true
    end
    return Combat.vanillaCastAllowanceStopReason(now) == nil
end

--- Remaining vanilla casts (diagnostics).
function Combat.vanillaCastsRemaining()
    if not Cast.vanillaCastAllowanceArmed then return 0 end
    return Cast.vanillaCastsLeft
end

--- Spell ids the engine is currently able to cast from. Deferred add()/remove()
--- operations mean this can lag a frame behind, so it is only used to decide
--- whether an idempotent add() still needs to be queued.
local function currentEngineSpellIds()
    local ids, actorSpells = {}, types.Actor.spells(self)
    if not actorSpells then return ids end
    local function remember(spellId)
        if spellId then ids[spellId] = true end
    end
    for key, value in pairs(actorSpells) do
        remember(casterUtils.spellIdFromEntry(key, value))
    end
    if type(actorSpells) == 'table' then
        for i = 1, #actorSpells do
            remember(casterUtils.spellIdFromEntry(i, actorSpells[i]))
        end
    end
    return ids
end

--- Queue an add() for every spell of `wanted` the engine list does not show
--- yet. add() is idempotent and applies at frame end, so a stale read can only
--- cost a redundant call. Returns how many were queued.
local function addMissingSpells(wanted)
    if not wanted or next(wanted) == nil then return 0 end
    local actorSpells = types.Actor.spells(self)
    if not actorSpells then return 0 end
    local present = currentEngineSpellIds()
    local queued = 0
    for spellId in pairs(wanted) do
        if spellRecords[spellId] and not present[spellId] then
            actorSpells:add(spellId)
            queued = queued + 1
        end
    end
    return queued
end

--- Hand the actor's castable spells to the engine for the window that is open
--- right now: undo an OSSC strip first, then put back anything else that is
--- missing. Safe to call every frame (it is a no-op when the list already has
--- what the engine needs).
--- `force` re-checks the live list even when OSSC believes nothing is
--- stripped; the cheap flag-only pass is used on the frames in between.
function Combat.handVanillaCastSpells(now, force)
    local restored, queued = 0, 0
    if Cast.spellsTemporarilyRemoved then
        restoreAllCastableSpells()
        restored = 1
    end
    if force or restored > 0 then
        queued = addMissingSpells(Cast.vanillaCastSpellIds)
    end
    Cast.vanillaCastEnsureAt = (now or core.getSimulationTime()) + 0.5
    return restored + queued
end

--- Keep the engine's spell list complete for as long as the window lasts.
function Combat.ensureVanillaCastSpells(now)
    if not Cast.vanillaCastAllowanceArmed then return end
    now = now or core.getSimulationTime()
    if not Combat.vanillaCastAllowanceActive(now) then return end
    -- Fast path every frame: an OSSC strip is undone immediately.
    if Cast.spellsTemporarilyRemoved then
        Combat.handVanillaCastSpells(now, false)
        return
    end
    -- Slow path (2 Hz): a mod's clear, or a deferred remove that landed after
    -- the hand-back, is repaired without waiting for the next pause.
    if now >= Cast.vanillaCastEnsureAt then
        local queued = Combat.handVanillaCastSpells(now, true)
        if queued > 0 then
            debugLogf('Vanilla cast window: re-added %d spell(s) to the actor '
                .. 'for the engine (%d owed vanilla cast(s) left)',
                queued, Cast.vanillaCastsLeft)
        end
    end
end

--- Roll the number of vanilla casts this hand-back allows.
--- NPCVanillaCastsAllowedMin == NPCVanillaCastsAllowedMax pins the rate;
--- min < max varies it per hand-back, so the actor does not always alternate
--- in the same rhythm. 0/0 (or a roll of 0) means "no vanilla casts this
--- time" and OSSC keeps the spell list.
function Combat.rollVanillaCastsAllowed()
    local lo = math.floor(tonumber(Cfg.vanillaCastsAllowedMin) or 0)
    local hi = math.floor(tonumber(Cfg.vanillaCastsAllowedMax) or lo)
    if lo < 0 then lo = 0 end
    if hi < lo then hi = lo end
    if hi <= 0 then return 0 end
    if lo == hi then return lo end
    return math.random(lo, hi)
end

--- Arm the allowance. Only ever called on a pause RELEASE: while another mod
--- still holds a pause the engine has not been handed anything yet, and an
--- OSSC quick-cast window is its own negotiated handshake, not a vanilla cast.
function Combat.armVanillaCastAllowance(reason)
    if Cast.mercyWindowActive then return false end
    -- OSSC's own quick-cast is still on screen. Nothing was handed to the
    -- engine for it, and arming a budget here would stand OSSC down for a
    -- cast it just made itself — Mercy's hold lifting mid-gesture is not a
    -- hand-back. The next real release arms the allowance as usual.
    if Cast.isCasting then
        debugLogf('Vanilla cast allowance NOT armed (%s) — OSSC quick-cast '
            .. 'still in flight', tostring(reason))
        return false
    end
    if Pause.suspended or Pause.detachPending then return false end
    if next(Pause.reasons) ~= nil then return false end
    if knownSpellCount() == 0 then return false end
    -- OSSC still owns the list, so nothing was handed back: quick-cast mode.
    if Combat.osscOwnsSpellList() then return false end
    local now0 = core.getSimulationTime()
    -- NEVER re-roll or extend a budget that is still open. Mercy CAO releases
    -- its pause around every routine it runs, and each of those releases used
    -- to push the deadline forward, so the gate never opened and the actor
    -- stopped quick-casting altogether even though Mercy was not driving it.
    -- The open budget keeps its own deadline and its own remaining casts; only
    -- a genuinely new hand-back (the old budget spent or expired) starts fresh.
    if Cast.vanillaCastAllowanceArmed
        and Combat.vanillaCastAllowanceStopReason(now0) == nil then
        -- Keep the hand-back to the engine, but leave the budget alone. The
        -- list is re-asserted; the deadline and the remaining casts are not.
        Combat.ensureVanillaCastSpells(now0)
        return false
    end
    -- Roll only when the hand-back is real, so a refused release never eats a
    -- draw from the shared math.random stream.
    local allowed = Combat.rollVanillaCastsAllowed()
    if allowed <= 0 then return false end
    local now = core.getSimulationTime()
    local timeout = tonumber(Cfg.vanillaCastAllowanceTimeout) or 0
    Cast.vanillaCastAllowanceArmed = true
    Cast.vanillaCastsLeft          = allowed
    Cast.vanillaCastsRolled        = allowed
    Cast.vanillaCastsDone          = 0
    Cast.vanillaCastAllowanceUntil = timeout > 0 and (now + timeout) or 0.0
    Cast.vanillaCastAllowanceArmedAt = now
    -- The engine may have readied magic while it was paused (that is exactly
    -- what a Mercy vanilla cast looks like), so a release from Spell stance
    -- starts the budget already "readied".
    Cast.vanillaCastAllowanceSawSpellStance =
        types.Actor.getStance(self) == STANCE.Spell
    -- Snapshot the exact castables this window owes the engine, then ADD them
    -- back. A stripped list (OSSC held the spells for its own quick-casts) is
    -- the normal case here — that is precisely what must be handed back — so
    -- it is not a reason to refuse the window.
    Cast.vanillaCastSpellIds = {}
    local owed = 0
    for spellId in pairs(Cast.knownSpells) do
        if spellRecords[spellId] then
            Cast.vanillaCastSpellIds[spellId] = true
            owed = owed + 1
        end
    end
    local wasStripped = Cast.spellsTemporarilyRemoved
    Cast.vanillaCastEnsureAt = 0.0
    local queued = Combat.handVanillaCastSpells(now, true)
    debugLogf('Vanilla cast allowance armed (%s) — %d castable spell(s) handed '
        .. 'to the engine%s (%d add() queued), it may finish %d vanilla cast(s) '
        .. '(rolled from %d-%d) before OSSC re-strips the spell list',
        tostring(reason), owed,
        wasStripped and ' (list was stripped by OSSC)' or '', queued,
        Cast.vanillaCastsLeft,
        Cfg.vanillaCastsAllowedMin, Cfg.vanillaCastsAllowedMax)
    return true
end

--- Close the allowance. Bookkeeping only: the caller (or the ordinary strip
--- guard on the next update) hands the spell list back to OSSC.
function Combat.closeVanillaCastAllowance(reason)
    if not Cast.vanillaCastAllowanceArmed then return end
    Cast.vanillaCastAllowanceArmed = false
    Cast.vanillaCastsLeft          = 0
    Cast.vanillaCastsRolled        = 0
    Cast.vanillaCastAllowanceUntil = 0.0
    Cast.vanillaCastSpellIds       = nil
    Cast.vanillaCastEnsureAt       = 0.0
    Cast.vanillaCastAllowanceArmedAt        = 0.0
    Cast.vanillaCastAllowanceSawSpellStance = false
    debugLogf('Vanilla cast allowance closed (%s) — OSSC owns the spell list again',
        tostring(reason))
end

--- Spend one unit of budget for a cast cycle that just opened, and restart the
--- per-cast deadline for the next one.
function Combat.spendVanillaCastAllowance()
    if not Cast.vanillaCastAllowanceArmed then return false end
    if Cast.vanillaCastsLeft <= 0 then return false end
    Cast.vanillaCastsLeft = Cast.vanillaCastsLeft - 1
    Cast.vanillaCastsDone = Cast.vanillaCastsDone + 1
    -- The engine provably used the list, so the rest of the budget is live:
    -- the readiness grace must never cut a multi-cast hand-back short.
    Cast.vanillaCastAllowanceSawSpellStance = true
    local timeout = tonumber(Cfg.vanillaCastAllowanceTimeout) or 0
    if timeout > 0 then
        Cast.vanillaCastAllowanceUntil = core.getSimulationTime() + timeout
    end
    debugLogf('Vanilla cast %d started — %d more allowed before OSSC re-strips',
        Cast.vanillaCastsDone, Cast.vanillaCastsLeft)
    return true
end

--- A real vanilla cast key means another system (Mercy CAO, the engine AI,
--- or a mod) temporarily re-added the actor's spells so the engine could cast
--- them. OSSC must not strip them while that cycle is running. `newCycle` is
--- true only for the key that opened the cycle, so an open allowance spends
--- exactly one unit per vanilla cast rather than one per key.
function Combat.beginVanillaCastCycle(kind, key, newCycle)
    restoreAllCastableSpells()
    Cast.spellStanceSince = 0.0
    if newCycle then Combat.spendVanillaCastAllowance() end
    debugLogf('Vanilla cast cycle started (%s: %s) — engine spells restored, '
        .. 'quick-casts held until SpellCast Unequip Stop (vanilla left=%d)',
        tostring(kind), tostring(key), Combat.vanillaCastsRemaining())
end

--- SpellCast Unequip Stop (or the fallback timeout) is the point where the
--- engine has finished with the spell list. While the allowance still owes
--- the actor vanilla casts the list stays restored; once the budget is spent
--- (or the allowance timed out) OSSC strips again and quick-casts resume.
--- Both modes then alternate indefinitely.
function Combat.endVanillaCastCycle(reason)
    Cast.spellStanceSince = 0.0
    Cast.vanillaCastTimedOut = false
    if Cast.vanillaCastAllowanceArmed and Cast.vanillaCastsLeft > 0 then
        Cast.externalPauseGraceUntil = 0.0
        Cast.mercyVanillaCastUntil = 0.0
        debugLogf('Vanilla cast cycle ended (%s) — %d more vanilla cast(s) '
            .. 'allowed, spells stay restored', tostring(reason),
            Cast.vanillaCastsLeft)
        return
    end
    Combat.closeVanillaCastAllowance('vanilla cast allowance spent')
    -- A pause still held by another mod owns the list: it restored those spells
    -- so it could drive the actor itself.
    if Pause.suspended then
        debugLogf('Vanilla cast cycle ended (%s) — engine spells kept, a mod '
            .. 'still holds this caster paused', tostring(reason))
        return
    end
    removeAllCastableSpells()
    Cast.externalPauseGraceUntil = 0.0
    Cast.mercyVanillaCastUntil = 0.0
    debugLogf('Vanilla cast cycle ended (%s) — engine spells stripped, '
        .. 'quick-casts re-armed', tostring(reason))
end

--- Safety valve for an animation set that never emits SpellCast Unequip Stop.
function Combat.expireVanillaCastCycle(now)
    if vanillaSpellcast.expireCycle(Cast, now, Cfg.vanillaCastUnequipTimeout) then
        Combat.endVanillaCastCycle('SpellCast Unequip Stop timeout')
    end
end

--- Lifecycle helper: the engine needs its own spell list while it stands in
--- vanilla Spell stance. Only strip castables when OSSC actually owns casting.
function Combat.syncSpellListWithStance()
    -- A pending real vanilla cast cycle always owns the engine spell list,
    -- even if the actor has already left Spell stance for a frame.
    if Combat.realVanillaSpellcastActive() then
        restoreAllCastableSpells()
    elseif Combat.vanillaCastAllowanceActive() then
        Combat.ensureVanillaCastSpells(nil)
    elseif Combat.vanillaSpellStanceActive() then
        restoreAllCastableSpells()
    else
        removeAllCastableSpells()
    end
end

-- Eligibility is re-checked live so settings changes apply mid-combat.
local function isActorEligible()
    if IS_SPELL_VENDOR then return false end
    if self.type == types.NPC then
        if settingOr(Cfg.npc, 'NPCQuickCastEnabled', true) then return true end
        debugLog('NPC quick-casting disabled by settings')
        return false
    end
    if self.type ~= types.Creature then return false end
    -- The master toggle gates creatures too (mirrors the global attach gate in
    -- isCasterEligible), so flipping it mid-combat stops attached creatures.
    if not settingOr(Cfg.npc, 'NPCQuickCastEnabled', true) then
        debugLog('NPC quick-casting disabled by settings (master toggle)')
        return false
    end
    if not settingOr(Cfg.npc, 'NPCQuickCastCreatures', true) then
        debugLog('Creature quick-casting disabled by settings')
        return false
    end
    if IS_BIPED_CREATURE or settingOr(Cfg.npc, 'NPCQuickCastNonBipedCreatures', true) then return true end
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
    -- canMove is also false when overencumbered; that must not block casting.
    if not types.Actor.canMove(self) and not isOverEncumbered(self) then
        debugLog('Cast blocked — canMove=false (paralyzed/knocked down)')
        return true
    end
    local silence = types.Actor.activeEffects(self):getEffect('silence')
    if silence and silence.magnitude > 0 then
        debugLog('Cast blocked — silenced')
        return true
    end
    local group = playingGroup(Combat.INCAPACITATED_GROUPS)
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
    if not Cast.attackSuppressedDuringCast then return end
    Cast.attackSuppressedDuringCast = false
    -- Never touch a vanilla spell cast: in Spell stance the held input is the
    -- engine's own cast, not a weapon attack OSSC suppressed.
    if types.Actor.getStance(self) ~= STANCE.Weapon then return end
    -- Releasing a wind-up that is actually playing would skip straight to its
    -- release section (an instant swing).
    if playingGroup(Combat.HEAVY_GROUPS) then return end
    if not isEngineAttackInputHeld() then return end
    debugLog('Re-arm: releasing the attack input this cast suppressed')
    releaseEngineAttack()
end

-- Play the school cast sound at most once per quickcast (both the cast start
-- and the animation's 'start' text key route through here).
local function playCastSoundOnce(spell)
    if Cast.castSoundPlayedForCastId == Cast.currentCastId then return end
    local effect = spell.effects[1]
    local mgef = effect and effectRecords[effect.id]
    if not mgef or not mgef.castSound or mgef.castSound == '' then return end
    Cast.castSoundPlayedForCastId = Cast.currentCastId
    core.sound.playSound3d(mgef.castSound, self)
end

Cast.snapSoundOptions = { volume = 0.45 }

local function playSnapSound()
    local volume = settingOr(Cfg.anim, 'SnapSoundVolume', 0.45)
    if volume <= 0 then return end
    Cast.snapSoundOptions.volume = volume
    core.sound.playSoundFile3d('sound/ossc/qcsnap.mp3', self, Cast.snapSoundOptions)
end

local function cleanupCast(reason)
    debugLog('Cleanup cast: ' .. tostring(reason))
    if Cast.ngardeParryControlActive then setNgardeParryControl(false) end
    stopAllVfx()
    -- A ready / unready that was running under this cast is NOT cancelled: the
    -- engine owns that transition and the weapon still has to attach (or
    -- detach) its mesh. Only the memory of it expires on its own.
    -- A vanilla Spell stance appearing mid-cast means the engine's own
    -- gesture must own the upper body. Cancel the blended quickcast group as
    -- well as its VFX; otherwise its text-key timers can still fire and its
    -- bones keep competing with the vanilla spellcast animation.
    local castGroup = Cast.currentAnimGroup
    -- Also when another mod pauses this caster: the pause hands the actor (and
    -- its upper body) to whoever asked for it — usually a vanilla cast — so the
    -- blended quickcast group must not keep playing over it.
    local yieldsAnimation = reason == 'vanilla spell stance'
        or reason == 'vanilla cast cycle started'
        or tostring(reason):find('^paused') ~= nil
    if yieldsAnimation and castGroup and type(anim.cancel) == 'function' then
        anim.cancel(self, castGroup)
        debugLog('Cancelled cast animation group: ' .. castGroup)
    end
    Cast.isCasting = false
    Cast.hasFiredThisCast = false
    Cast.currentSpell = nil
    Cast.currentAnimGroup = nil
    Cast.aimTarget = nil
    Cast.deadline = 0.0
    Cast.isBound2HWeaponCast = false
    Cast.mercyCast = false
    restoreShieldAfterCast()
    rearmSuppressedAttack()
    -- Every exit from a cast returns the body to Mercy: normal finish, a
    -- watchdog, incapacitation, a pause, or a real vanilla stance appearing.
    Combat.endMercyWindow('cast cleanup: ' .. tostring(reason))
    -- A Mercy hold that arrived during this cast was deferred so the gesture
    -- could finish; honour it now that the body is free again. The reason is
    -- cleared first: Pause.set may call back into cleanupCast for another
    -- reason and this must never recurse.
    local deferredMercyPause = Cast.mercyPauseDeferred
    Cast.mercyPauseDeferred = nil
    if deferredMercyPause then
        debugLogf('Applying the Mercy pause that waited for the cast (%s)',
            tostring(deferredMercyPause))
        Pause.set(true, deferredMercyPause)
    end
end

local function resetAfterActivation(reason)
    -- Session state never survives a save/load. If a window was open when the
    -- save was made, Mercy's yielded combat trees must come back immediately.
    Combat.endMercyWindow('activation reset: ' .. tostring(reason))
    -- Nor does the invisible-and-seen hold: Mercy's attack trees must never
    -- stay switched off after a save/load, a cell change or a detach.
    if Cast.hiddenHold or Cast.hiddenHoldYielding then mercy.endHiddenHold() end
    Cast.hiddenHold         = false
    Cast.hiddenHoldYielding = false
    Cast.hiddenSeen         = false
    Cast.hiddenThreat       = nil
    Cast.nextRetreatAt      = 0.0
    Cast.nextHiddenCheck    = 0.0
    Cast.lastIncomingHitAt  = nil
    Cast.nextReactionAt     = 0.0
    -- A text-key hold is session state: a save / cell re-entry must not keep
    -- the actor stood down for a cast that no longer exists.
    vanillaSpellcast.reset(Cast)
    Cast.spellStanceSince = 0.0
    Cast.currentCastId = Cast.currentCastId + 1
    stopAllVfx()
    Cast.mercyPauseDeferred = nil
    Cast.isCasting = false
    Cast.hasFiredThisCast = false
    Cast.currentSpell = nil
    Cast.currentAnimGroup = nil
    Cast.deadline = 0.0
    Cast.isBound2HWeaponCast = false
    restoreShieldAfterCast()
    Cast.attackSuppressedDuringCast = false
    Cast.nextActionTime = 0.0
    Cast.nextCastAllowedTime = 0.0
    Cast.nextBuffAllowedTime = 0.0
    Cast.comboTargetKey, Cast.comboUntil = nil, 0.0
    for tag in pairs(Cast.comboTags) do Cast.comboTags[tag] = nil end
    -- A (re)load wipes all unsavable timers, so any pending detach suspension
    -- is stale — self-heal back to normal casting.  External pauses are
    -- session state as well: the requesting mod asks again after the load.
    Pause.detachPending = false
    Pause.reasons = {}
    Pause.refresh()
    Cast.mercyVanillaCastUntil = 0.0
    Cast.externalPauseGraceUntil = 0.0
    Cast.pendingTimersUntil = 0.0
    -- The weapon draw OSSC started is gone with the session: a save made
    -- between the stance flip and the first cast must not hold the actor.
    Cast.equipReadyUntil = 0.0
    Cast.equipArmed = false
    -- The vanilla-cast allowance is session state too: a save / cell re-entry
    -- must not leave the actor stood down for casts that no longer exist.
    Cast.vanillaCastAllowanceArmed = false
    Cast.vanillaCastsLeft          = 0
    Cast.vanillaCastsRolled        = 0
    Cast.vanillaCastsDone          = 0
    Cast.vanillaCastAllowanceUntil = 0.0
    Cast.vanillaCastSpellIds       = nil
    Cast.vanillaCastEnsureAt       = 0.0
    Cast.vanillaCastAllowanceArmedAt        = 0.0
    Cast.vanillaCastAllowanceSawSpellStance = false
    -- External NGarde control is transient engine state: a save made mid-cast
    -- must never keep guards locked after the load. Unconditional — the
    -- lifecycle reset always leaves the guard released.
    setNgardeParryControl(false)
    Cast.reentryGuardUntil = core.getSimulationTime() + Anim.reentryGuardDuration
    -- Never clear the engine's selected castable or take its Spell stance
    -- away on activation: that is a vanilla cast in progress. The onUpdate
    -- stand-down keeps OSSC out of the engine's way until the stance drops.
    if not Combat.vanillaSpellStanceActive() then
        types.Actor.clearSelectedCastable(self)
    end
    debugLogf('Cell re-entry reset (%s), re-entry guard %.1fs', tostring(reason), Anim.reentryGuardDuration)
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

    -- Mercy's latest request wins. A hold that was deferred for an OSSC
    -- quick-cast must never be applied after Mercy already released it: its
    -- onUpdate sends the release the moment its routine is over, which is
    -- usually well before a 1.2 s gesture ends.
    if not paused and Cast.mercyPauseDeferred ~= nil
        and (releaseAll or Cast.mercyPauseDeferred == reason) then
        Cast.mercyPauseDeferred = nil
        debugLog('Deferred Mercy pause dropped — Mercy released it first')
    end

    if paused then
        -- A stale/reasserted Mercy hold must not cancel an OSSC quick-cast
        -- window. Mercy's updateOSSCHold() reads its own state, and frame
        -- order can let it see the pre-yield combatState for one frame. The
        -- window reasserts the FIGHT snapshot below; every OTHER pause still
        -- wins and stops the cast through the normal path.
        if Cast.mercyWindowActive and isMercyPauseReason(reason) then
            mercy.maintainYield()
            return false
        end
        -- Mercy CAO has to wait for OSSC to finish its own quick-cast. Mercy
        -- re-sends this hold from its own onUpdate whenever it wants the body
        -- (an attack sequence, repositioning, a vanilla cast of its own), and
        -- a hold that landed 0.6 s into a gesture used to restore the engine
        -- spell list, cancel the blended cast animation and stand OSSC down
        -- mid-cast — the reported "cast is cut off every time Mercy swings".
        -- Hold the request instead and apply it the moment the cast ends
        -- (cleanupCast), so the actor never gets a half-played gesture and
        -- Mercy still gets the body back for its next routine.
        if Cast.isCasting and isMercyPauseReason(reason) then
            if Cast.mercyPauseDeferred ~= reason then
                debugLog('Mercy pause deferred — OSSC quick-cast in flight, '
                    .. 'Mercy waits for it to finish')
            end
            Cast.mercyPauseDeferred = reason
            return false
        end
        if Pause.reasons[reason] then return false end
        Pause.reasons[reason] = true
        Pause.refresh()
        -- Hand the engine its spell list back and stop any in-flight cast:
        -- while paused this actor is not OSSC's to drive.
        restoreAllCastableSpells()
        if Cast.isCasting then cleanupCast('paused (' .. reason .. ')') end
        debugLogf('Caster paused by %s', reason)
        return true
    end

    -- A Mercy pause released during a real vanilla cast cycle must keep the
    -- engine spell list restored past the release (Mercy's hold can lift far
    -- too soon for SpellCast Unequip Stop). A bare Spell posture, equip/idle
    -- spellcast anim or sticky selected castable does not count. onUpdate
    -- neither re-strips the spells nor takes the stance back until the cycle
    -- ends or the window lapses.
    local function armMercyVanillaCastWindow()
        if Cfg.mercyVanillaCastWindow <= 0 then return end
        -- A Mercy pause released BECAUSE OSSC opened a quick-cast window is
        -- not a queued engine cast. The Spell stance OSSC is about to swap is
        -- Mercy's posture; arming this window would protect it for seconds.
        if Cast.mercyWindowActive then return end
        if types.Actor.getStance(self) ~= STANCE.Spell then return end
        -- Same rule as armExternalPauseGrace: only an active real spellcast
        -- key window counts, not a bare Spell posture or sticky selected spell.
        if not Combat.realVanillaSpellcastActive() then return end
        Cast.mercyVanillaCastUntil = core.getSimulationTime() + Cfg.mercyVanillaCastWindow
        debugLog('Mercy pause released during a vanilla cast cycle — protecting it')
    end

    -- The resume grace (armExternalPauseGrace, NPCPauseResumeGrace) is the
    -- single "do not re-strip before the timer is off" cooldown and backs
    -- EVERY release: while paused the spells are the engine's again, so any
    -- mod, Mercy or otherwise, can leave the actor readied in Spell stance
    -- and release the pause long before the engine presses `use`, after which
    -- OSSC would otherwise re-strip the list on its very next update (the
    -- reported "spells removed instantly after unpause"). Mercy's own window
    -- above is kept exactly as it was; the two simply overlap.
    if releaseAll then
        if next(Pause.reasons) == nil then return false end
        local hadMercyReason = Pause.reasons[mercy.PAUSE_REASONS[1]] ~= nil
            or Pause.reasons[mercy.PAUSE_REASONS[2]] ~= nil
        Pause.reasons = {}
        Pause.refresh()
        if hadMercyReason then armMercyVanillaCastWindow() end
        armExternalPauseGrace()
        -- Whoever holds the pause restored the engine spell list; let the
        -- engine finish its configured number of vanilla casts before OSSC
        -- strips the list again (this is the reported "spells are removed
        -- instantly after unpause, so the NPC never vanilla casts").
        Combat.armVanillaCastAllowance('every pause released')
        debugLogf('Caster resumed: every pause released')
        return true
    end

    if not Pause.reasons[reason] then return false end
    Pause.reasons[reason] = nil
    Pause.refresh()
    if isMercyPauseReason(reason) then armMercyVanillaCastWindow() end
    armExternalPauseGrace()
    Combat.armVanillaCastAllowance('pause released: ' .. tostring(reason))
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
Cast.followTargetKey = nil

-- The leader OBJECT alongside the key: M2 ally casting aims spells at it
-- (the key stays the identity used for protection checks). nil until a
-- Follow package shows up; all reads validate the proxy first.
Cast.followObj = nil
-- M2 state: per-actor "knows spells" role cache (records are static, so a
-- key is scored at most once; the table resets past 64 entries to stay
-- bounded) and the ally-pool dirty flag (set by refreshDerived, cleared by
-- buildAllyPools after OSSCExternal exists).
Cast.casterKnows, Cast.casterKnowsN = {}, 0
Cast.allyPoolsDirty = true

-- Actors are compared by a stable key rather than by object identity: the
-- engine hands out fresh proxies for the same actor, so `==` is not reliable
-- across calls.
local function actorKey(obj)
    if not obj then return nil end
    return obj.id or obj.recordId
end

local function isFollowPackage(pkg)
    return pkg ~= nil and pkg.type == 'Follow'
end

-- Only used at init. Everything after that is driven by the package events,
-- so onUpdate never walks the AI stack.
local function scanFollowPackage()
    Cast.followTargetKey = nil
    Cast.followObj = nil
    if not (I.AI and type(I.AI.forEachPackage) == 'function') then return end
    I.AI.forEachPackage(function(pkg)
        if isFollowPackage(pkg) and pkg.target then
            Cast.followTargetKey = actorKey(pkg.target)
            Cast.followObj = pkg.target
        end
    end)
end

-- Target acquisition: the engine's Combat package list is the authoritative
-- "who this actor sees" pool. getActiveTarget() can be nil even while
-- getTargets('Combat') still reports a live target (a target-list change, a
-- different active package, or a player seen by the AI), so relying on the
-- active target alone made Target spells stop quick-casting. No free-aim
-- nearby.actors scan: only engine combat targets are candidates.
function Combat.isLiveTarget(obj)
    if not obj or obj == self or not obj.isValid or not obj:isValid() then return false end
    if obj.position == nil then return false end
    local isInstance = types.Actor.objectIsInstance
    if type(isInstance) == 'function' and not isInstance(obj) then return false end
    local isDead = types.Actor.isDead
    return not (type(isDead) == 'function' and isDead(obj))
end

function Combat.addTarget(list, seen, obj)
    if not Combat.isLiveTarget(obj) then return end
    local key = actorKey(obj) or tostring(obj)
    if seen[key] then return end
    seen[key] = true
    list[#list + 1] = obj
end

function Combat.collectTargets()
    local list, seen = Combat.targets, Combat.targetKeys
    for i = #list, 1, -1 do list[i] = nil end
    for key in pairs(seen) do seen[key] = nil end
    local ai = I.AI
    if not ai then return list end
    if type(ai.getActiveTarget) == 'function' then
        Combat.addTarget(list, seen, ai.getActiveTarget('Combat'))
    end
    if type(ai.getTargets) == 'function' then
        local targets = ai.getTargets('Combat')
        if targets then
            for _, obj in ipairs(targets) do Combat.addTarget(list, seen, obj) end
        end
    end
    if #list == 0 and type(ai.getTarget) == 'function' then
        Combat.addTarget(list, seen, ai.getTarget())
    end
    return list
end

-- Closest live engine combat target. onUpdate uses this to decide whether
-- OSSC is inside its cast range at all; evaluateCombatQuickcast then narrows
-- the same pool to visible targets.
local function getCombatTarget()
    local targets = Combat.collectTargets()
    local best, bestDist = nil, math.huge
    local selfPos = self.position
    for i = 1, #targets do
        local obj = targets[i]
        local dist = (obj.position - selfPos):length()
        if dist < bestDist then best, bestDist = obj, dist end
    end
    return best
end

-- Vanilla Spell stance hand-off (user rule).
-- The engine AI owns STANCE.Spell and the vanilla cast gesture that goes with
-- it. While that stance is up OSSC stands down completely: onUpdate restores
-- the engine spell list, leaves the selected castable / stance / attack input
-- alone, and starts no quick-cast — whatever owns the spell list, because a
-- quick-cast animation is never blended over Spell stance (see
-- castRules.quickcastStanceAllowed). Once the engine leaves Spell stance OSSC
-- strips the list again and resumes choosing spells. There is deliberately no
-- animation wait or input-hold give-up here: waiting for a doomed engine cast
-- used to wedge both casting systems, and taking the stance away kills the
-- vanilla cast the user wants to preserve.

-- True when the combat target is the actor's own leader. Deliberately NOT
-- folded into getCombatTarget: a protected follower is still in combat, and
-- reporting "no target" would make onUpdate hand the spells back to the engine,
-- which would then cast at the leader through the vanilla path. Keeping the
-- spells stripped is what actually protects the player; this only stops OSSC
-- from quick-casting.
local function isFollowProtected(target)
    return Cast.followTargetKey ~= nil and actorKey(target) == Cast.followTargetKey
end

-- Per-animation launch offsets (see scripts/ossc/ossc_launch_offsets.lua).
-- Actors always use the 'third' table applied from the actor origin along
-- the actor's facing.
local function getCasterSpawnPos(animGroup)
    local offset = launchOffsets.get(animGroup, false)
    local rotation = self.rotation
    return self.position
        + (rotation * Vec.FORWARD) * offset.forward
        + (rotation * Vec.LEFT) * offset.left
        + Vec.UP * offset.up
end

Cast.rayOptions = { ignore = self }

-- ── Bystanders on the line of fire (NPCProjectilesPassThroughBystanders) ──
-- Vanilla parity: a bolt aimed at this actor's own target flies THROUGH every
-- actor that is not its target, and only the intended target is affected. The
-- rule itself lives in ossc_cast_rules.lua so the player script applies the
-- exact same one to its own quick-casts; these wrappers keep the per-actor
-- `self` and the Combat.* names the rest of this script uses.
Combat.BYSTANDER_MAX       = castRules.BYSTANDER_MAX
Combat.BYSTANDER_STEP      = castRules.BYSTANDER_STEP
Combat.BYSTANDER_TOLERANCE = castRules.BYSTANDER_TOLERANCE

--- May the eye ray walk THROUGH `obj` on its way to `target`? (Visibility
--- only: an actor in the line of fire must not hide the target behind it.)
function Combat.isPassableBystander(obj, target)
    return castRules.isPassableBystander(self, obj, target)
end

local function hasLineOfSight(startPos, endPos, target)
    if type(nearby.castRay) ~= 'function' then return true end
    local from = startPos
    -- An actor standing in the line of fire does not hide the target behind
    -- it: the ray is restarted past the bystander, exactly like the bolt that
    -- will fly through them (or be soaked by them, see
    -- NPCProjectilesPassThroughBystanders). A wall still blocks.
    for _ = 1, Combat.BYSTANDER_MAX + 1 do
        local hit = nearby.castRay(from, endPos, Cast.rayOptions)
        if not hit or not hit.hit then return true end
        if hit.hitObject == target then return true end
        -- A hit at (or just in front of) the target's aim point is the
        -- target's own collision shape, not an obstruction.
        local hitPos = hit.hitPos
        if hitPos ~= nil and (hitPos - endPos):length() < Combat.BYSTANDER_TOLERANCE then
            return true
        end
        if hitPos == nil then return false end
        -- Another actor never hides the target behind it: the engine's own
        -- visibility does not treat actors as obstacles either, and the bolt
        -- either passes through them (the setting, default on) or is soaked by
        -- them (setting off) — but in both cases the caster may still shoot.
        if not Combat.isPassableBystander(hit.hitObject, target) then return false end
        from = hitPos + (endPos - startPos):normalize() * Combat.BYSTANDER_STEP
    end
    return false
end

-- ── Invisible actors ───────────────────────────────────────────────────────
-- Invisibility is DEFENSIVE (see the reactions section: it is only ever chosen
-- at 20% health or less). A quick-cast breaks invisibility — startQuickcast
-- sends the same MagExp_BreakInvisibility the player's cast sends, and vanilla
-- only breaks it on an attack — so an invisible actor that kept casting, or
-- kept walking into the player, would give itself away with its first spell or
-- stumble into the fight it is trying to leave.
--
-- So while the player can still see it, three things are taken away at once:
--
--   * its casts       — the cast gate reads Cast.hiddenHold (ossc_npc's
--                       evaluateCombatQuickcast);
--   * its attacks     — Mercy's Combat/CombatAux trees are switched off;
--   * its approach    — Mercy's Locomotion tree is switched off and the actor
--                       is walked AWAY from the player instead
--                       (Combat.retreatFrom), which is the part that makes the
--                       invisibility worth casting at all: it has to leave the
--                       line of sight to survive and heal up.
--
-- The moment the player loses sight of it the hold is released and everything
-- is handed back; the invisibility is still running, so the heal it came for is
-- cast unseen. On an actor with no Mercy interface only OSSC's own casts are
-- withheld and the engine AI is given a destination away from the player — an
-- engine melee swing is still not something a script can veto.
Combat.HIDDEN_LOS_INTERVAL = 0.2
-- How far away the player still counts as "able to see this actor at all".
-- Casting is what breaks invisibility and an attack is what gives the position
-- away, so the hold only protects an actor the player could actually notice;
-- beyond this distance nothing is hidden from anybody and the actor fights
-- normally instead of standing still forever. (Roughly vanilla's actor
-- perception range, in world units.)
Combat.HIDDEN_SIGHT_DISTANCE = 2500

--- True while this actor carries an Invisibility effect (any source).
function Combat.isInvisible()
    local effects = types.Actor.activeEffects(self)
    local getEffect = effects and effects.getEffect
    if type(getEffect) ~= 'function' then return false end
    local effect = effects:getEffect(core.magic.EFFECT_TYPE.Invisibility)
    if effect == nil then return false end
    return (tonumber(effect.magnitude) or 0) > 0
end

--- The actor the invisible retreat hides from: the player.
---
--- `nearby.players` is the only supported way for an actor script to ask where
--- the player is (nearbybindings.cpp exposes the same object list to local
--- scripts), so it is read rather than kept as a reference: an actor is handed
--- a fresh proxy for the same object on every call, and holding on to one
--- across cells is how a stale player ends up compared against.
---
--- When the list is empty (a modded setup, the test harness) the PLAYER is
--- looked for among the engine's combat targets instead — and only a Player
--- counts: hiding from another NPC is not what this hold is for, so a scene
--- with no player in it simply has no hold.
function Combat.threatActor()
    local players = nearby.players
    if type(players) == 'table' then
        local player = players[1]
        if player ~= nil and player.position ~= nil then return player end
    end
    local isPlayer = types.Player and types.Player.objectIsInstance
    if type(isPlayer) ~= 'function' then return nil end
    local targets = Combat.collectTargets()
    for i = 1, #targets do
        local obj = targets[i]
        if obj.position ~= nil and isPlayer(obj) then return obj end
    end
    return nil
end

--- True when `threat` has a clear line of sight to this actor.
---
--- Only the world, doors and the heightmap can block this ray; ACTORS cannot.
--- That is the whole point of the check: an invisible actor standing behind a
--- bystander is still in plain view of the player, so a body in the way is not
--- concealment. Ignoring actors also removes the "is this proxy the player?"
--- comparison, which `==` cannot answer reliably (the engine hands out a fresh
--- proxy per call), and it is the same rule Mercy's own concealment probes use
--- (`collisionType = World + HeightMap + Door`).
---
--- A STRICT ray otherwise: unlike the targeting walk, geometry between the two
--- is exactly what hides an invisible actor.
function Combat.playerCanSeeMe(threat)
    threat = threat or Combat.threatActor()
    if threat == nil or threat.position == nil then return false end
    if type(nearby.castRay) ~= 'function' then return false end
    local mine = self.position + Vec.LOS_TARGET_OFFSET
    local eye = threat.position + Vec.LOS_TARGET_OFFSET
    if (eye - mine):length() > Combat.HIDDEN_SIGHT_DISTANCE then return false end
    local collisions = nearby.COLLISION_TYPE
    local options = Cast.rayOptions
    if collisions ~= nil and collisions.World ~= nil
        and collisions.HeightMap ~= nil and collisions.Door ~= nil then
        options = {
            collisionType = collisions.World + collisions.HeightMap + collisions.Door,
        }
    end
    -- No collision-type table in this build: the targeting ray (which ignores
    -- this actor) is the closest thing to "did a wall stop it".
    local hit = nearby.castRay(mine, eye, options)
    return not (hit and hit.hit)
end

-- How far a hidden actor steps away from the player when nothing can path it.
-- Long enough to leave vanilla's actor perception range (Combat.HIDDEN_SIGHT_DISTANCE)
-- from where it stood, short enough to be an attainable destination.
Combat.HIDDEN_RETREAT_DISTANCE = 800
-- An engine-driven actor is given a fresh destination at most this often: a
-- Travel package restarted every frame never finishes its own path.
Combat.HIDDEN_RETREAT_REISSUE  = 2.0
-- Directions probed for a retreat point, in degrees off "straight away from the
-- threat", in the order they are tried. The first one the threat cannot see is
-- the one used; straight away is the fallback when none of them is concealed.
local HIDDEN_RETREAT_ANGLES = { 0, 40, -40, 80, -80 }

--- A point away from `threat` that the threat cannot see, or nil.
---
--- The candidate is the actor's own position pushed `HIDDEN_RETREAT_DISTANCE`
--- away from the threat, rotated by each angle in turn; the first candidate
--- whose sight line from the threat is blocked wins. "Blocked" is asked with
--- the same ray as playerCanSeeMe (world only), just cast the other way and to
--- the candidate point, which is the question "can the player see that spot".
function Combat.hidePointFor(threat)
    if threat == nil or threat.position == nil then return nil end
    local away = self.position - threat.position
    away = util.vector3(away.x, away.y, 0)
    if away:length() < 1 then return nil end
    away = away:normalize()
    local collisions = nearby.COLLISION_TYPE
    local options = nil
    if collisions ~= nil and collisions.World ~= nil
        and collisions.HeightMap ~= nil and collisions.Door ~= nil then
        options = { collisionType = collisions.World + collisions.HeightMap + collisions.Door }
    end
    local eye = threat.position + Vec.LOS_TARGET_OFFSET
    local fallback = nil
    for i = 1, #HIDDEN_RETREAT_ANGLES do
        local radians = math.rad(HIDDEN_RETREAT_ANGLES[i])
        local cos, sin = math.cos(radians), math.sin(radians)
        local dir = util.vector3(
            away.x * cos - away.y * sin,
            away.x * sin + away.y * cos,
            0)
        local point = self.position + dir * Combat.HIDDEN_RETREAT_DISTANCE
        if fallback == nil then fallback = point end
        if options == nil or type(nearby.castRay) ~= 'function' then return fallback end
        local hit = nearby.castRay(eye, point + Vec.LOS_TARGET_OFFSET, options)
        if hit and hit.hit then return point end
    end
    return fallback
end

--- Walk the hidden actor away from `threat` for one frame.
---
--- OSSC cannot path another actor (`nearby.findPath` is for this actor's own
--- queries and the engine only moves a body through an AI package or its own
--- controls), so the retreat is split by who is driving:
---
---  * Mercy drives: the hold switched its Combat AND Locomotion trees off
---    (ossc_mercy.beginHiddenHold), so nothing else writes these controls this
---    frame. The actor backs away — movement = -1 is "backwards", which keeps
---    it FACING the threat while increasing the distance, exactly what an
---    escape wants (turning its back is how a fleeing actor is caught).
---  * The engine drives (no Mercy interface on this actor): writing controls
---    would be ignored, so the actor is given a Travel destination instead, at
---    most every HIDDEN_RETREAT_REISSUE seconds so the package can make
---    progress. No cast of ours is allowed while the hold lasts, so it does not
---    turn and fight on the way.
function Combat.retreatFrom(threat)
    if threat == nil then return false end
    local now = core.getSimulationTime()
    if Cast.hiddenHoldYielding then
        local controls = self.controls
        if controls == nil then return false end
        controls.movement = -1
        controls.sideMovement = 0
        controls.run = true
        return true
    end
    if now < Cast.nextRetreatAt then return false end
    local point = Combat.hidePointFor(threat)
    if point == nil then return false end
    if not (I.AI and type(I.AI.startPackage) == 'function') then return false end
    Cast.nextRetreatAt = now + Combat.HIDDEN_RETREAT_REISSUE
    I.AI.startPackage({ type = 'Travel', destPosition = point, cancelOther = true })
    debugLog('Invisible retreat — travelling away from the player')
    return true
end

--- Refresh the invisible-and-seen hold. Called once per frame from onUpdate,
--- before the tactical poll, so no cast gate ever reads a stale answer.
---
--- The hold has three jobs, and all three are needed for invisibility to be
--- worth casting: no attack, no cast (ossc_npc's cast gate reads
--- `Cast.hiddenHold`) and NO CHASE. The third one is the retreat below: an
--- invisible actor that keeps walking into the player gives itself away just as
--- surely as one that swings, and a hit breaks the invisibility the same way.
function Combat.updateHidden(now)
    local invisible = Combat.isInvisible()
    if not invisible then
        Cast.hiddenSeen = false
        Cast.hiddenThreat = nil
    elseif now >= Cast.nextHiddenCheck then
        Cast.nextHiddenCheck = now + Combat.HIDDEN_LOS_INTERVAL
        Cast.hiddenThreat = Combat.threatActor()
        Cast.hiddenSeen = Combat.playerCanSeeMe(Cast.hiddenThreat)
    end
    local hold = invisible and Cast.hiddenSeen == true
    if hold and not Cast.hiddenHold then
        Cast.hiddenHold = true
        -- Mercy's Combat trees are what make the body attack, and its
        -- Locomotion tree is what walks it into the player; both are switched
        -- off for the hold, so the retreat below is the only thing moving the
        -- actor. Locomotion is handed back when the hold ends.
        Cast.hiddenHoldYielding = mercy.beginHiddenHold()
        Cast.nextRetreatAt = 0.0
        debugLog('Invisible and seen — holding attacks and casts until the player loses sight')
    elseif not hold and Cast.hiddenHold then
        Cast.hiddenHold = false
        mercy.endHiddenHold()
        Cast.hiddenHoldYielding = false
        Cast.hiddenThreat = nil
        debugLog('Invisible hold released — the player lost sight of this actor')
    elseif hold and Cast.hiddenHoldYielding then
        mercy.maintainHiddenHold()
    end
    if hold then Combat.retreatFrom(Cast.hiddenThreat) end
    return hold
end

--- Live engine combat targets this actor can actually see and shoot at.
--- The eye ray answers "sees another actor/player"; the launch ray makes sure
--- a Target projectile is not spawned into a wall. Both rays ignore self.
function Combat.collectVisibleTargets()
    local visible = Combat.visibleTargets
    for i = #visible, 1, -1 do visible[i] = nil end
    local targets = Combat.collectTargets()
    local selfPos = self.position
    local eyePos = selfPos + Vec.LOS_TARGET_OFFSET
    local spawnPos = getCasterSpawnPos(nil)
    for i = 1, #targets do
        local obj = targets[i]
        local dist = (obj.position - selfPos):length()
        if dist <= Cfg.maxDist and not isFollowProtected(obj) then
            local aimPos = obj.position + Vec.LOS_TARGET_OFFSET
            if hasLineOfSight(eyePos, aimPos, obj)
                and hasLineOfSight(spawnPos, aimPos, obj) then
                visible[#visible + 1] = obj
            end
        end
    end
    return visible
end

-- Touch reach: the vanilla getHitContact formula, shared with the player's
-- fallback (scripts/ossc/ossc_cast_rules.lua). The engine calls
-- getHitContact(actor, fCombatDistance) — plain fCombatDistance, NOT
-- fCombatDistance * fHandToHandReach (that product is the UNARMED MELEE swing
-- reach and gave this actor a several-hundred-unit touch spell whenever a
-- combat mod raised fHandToHandReach). An actor has no camera: it looks along
-- its body yaw from the vanilla eye level, level (a vertical angle of 0 is
-- exactly what the engine gives a non-player caster), and the line of sight is
-- the engine's own world-geometry-only check. The interactive
-- iMaxActivateDist cap is the player's crosshair rule and is deliberately not
-- applied here.
local function isTouchTargetInReach(target)
    return castRules.isTouchTargetInReach(self, target)
end

-- ── Spell selection ────────────────────────────────────────────────────────
local function schoolName(mgef)
    local school = mgef and mgef.school
    if type(school) == 'string' then return school:lower() end
    return Anim.SCHOOL_STRS[school] or 'destruction'
end

-- A school does not tell us whether an effect heals: Restoration includes
-- defensive and attribute buffs. Only an actual Restore Health effect counts
-- for the NPC's low-health priority or the self-only healing safeguard. Use
-- the effect record id when available and normalize separators/case so
-- modded ids such as "Super_Restore_Health" are recognized too.
local function isRestoreHealthEffect(effect)
    if not effect or effect.id == nil then return false end
    local mgef = effectRecords[effect.id]
    local effectId = mgef and mgef.id or effect.id
    if type(effectId) ~= 'string' then return false end
    local normalizedId = effectId:lower():gsub('[^%w]', '')
    return normalizedId:find('restorehealth', 1, true) ~= nil
end

local function hasSelfRestoreHealthEffect(record)
    for _, effect in ipairs(record.effects or {}) do
        if effect.range == RANGE.Self and isRestoreHealthEffect(effect) then return true end
    end
    return false
end

-- Restore Fatigue (vanilla id "RestoreFatigue", modded ids normalized the
-- same way as Restore Health above) is maintenance, not a buff: the actor
-- only considers such a spell while its own fatigue is strictly under
-- Cfg.restoreFatigueThreshold. At or above the threshold the spell is left
-- out of every pool entirely — see categorizeSpells.
local function isRestoreFatigueEffect(effect)
    if not effect or effect.id == nil then return false end
    local mgef = effectRecords[effect.id]
    local effectId = mgef and mgef.id or effect.id
    if type(effectId) ~= 'string' then return false end
    local normalizedId = effectId:lower():gsub('[^%w]', '')
    return normalizedId:find('restorefatigue', 1, true) ~= nil
end

local function hasRestoreFatigueEffect(record)
    for _, effect in ipairs(record.effects or {}) do
        if isRestoreFatigueEffect(effect) then return true end
    end
    return false
end

-- ── Spell Decision AI: eligibility, expiry, underwater grant, private RNG ──
-- Supporting logic for the NPC Spell Decision AI group
-- (docs/actor-cast-decisions-plan.md §4.10): the declined-spell list (user
-- setting + built-in family declines), the Waterbreathing context gate and
-- its 33 % underwater grant, the target-side expiry rule (never re-apply a
-- timed effect while it is on the target; 1–3 s private jitter after
-- cast + duration), and the derived flags behind the magicka reserve.
-- Design rules: ONE chunk local (the 200-local main-chunk budget is the
-- limit that matters); all randomness comes from the PRIVATE Lehmer LCG —
-- the shared math.random stream keeps its exact draw order and count (the
-- stance suite is RNG-stream-sensitive).
local Tactics = (function()
    local lcgState, lcgSeeded = 0, false
    local tagCache = {}
    local expiryNotBefore = {}

    -- Lehmer GC (MINSTD): exact in double arithmetic (48271 * 2^31 < 2^53),
    -- seeded deterministically from the actor id — never touches math.random.
    local function rand01()
        if not lcgSeeded then
            local s = 1013904223
            local id = tostring((self and self.id) or (self and self.recordId) or '')
            for i = 1, #id do
                s = (s * 31 + string.byte(id, i)) % 2147483647
            end
            if s == 0 then s = 1 end
            lcgState, lcgSeeded = s, true
        end
        lcgState = (lcgState * 48271) % 2147483647
        return lcgState / 2147483647
    end

    local function effectKey(effect)
        return table.concat({
            tostring(effect.id or ''):lower(),
            tostring(effect.affectedAttribute or ''):lower(),
            tostring(effect.affectedSkill or ''):lower(),
        }, '|')
    end

    local function normalizedEffectId(effect)
        local mgef = effectRecords[effect.id]
        local effectId = mgef and mgef.id or effect.id
        if type(effectId) ~= 'string' then return '' end
        return (effectId:lower():gsub('[^%w]', ''))
    end

    local function hasWaterBreathing(record)
        for _, effect in ipairs(record.effects or {}) do
            if normalizedEffectId(effect):find('waterbreathing', 1, true) then
                return true
            end
        end
        return false
    end

    -- Direct-health damage and its matching weakness tag. "Same school" for
    -- combo purposes means same DAMAGE TYPE (user decision), not merely that
    -- both records happen to use Destruction: Fire→Fire, Frost→Frost,
    -- Shock→Shock, Poison→Poison, Weakness to Magicka→Damage Health.
    local damageTagById = {
        damagehealth = 'magicka',
        firedamage   = 'fire',
        frostdamage  = 'frost',
        shockdamage  = 'shock',
        poison       = 'poison',
    }
    -- Every Weakness effect vanilla/OpenMW defines (core.magic.EFFECT_TYPE
    -- ids). All of them are Weakness spells: the Minimum Weakness Magnitude
    -- rule applies to each one. Only the five that own a
    -- matching DAMAGE type above can ever arm a Strict Sequence; Weakness to
    -- Normal Weapons has nothing to chain to, so it stays ordinary offense (it
    -- used to fall through untagged, which also let it bypass the minimum
    -- magnitude entirely — the reported bug).
    local weaknessTagById = {
        weaknesstomagicka        = 'magicka',
        weaknesstofire           = 'fire',
        weaknesstofrost          = 'frost',
        weaknesstoshock          = 'shock',
        weaknesstopoison         = 'poison',
        weaknesstonormalweapons  = 'normalweapons',
    }
    -- Ruled out completely (user directive): Weakness to Disease, Weakness to
    -- Blight AND Weakness to Corprus are never cast, never stored and never
    -- chained — not even when they meet the minimum magnitude or the actor has
    -- nothing else. Nothing in the game deals their damage type through a
    -- spell, so the effect is a wasted cast; leaving them out of
    -- weaknessTagById alone would send them back through the untagged path that
    -- bypassed the minimum magnitude.
    --
    -- The record id is `weaknesstocorprusdisease` in OpenMW's EFFECT_TYPE enum
    -- (and some mods spell the id `weaknesstocorprus`); both map to the same
    -- effect, so both are listed. The normaliser lowercases and strips
    -- separators, so `Weakness to Corprus Disease` matches too.
    local excludedWeaknessById = {
        weaknesstocommondisease      = true,
        weaknesstoblightdisease      = true,
        weaknesstocorprusdisease     = true,
        weaknesstocorprus            = true,
    }
    -- Weakness types a Strict Sequence can chain to: exactly the ones with a
    -- damageTagById partner ("same school" = same DAMAGE type, user decision).
    local weaknessHasDamageTag = {
        magicka = true,
        fire    = true,
        frost   = true,
        shock   = true,
        poison  = true,
    }

    -- Static tags for one spell record. Damage tags are a set; weakness tags
    -- retain both the strongest guaranteed (minimum) magnitude and the longest
    -- duration per type. Qualification uses magnitude; duration is retained to
    -- bound the strict sequence after its setup has been cast.
    local function combatTags(record)
        local damageTags, weaknessDurations, weaknessMagnitudes
        local comboWeakness = false
        -- Weakness accounting for the Disease / Blight / Corprus exclusion:
        -- every Weakness effect on the record is counted, and the excluded ones
        -- are counted separately. A record whose ONLY weaknesses are excluded
        -- is dropped from every pool; a mixed record keeps its usable weakness.
        local weaknessEffects, excludedWeaknessEffects = 0, 0
        for _, effect in ipairs(record.effects or {}) do
            if effect.range ~= RANGE.Self then
                local nid = normalizedEffectId(effect)
                local damageTag = damageTagById[nid]
                if damageTag then
                    damageTags = damageTags or {}
                    damageTags[damageTag] = true
                end
                if excludedWeaknessById[nid] then
                    excludedWeaknessEffects = excludedWeaknessEffects + 1
                elseif weaknessTagById[nid] then
                    weaknessEffects = weaknessEffects + 1
                end
                local weaknessTag = weaknessTagById[nid]
                if weaknessTag then
                    if weaknessHasDamageTag[weaknessTag] then comboWeakness = true end
                    weaknessDurations = weaknessDurations or {}
                    weaknessMagnitudes = weaknessMagnitudes or {}
                    local duration = tonumber(effect.duration) or 0
                    local magnitude = tonumber(effect.magnitudeMin)
                        or tonumber(effect.minMagnitude)
                        or tonumber(effect.magnitudeMax)
                        or tonumber(effect.maxMagnitude) or 0
                    if duration > (weaknessDurations[weaknessTag] or -1) then
                        weaknessDurations[weaknessTag] = duration
                    end
                    if magnitude > (weaknessMagnitudes[weaknessTag] or -1) then
                        weaknessMagnitudes[weaknessTag] = magnitude
                    end
                end
            end
        end
        return damageTags, weaknessDurations, weaknessMagnitudes, comboWeakness,
            excludedWeaknessEffects > 0 and weaknessEffects == 0
    end

    local function recordIsHarmful(record)
        for _, effect in ipairs(record.effects or {}) do
            local mgef = effect.id and effectRecords[effect.id]
            if mgef and mgef.harmful then return true end
        end
        return false
    end

    local function hasAbsorbOrDrainOffense(record)
        for _, effect in ipairs(record.effects or {}) do
            local id = normalizedEffectId(effect)
            if id:sub(1, 6) == 'absorb' or id:sub(1, 5) == 'drain' then
                return true
            end
        end
        return false
    end

    -- Longest duration among effects explicitly classified as beneficial,
    -- computed once per record. Unknown/harmful effects are not assumed to be
    -- buffs: otherwise an unannotated damage spell could be rejected as a
    -- zero-second benefit. A mixed buff qualifies when one known benefit lasts
    -- long enough; harmful effects do not make it look worthwhile.
    local function beneficialDuration(record)
        local found, longest = false, 0
        for _, effect in ipairs(record.effects or {}) do
            local mgef = effect.id and effectRecords[effect.id]
            if mgef and mgef.harmful == false then
                found = true
                local duration = tonumber(effect.duration) or 0
                if duration > longest then longest = duration end
            end
        end
        return found, longest
    end

    -- Built-in family declines: Fortify Sneak / Fortify Mercantile are never
    -- quick-cast (user directive, plan §4.10). Covers affectedSkill and
    -- modded effect ids like "FortifySneak".
    local function isDeclinedFamily(record)
        for _, effect in ipairs(record.effects or {}) do
            local nid = normalizedEffectId(effect)
            if nid:find('fortify', 1, true) then
                local skill = effect.affectedSkill
                if type(skill) == 'string' then
                    local ns = (skill:lower():gsub('[^%w]', ''))
                    if ns == 'sneak' or ns == 'mercantile' then return true end
                end
                if nid:find('sneak', 1, true) or nid:find('mercantile', 1, true) then
                    return true
                end
            end
        end
        return false
    end

    -- Static per-record flags, computed exactly once (plan perf rule 2):
    -- records never change, so the effect scans behind them never need to
    -- run again inside the hot categorize loop.
    local flagCache = {}
    local function flagsOf(record)
        local flags = flagCache[record.id]
        if flags then return flags end
        local damageTags, weaknessDurations, weaknessMagnitudes, comboWeakness,
            excludedWeaknessOnly = combatTags(record)
        local hasBeneficialEffect, beneficialMaxDuration = beneficialDuration(record)
        flags = {
            waterBreathing        = hasWaterBreathing(record),
            declinedFamily        = isDeclinedFamily(record),
            priorityDamage        = damageTags ~= nil,
            harmful               = recordIsHarmful(record),
            damageTags            = damageTags,
            weaknessDurations     = weaknessDurations,
            weaknessMagnitudes    = weaknessMagnitudes,
            -- True only for a weakness a Strict Sequence could chain to. The
            -- others still carry magnitudes (so the minimum applies) but are
            -- never diverted out of the ordinary offense pools.
            comboWeakness         = comboWeakness,
            -- Weakness to Disease / Blight / Corprus is excluded outright: a
            -- record that carries nothing but those is never cast at all.
            excludedWeakness      = excludedWeaknessOnly,
            hasBeneficialEffect  = hasBeneficialEffect,
            beneficialMaxDuration = beneficialMaxDuration,
        }
        flagCache[record.id] = flags
        return flags
    end

    local function hasQualifyingWeakness(flags)
        for _, magnitude in pairs(flags.weaknessMagnitudes or {}) do
            if magnitude >= Cfg.weaknessMinMagnitude then return true end
        end
        return false
    end

    -- Non-beneficial Self effects and maintenance spells are not duration-
    -- filtered. A zero minimum disables the filter; otherwise one beneficial
    -- effect must meet the inclusive minimum.
    local function buffDurationQualifies(record)
        local minimum = Cfg.beneficialBuffMinDuration or 0
        if minimum <= 0 or hasRestoreFatigueEffect(record)
            or hasSelfRestoreHealthEffect(record)
            or hasAbsorbOrDrainOffense(record) then
            return true
        end
        local flags = flagsOf(record)
        return flags.harmful or not flags.hasBeneficialEffect
            or flags.beneficialMaxDuration >= minimum
    end

    -- A setup is only meaningful when a currently legal matching damage spell
    -- exists. Touch damage counts only while the target is actually in reach;
    -- Target damage is usable in either distance band.
    local function weaknessMatchesAvailableDamage(flags, inTouchReach)
        for tag, magnitude in pairs(flags.weaknessMagnitudes or {}) do
            if magnitude >= Cfg.weaknessMinMagnitude
                and (Spells.damageTagsTarget[tag]
                    or (inTouchReach and Spells.damageTagsTouch[tag])) then
                return true
            end
        end
        return false
    end

    local function damageMatchesTags(flags, wanted)
        for tag in pairs(flags.damageTags or {}) do
            if wanted[tag] then return true end
        end
        return false
    end

    local function addDamageTags(flags, destination)
        for tag in pairs(flags.damageTags or {}) do destination[tag] = true end
    end

    local function isDeclinedSpell(spellId, record)
        if Cfg.declinedSpells then
            local key = type(spellId) == 'string' and spellId:lower() or nil
            if key and Cfg.declinedSpells[key] then return true end
        end
        return flagsOf(record).declinedFamily
    end

    -- Timed-effect tag: unique keys of non-Self effects with a duration,
    -- plus the longest duration. Records are static → computed once each.
    local function tagOf(record)
        local tag = tagCache[record.id]
        if tag then return tag end
        local keys, maxDur = nil, 0
        for _, eff in ipairs(record.effects or {}) do
            local dur = tonumber(eff.duration) or 0
            if dur > 0 and eff.range ~= RANGE.Self then
                keys = keys or {}
                local k = effectKey(eff)
                if not keys[k] then keys[k] = true end
                if dur > maxDur then maxDur = dur end
            end
        end
        tag = { timedKeys = keys, maxDur = maxDur }
        tagCache[record.id] = tag
        return tag
    end

    local function isTimed(record)
        return tagOf(record).timedKeys ~= nil
    end

    local function targetKeyOf(target)
        if target == nil then return nil end
        if type(target.id) == 'string' and target.id ~= '' then return target.id end
        return tostring(target.recordId or target)
    end

    local function clearSequence()
        Cast.comboTargetKey, Cast.comboUntil = nil, 0.0
        for tag in pairs(Cast.comboTags) do Cast.comboTags[tag] = nil end
    end

    local function armSequence(target, record, now)
        clearSequence()
        local key = targetKeyOf(target)
        if not key then return end
        local longest = 0
        local flags = flagsOf(record)
        for tag, magnitude in pairs(flags.weaknessMagnitudes or {}) do
            if magnitude >= Cfg.weaknessMinMagnitude
                and weaknessHasDamageTag[tag] then
                Cast.comboTags[tag] = true
                local duration = flags.weaknessDurations[tag] or 0
                if duration > longest then longest = duration end
            end
        end
        if next(Cast.comboTags) == nil then return end
        Cast.comboTargetKey = key
        -- Allow for projectile travel before the effect's own duration starts.
        Cast.comboUntil = (now or 0) + longest + 5
    end

    local function targetHasSequenceWeakness(target)
        local active = types.Actor.activeSpells and types.Actor.activeSpells(target)
        if not active then return false end
        for _, activeSpell in pairs(active) do
            for _, effect in pairs(activeSpell.effects or {}) do
                local tag = weaknessTagById[normalizedEffectId(effect)]
                if tag and Cast.comboTags[tag] then return true end
            end
        end
        return false
    end

    -- Returns the locked damage tags and whether their Weakness has actually
    -- landed. A strict sequence waits rather than firing its nuke while the
    -- setup projectile is still in flight (or if it missed).
    local function sequenceState(target, now)
        if not Cast.comboTargetKey then return nil, false end
        if targetKeyOf(target) ~= Cast.comboTargetKey or now >= Cast.comboUntil then
            clearSequence()
            return nil, false
        end
        return Cast.comboTags, targetHasSequenceWeakness(target)
    end

    local function noteComboCast(target, record, strategy, now)
        if strategy == 'strict_weakness' then
            armSequence(target, record, now)
        elseif strategy == 'strict_damage' then
            clearSequence()
        end
    end

    -- Effect keys currently on the target (any caster). Built at most once
    -- per categorize pass, and only when a timed candidate needs it.
    local function targetEffectKeys(target)
        local keys = {}
        local active = types.Actor.activeSpells and types.Actor.activeSpells(target)
        if active then
            for _, activeSpell in pairs(active) do
                local effs = activeSpell and activeSpell.effects
                if effs then
                    for _, eff in pairs(effs) do
                        keys[effectKey(eff)] = true
                    end
                end
            end
        end
        return keys
    end

    -- Expiry rule (always on): skip when (a) this actor cast this spell at
    -- this target less than duration + 1–3 s ago, or (b) any of the spell's
    -- timed effects is on the target right now — whichever applies first.
    local function expiryBlocks(target, now, record, activeKeys)
        local tag = tagOf(record)
        if not tag.timedKeys then return false end
        local key = targetKeyOf(target)
        if key then
            local per = expiryNotBefore[key]
            local untilTime = per and per[record.id]
            if untilTime and now < untilTime then return true end
        end
        if activeKeys then
            for k in pairs(tag.timedKeys) do
                if activeKeys[k] then return true end
            end
        end
        return false
    end

    -- Called when a timed spell is actually committed to a cast: block
    -- re-selection until the effects run out plus a 1–3 s grace, so recasts
    -- of paralysis/silence-style spells never feel metronomic (user rule).
    local function noteExpiry(target, spell, now)
        local tag = tagOf(spell)
        if not tag.timedKeys then return end
        local key = targetKeyOf(target)
        if not key then return end
        local per = expiryNotBefore[key]
        if not per then
            per = {}
            expiryNotBefore[key] = per
        end
        per[spell.id] = now + tag.maxDur + 1 + math.floor(rand01() * 3)
        -- Cheap cap: keep at most 8 pending entries per target.
        local count = 0
        for _ in pairs(per) do count = count + 1 end
        if count > 8 then
            local drop = count - 8
            for k in pairs(per) do
                if k ~= spell.id then
                    per[k] = nil
                    drop = drop - 1
                    if drop <= 0 then break end
                end
            end
        end
    end

    local function submerged()
        local fn = types.Actor.isSwimming
        return fn ~= nil and fn(self) == true
    end

    local function scanKnowsWaterbreathing()
        for spellId in pairs(Cast.knownSpells) do
            local record = spellRecords[spellId]
            if record and isCastableSpellType(record) and hasWaterBreathing(record) then
                return true
            end
        end
        return false
    end

    -- 33 %/eval underwater grant (plan §4.10, "both"): runs only while the
    -- actor is submerged, lacks a Waterbreathing spell and the private roll
    -- succeeds — then the spell joins the known set once and stops rolling.
    local function maybeGrantWaterbreathing()
        if Cast.wbKnown or Cast.wbExhausted then return end
        if not Cast.wbValidated then
            Cast.wbValidated = true
            if scanKnowsWaterbreathing() then
                Cast.wbKnown = true
                return
            end
        end
        if not submerged() then return end
        if rand01() >= (1 / 3) then return end
        local bestId, bestCost = nil, nil
        for id, record in pairs(spellRecords) do
            if isCastableSpellType(record) and record.effects and hasWaterBreathing(record)
                and record.effects[1] and record.effects[1].range == RANGE.Self then
                local cost = record.cost or 0
                if bestId == nil or cost < bestCost then bestId, bestCost = id, cost end
            end
        end
        if not bestId then
            Cast.wbExhausted = true
            return
        end
        -- Combat-loophole consistency: while the engine list is stripped the
        -- grant joins only the OSSC cache (restore hands it over later);
        -- otherwise the actor keeps it in his spellbook immediately.
        if not Cast.spellsTemporarilyRemoved then
            local list = types.Actor.spells(self)
            if list and list.add then list:add(bestId) end
        end
        Cast.knownSpells[bestId] = true
        Cast.wbKnown = true
        Cast.knownSpellsDirty = true
        debugLog('Granted Waterbreathing underwater (33% roll): ' .. tostring(bestId))
    end

    -- Derived flags, re-run only when knownSpells grows (dirty bit from
    -- cacheCastableSpells / the grant / save-load): sustain-capable caster
    -- (knows a Self heal or Restore-Fatigue spell → magicka reserve applies)
    -- and the Waterbreathing validation bit.
    local function refreshDerived()
        Cast.knownSpellsDirty = false
        Cast.wbValidated = false
        local sustain = false
        for spellId in pairs(Cast.knownSpells) do
            local record = spellRecords[spellId]
            if record and record.effects
                and (hasSelfRestoreHealthEffect(record) or hasRestoreFatigueEffect(record)) then
                sustain = true
                break
            end
        end
        Cast.sustainCaster = sustain
        -- Ally pools (M2) rebuild on the same dirty signal: their membership
        -- (range, effects, declines) is static spell-list fact.
        Cast.allyPoolsDirty = true
    end

    -- True while `active` (an ActorActiveSpells snapshot) does not carry
    -- this record on `leader`: exact-spell check first, then the effect-key
    -- fallback that catches renamed or stacked copies — the same match
    -- selfSpellStillActive uses for the caster's own buffs, generalised to
    -- any actor and without the Self-range restriction (ally buffs land at
    -- Touch/Target range).
    local function allyBuffMissing(active, leader, record)
        if active.isSpellActive and active:isSpellActive(record.id) then return false end
        local wanted, wantedCount = {}, 0
        for _, effect in ipairs(record.effects or {}) do
            if effect.id then
                local key = effectKey(effect)
                if not wanted[key] then
                    wanted[key] = true
                    wantedCount = wantedCount + 1
                end
            end
        end
        if wantedCount == 0 then return false end
        for _, activeSpell in pairs(active) do
            local effs = activeSpell and activeSpell.effects
            if effs then
                local matched = 0
                for _, eff in ipairs(effs) do
                    if wanted[effectKey(eff)] then matched = matched + 1 end
                end
                if matched >= wantedCount then return false end
            end
        end
        return true
    end

    -- Same-buff recast lockout (NPCAIBuffRecastCooldown): true while this
    -- actor quick-cast this exact buff spell less than the configured
    -- seconds ago, whether the buff went on the actor itself or its leader.
    -- It sits ON TOP of the still-active rules (selfSpellStillActive /
    -- allyBuffMissing): those only see a buff that is still running, so an
    -- expired, dispelled or undetectable buff could be re-cast on the next
    -- 2.2 s buff tick forever. Expired entries prune themselves here, so
    -- the persisted map only ever holds live lockouts.
    local function buffRecastBlocked(record, now)
        local cooldown = Cfg.buffRecastCooldown
        if not cooldown or cooldown <= 0 or not record or not record.id then
            return false
        end
        local key = tostring(record.id):lower()
        local last = Cast.buffLastCastAt[key]
        if not last then return false end
        if (now or 0) - last < cooldown then return true end
        Cast.buffLastCastAt[key] = nil
        return false
    end

    -- Stamp a buff quick-cast the moment it is committed (same point the
    -- general cooldown is armed): the lockout is per caster and per spell,
    -- not per target, so a buff cast on the leader also locks the Self cast
    -- of the same spell and vice versa.
    local function noteBuffCast(record, now)
        local cooldown = Cfg.buffRecastCooldown
        if not cooldown or cooldown <= 0 or not record or not record.id then
            return
        end
        Cast.buffLastCastAt[tostring(record.id):lower()] = now or 0
    end

    -- M2 ally casting (leader-only, engine-true source): an opportunistic
    -- heal for the Follow-package leader, then — from Moderate up — a
    -- Touch/Target buff the leader lacks. Returns leader, record, isBuff or
    -- nil. No RNG here: the combat pipeline keeps owning every draw, and an
    -- actor without a leader exits after one nil check, draw-identical to
    -- M1. The heal picks the strongest record (magnitude is static); the
    -- buff picks the first missing one.
    local function pickAllyCast(now)
        if Cfg.allyLevel < 1 then return nil end
        local leader = Cast.followObj
        if not leader or not leader.isValid or not leader:isValid() then return nil end
        if types.Actor.isDead(leader) then return nil end
        local heals, buffs = Cast.allyHeals, Cast.allyBuffs
        if not heals or not buffs or (#heals == 0 and #buffs == 0) then return nil end
        local health = types.Actor.stats.dynamic.health(leader)
        if not health or not health.base or health.base <= 0 then return nil end
        local pct = health.current / health.base * 100
        if pct < Cfg.healThresholdPct and #heals > 0 then
            local best, bestMag = heals[1], -1
            for i = 1, #heals do
                local record = heals[i]
                local mag = 0
                for _, effect in ipairs(record.effects or {}) do
                    if effect.range ~= RANGE.Self and isRestoreHealthEffect(effect) then
                        mag = mag + (effect.magnitude or 0)
                    end
                end
                if mag > bestMag then best, bestMag = record, mag end
            end
            return leader, best, false
        end
        if Cfg.allyLevel >= 2 and #buffs > 0 then
            local active = types.Actor.activeSpells and types.Actor.activeSpells(leader)
            if active then
                for i = 1, #buffs do
                    if buffDurationQualifies(buffs[i])
                        and not buffRecastBlocked(buffs[i], now)
                        and allyBuffMissing(active, leader, buffs[i]) then
                        return leader, buffs[i], true
                    end
                end
            end
        end
        return nil
    end

    -- "Knows at least one spell" (the caster-role factor). Records never
    -- change, so the answer is cached per actor key forever — first visit
    -- pays one spell-list walk, every later pick is a table read. The cache
    -- resets past 64 entries so a session full of unique actors stays
    -- bounded.
    local function roleOf(actor)
        local key = actorKey(actor)
        if not key then return false end
        local knows = Cast.casterKnows[key]
        if knows ~= nil then return knows end
        knows = false
        for _ in pairs(types.Actor.spells(actor)) do
            knows = true
            break
        end
        if Cast.casterKnowsN >= 64 then
            Cast.casterKnows = {}
            Cast.casterKnowsN = 0
        end
        Cast.casterKnows[key] = knows
        Cast.casterKnowsN = Cast.casterKnowsN + 1
        return knows
    end

    -- Rebuild the engine-target list (whom this actor's own AI is
    -- fighting). EngineTargetsOnly remains the fixed policy: no nearby.actors
    -- free-aim scan. `candidates` is the live, visible subset collected by
    -- Combat.collectVisibleTargets(); without it we fall back to the engine's
    -- full Combat list for callers that only have an active target.
    local function refreshHostiles(engineTarget, candidates)
        local engine = candidates
        if not engine and I.AI and type(I.AI.getTargets) == 'function' then
            engine = I.AI.getTargets('Combat')
        end
        if not engine or #engine == 0 then engine = { engineTarget } end
        local wrapped, set = {}, {}
        for i = 1, #engine do
            local obj = engine[i]
            local key = Combat.isLiveTarget(obj) and actorKey(obj) or nil
            -- Never score the protected leader (same rule upstream's
            -- isFollowProtected applies to the combat target).
            if key and key == Cast.followTargetKey then key = nil end
            if key and not set[key] then
                set[key] = true
                wrapped[#wrapped + 1] = { obj = obj, key = key, threat = 1 }
            end
        end
        if #wrapped == 0 and Combat.isLiveTarget(engineTarget) then
            local key = actorKey(engineTarget)
            if key then
                wrapped[1] = { obj = engineTarget, key = key, threat = 1 }
            end
        end
        Cast.engineTargets = wrapped
    end

    -- Engine-target choice: deterministic argmax over the engine pool —
    -- zero RNG, zero allocation in the pick itself. Fitness = sum of the
    -- fixed rank weights (4/2/1/0.5 by position in TARGET_ORDER) times the
    -- four [0..1] factors: dist (range fit), hp (finish the weak), role
    -- (caster), threat (engine combat target). The factor order is the old
    -- DistanceFirst priority, hardcoded now that the free-aim candidate
    -- settings are retired. An empty pool degrades to the engine target;
    -- a one-candidate pool equal to the engine target short-circuits
    -- before any stat read.
    local RANK_W = { 4, 2, 1, 0.5 }
    local TARGET_ORDER = { 'dist', 'hp', 'role', 'threat' }
    local function pickCombatTarget(target, now, candidates)
        if not target then return target end
        refreshHostiles(target, candidates)
        local pool = Cast.engineTargets
        if not pool or #pool == 0 then return target end
        if #pool == 1 then
            local only = pool[1].obj
            if only == target or (only.id and target.id and only.id == target.id) then
                return target
            end
        end
        local order, maxDist = TARGET_ORDER, math.max(1, Cfg.maxDist)
        local best, bestScore = target, -math.huge
        local selfX, selfY, selfZ = self.position.x, self.position.y, self.position.z
        for i = 1, #pool do
            local entry = pool[i]
            local obj = entry.obj
            if not obj.isValid or not obj:isValid() or types.Actor.isDead(obj) then
                obj = nil
            end
            if obj then
                local score = 0
                for rank = 1, #order do
                    local factor = order[rank]
                    local v = 0
                    if factor == 'dist' then
                        local dx = obj.position.x - selfX
                        local dy = obj.position.y - selfY
                        local dz = obj.position.z - selfZ
                        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                        v = 1 - math.min(1, d / maxDist)
                    elseif factor == 'hp' then
                        local hp = types.Actor.stats.dynamic.health(obj)
                        if hp and hp.base and hp.base > 0 then
                            local pct = hp.current / hp.base
                            if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
                            v = 1 - pct
                        end
                    elseif factor == 'role' then
                        if entry.role == nil then entry.role = roleOf(obj) and 1 or 0 end
                        v = entry.role
                    else -- threat
                        v = entry.threat or 0
                    end
                    score = score + RANK_W[rank] * v
                end
                if score > bestScore then
                    best, bestScore = obj, score
                end
            end
        end
        return best or target
    end

    return {
        rand01                  = rand01,
        refreshDerived          = refreshDerived,
        isDeclinedSpell          = isDeclinedSpell,
        flagsOf                  = flagsOf,
        hasQualifyingWeakness    = hasQualifyingWeakness,
        weaknessMatchesAvailable = weaknessMatchesAvailableDamage,
        buffDurationQualifies   = buffDurationQualifies,
        damageMatchesTags        = damageMatchesTags,
        addDamageTags            = addDamageTags,
        sequenceState            = sequenceState,
        noteComboCast            = noteComboCast,
        hasWaterBreathing        = hasWaterBreathing,
        submerged                = submerged,
        maybeGrantWaterbreathing = maybeGrantWaterbreathing,
        isTimed                 = isTimed,
        targetEffectKeys        = targetEffectKeys,
        expiryBlocks            = expiryBlocks,
        noteExpiry              = noteExpiry,
        pickCombatTarget        = pickCombatTarget,
        pickAllyCast            = pickAllyCast,
        buffRecastBlocked       = buffRecastBlocked,
        noteBuffCast            = noteBuffCast,
    }
end)()

-- True only when the spell would restore the combat target's Health at Touch
-- or Target range. The cast is aimed at the combat target, so quick-casting a
-- heal there would heal the player (reported with Fair Care's touch-heal
-- spells on Ordinators). Restoration-school buffs are still valid spells, and
-- Absorb/Drain Health remain offensive rather than being mistaken for heals.
local function healsAtNonSelfRange(record)
    for _, effect in ipairs(record.effects or {}) do
        if effect.range ~= RANGE.Self and isRestoreHealthEffect(effect) then return true end
    end
    return false
end

-- ── Public actor API: spell filter + on-demand cast (I.OSSC_Caster) ───────
-- One table for both features: everything below lives inside the closure, so
-- the main chunk pays for exactly one local — the limit that matters is the
-- 200 active locals a Lua function (and a chunk is one) may hold.
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
            -- The blast radius a launch reports is the largest area among the
            -- record's TARGET-range effects (`castRules.impactArea`), the same
            -- rule the quick-cast path uses. `firstEffect.area` was wrong for
            -- every spell whose first effect is not the exploding one -- the
            -- usual layout, e.g. a Self rider in front of a Target blast -- and
            -- those casts reached Spell Framework Plus with `area = 0`, i.e. no
            -- explosion at all.
            area    = castRules.impactArea(record),
            range   = firstEffect and firstEffect.range or RANGE.Self,
        }

        local startPos = getCasterSpawnPos(Cast.currentAnimGroup)
        local direction = self.rotation * Vec.FORWARD
        local hitObject, hitPos = nil, nil
        if spell.range == RANGE.Self then
            targetObj, targetPos = self, self.position
            hitObject, hitPos = self, self.position
        elseif targetPos then
            -- Vanilla parity: aim at the actor's bounding-box centre
            -- (CastSpell::launchMagicBolt), not at a fixed height above its
            -- feet — a bolt aimed low strikes low and its hit effect lands on
            -- the floor at the target's feet.
            local aim = castRules.actorAimPoint(targetObj, Vec.TARGET_AIM_OFFSET.z)
                or (targetPos + Vec.TARGET_AIM_OFFSET)
            direction = (aim - startPos):normalize()
            -- Each eligible target-range cast gets one private 50/50 lead
            -- decision. With a plain position target, or without movement
            -- history, launchDirection returns nil and the plain aim is kept.
            if spell.range == RANGE.Target and targetObj then
                local now = core.getSimulationTime()
                if targetLead.shouldLead(self.id, now) then
                    targetLead.track(targetObj, now)
                    local led = targetLead.launchDirection{
                        startPos      = startPos,
                        aimPoint      = aim,
                        target        = targetObj,
                        effects       = spell.effects,
                        effectRecords = effectRecords,
                        now           = now,
                        gmstBaseSpeed = F_TARGET_SPELL_MAX_SPEED,
                    }
                    if led then direction = led end
                end
            end
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
        -- NPCProjectilesPassThroughBystanders (default on): the same vanilla
        -- rule the quick-cast release applies — a requested Target cast flies
        -- through EVERY actor that is not its target, and those actors are not
        -- affected by it. The launch names its mark and SF+ does the rest (see
        -- the quick-cast release below); `piercing` is never used because it
        -- applies the spell to every actor crossed and cannot be bounded to
        -- stop at the intended target. A caller that already asked for the
        -- pass-through keeps its own request.
        local boltArea = castRules.impactArea(spell)
        if Cfg.projectilesPassThroughBystanders and spell.range == RANGE.Target
            and boltArea <= 0 and not userData.passThroughBystanders then
            userData = castRules.requestBystanderPassThrough(userData, self,
                targetObj)
        end
        -- Who draws the impact: a cast that explodes anywhere is the engine's
        -- blast (each exploding effect's own area static, spawned by SF+'s
        -- detonateSpellAtPos exactly like CastSpell::explodeSpell), so SF+ keeps
        -- it. Only a cast with no area anywhere is taken over by OSSC's hit
        -- statics.
        if spell.range ~= RANGE.Self and not castRules.explodes(spell) then
            userData = impactVfx.requestFor(userData, spell)
        end
        if targetObj and targetObj ~= self then
            core.sendGlobalEvent('OSSC_EnsureHitVfx', { actor = targetObj })
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
            area           = boltArea,
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

-- ── M2 ally pools ──────────────────────────────────────────────────────────
-- Touch/Target spells the caster knows and may hand to the leader: heals
-- (the same test that keeps combat-target heals out of the offense pools)
-- and non-harmful beneficents, using the engine's own harmful flag — the
-- one Friendlier Fire reads too. Declined/ignored/uncastable spells are
-- filtered at build time; the pools rebuild only while the spell list is
-- dirty, so no per-eval scan ever walks the records. (After OSSCExternal:
-- the closure above is what exposes isIgnored.)
local function isHarmfulRecord(record)
    for _, effect in ipairs(record.effects or {}) do
        local mgef = effect.id and effectRecords[effect.id]
        if mgef and mgef.harmful then return true end
    end
    return false
end

local function buildAllyPools()
    Cast.allyPoolsDirty = false
    local heals, buffs = {}, {}
    for spellId in pairs(Cast.knownSpells) do
        local record = spellRecords[spellId]
        local first = record and record.effects[1]
        if first and first.range ~= RANGE.Self
            and not OSSCExternal.isIgnored(spellId)
            and not Tactics.isDeclinedSpell(spellId, record)
            and isCastableSpellType(record) then
            if healsAtNonSelfRange(record) then
                heals[#heals + 1] = record
            elseif not isHarmfulRecord(record) then
                buffs[#buffs + 1] = record
            end
        end
    end
    Cast.allyHeals, Cast.allyBuffs = heals, buffs
end

local function clearList(list)
    for i = #list, 1, -1 do list[i] = nil end
end

-- True when this exact Self buff is still active. isSpellActive(spellId)
-- catches the original record; Spell Framework Plus applies reduced casts
-- under a generated id. Its active-spell display name may be the source name,
-- so identify that copy by (source name + caster + different record id), which
-- stays reliable while individual effects in a multi-effect buff expire. The
-- full-effect fallback compares effect ids plus their affected attribute/skill,
-- so e.g. Fortify Intelligence is not mistaken for Fortify Personality just
-- because both use the Fortify Attribute effect id.
local function selfSpellStillActive(record)
    local active = types.Actor.activeSpells(self)
    if active:isSpellActive(record.id) then return true end
    local baseName = tostring(record.name or record.id or '')
    local baseNameLower = baseName:lower()
    local reducedName = (baseName .. ' (Quick Cast)'):lower()
    local recordIdLower = tostring(record.id or ''):lower()
    local wanted, wantedCount = {}, 0
    local function effectKey(effect)
        return table.concat({
            tostring(effect.id or ''):lower(),
            tostring(effect.affectedAttribute or ''):lower(),
            tostring(effect.affectedSkill or ''):lower(),
        }, '|')
    end
    for _, effect in ipairs(record.effects or {}) do
        if effect.range == RANGE.Self and effect.id then
            local key = effectKey(effect)
            if not wanted[key] then
                wanted[key] = true
                wantedCount = wantedCount + 1
            end
        end
    end
    if wantedCount == 0 then return false end
    for _, activeSpell in pairs(active) do
        local activeName = type(activeSpell.name) == 'string' and activeSpell.name:lower() or ''
        if activeName == reducedName then return true end
        local activeId = tostring(activeSpell.id or '')
        local activeIdLower = activeId:lower()
        local activeRecord = activeId ~= '' and spellRecords[activeId] or nil
        local activeRecordName = activeRecord and type(activeRecord.name) == 'string'
            and activeRecord.name:lower() or ''
        if activeRecordName == reducedName then return true end
        local caster = activeSpell.caster
        local fromThisActor = caster == nil or caster == self
            or (caster.id ~= nil and caster.id == self.id)
        if fromThisActor and activeName == baseNameLower
            and activeIdLower ~= '' and activeIdLower ~= recordIdLower then
            for _, effect in ipairs(activeSpell.effects or {}) do
                if wanted[effectKey(effect)] then return true end
            end
        end
        if fromThisActor then
            local found, seen = 0, {}
            for _, effect in ipairs(activeSpell.effects or {}) do
                local key = effectKey(effect)
                if wanted[key] and not seen[key] then
                    seen[key] = true
                    found = found + 1
                end
            end
            if found == wantedCount then return true end
        end
    end
    return false
end

--- Effect id of `effect`, lowercased and stripped of punctuation, exactly the
--- comparison the other effect tests in this file use (modded ids included).
local function reactionEffectKey(effect)
    if not effect or effect.id == nil then return '' end
    local mgef = effectRecords[effect.id]
    local effectId = mgef and mgef.id or effect.id
    if type(effectId) ~= 'string' then return '' end
    return effectId:lower():gsub('[^%w]', '')
end

--- True when `record` hides its caster (a Self Invisibility or Chameleon
--- effect). Such a spell is an ESCAPE REACTION, never routine buffing: the
--- buff pool casts anything beneficial that is not already running, at any
--- health, which is exactly what "do not cast invisibility unless the actor is
--- at 20% health or less" forbids.
local function isEscapeSpell(record)
    for _, effect in ipairs(record and record.effects or {}) do
        if effect.range == RANGE.Self then
            local key = reactionEffectKey(effect)
            if key:find('invisibility', 1, true) or key:find('chameleon', 1, true) then
                return true
            end
        end
    end
    return false
end

local function categorizeSpells(target, now)
    updateKnownSpellsCache()
    if Cast.knownSpellsDirty then Tactics.refreshDerived() end
    clearList(Spells.heal)
    clearList(Spells.buff)
    clearList(Spells.touch)
    clearList(Spells.target)
    clearList(Spells.priorityTouch)
    clearList(Spells.priorityTarget)
    clearList(Spells.comboTouch)
    clearList(Spells.comboTarget)
    clearList(Spells.comboPickTouch)
    clearList(Spells.comboPickTarget)
    for tag in pairs(Spells.damageTagsTouch) do Spells.damageTagsTouch[tag] = nil end
    for tag in pairs(Spells.damageTagsTarget) do Spells.damageTagsTarget[tag] = nil end
    local magicka = types.Actor.stats.dynamic.magicka(self)
    local magickaCurrent = magicka.current
    -- Fatigue percentage gates Restore Fatigue spells (strictly under the
    -- threshold). An unreadable stat must not silently exclude spells.
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    local fatiguePct = 0
    if fatigue and fatigue.base > 0 then
        fatiguePct = fatigue.current / fatigue.base * 100
    end
    -- Offense eligibility extras (Spell Decision AI): Waterbreathing needs
    -- the caster submerged; the magicka reserve (sustain casters only) stops
    -- offense spends that would eat the headroom — heals and the buff
    -- opening ignore it; the expiry rule blocks re-applying timed effects
    -- still on the target (target effect keys are built at most once per
    -- pass, and only when a timed candidate shows up).
    local submerged = Tactics.submerged()
    local reserveFloor = 0
    if Cast.sustainCaster and Cfg.magickaReservePct > 0 then
        reserveFloor = (Cfg.magickaReservePct / 100) * magicka.base
    end
    now = now or 0
    local targetKeys, targetKeysBuilt = nil, false
    for spellId in pairs(Cast.knownSpells) do
        local record = spellRecords[spellId]
        local firstEffect = record and record.effects[1]
        -- Spells a mod filtered out (I.OSSC_Casters.ignoreSpell) and spells
        -- the player declined (NPCAIDeclinedSpells + built-in family rules,
        -- e.g. Fortify Sneak/Mercantile) are never picked. Mod filters are
        -- skipped silently: the mod that asked for it knows why.
        if firstEffect and not OSSCExternal.isIgnored(spellId)
            and not Tactics.isDeclinedSpell(spellId, record)
            and isCastableSpellType(record) and magickaCurrent >= record.cost then
            local range = firstEffect.range
            local flags = Tactics.flagsOf(record)
            if flags.excludedWeakness then
                -- Weakness to Disease / Blight / Corprus is excluded outright
                -- (user directive): never selected, whatever its magnitude.
                debugLog('Weakness skipped — excluded weakness (Disease/Blight/Corprus): ' .. spellId)
            elseif flags.waterBreathing and not submerged then
                debugLog('Spell skipped — Waterbreathing only while submerged: ' .. spellId)
            elseif flags.weaknessMagnitudes
                and not Tactics.hasQualifyingWeakness(flags) then
                debugLog(('Weakness skipped — needs minimum magnitude of at least %.0f%%: %s')
                    :format(Cfg.weaknessMinMagnitude, spellId))
            elseif not flags.harmful and flags.hasBeneficialEffect
                and not healsAtNonSelfRange(record)
                and not Tactics.buffDurationQualifies(record) then
                debugLog(('Beneficial buff skipped — needs duration of at least %.0fs: %s')
                    :format(Cfg.beneficialBuffMinDuration, spellId))
            elseif hasRestoreFatigueEffect(record) and fatiguePct >= Cfg.restoreFatigueThreshold
                and not hasSelfRestoreHealthEffect(record) then
                -- Maintenance spell at rest: Restore Fatigue is only
                -- considered under the fatigue threshold; at or above it the
                -- spell is left out of every pool (a mixed Self heal still
                -- heals — the health threshold governs that spell).
                debugLog(('Spell skipped — Restore Fatigue needs under %d%% fatigue (%.0f%%): %s')
                    :format(Cfg.restoreFatigueThreshold, fatiguePct, spellId))
            elseif range == RANGE.Self then
                -- INVARIANT (plan §4.10): Reflect and Spell-Absorption Self
                -- spells are BUFFS — every not-active Self spell lands in
                -- the buff pool here, and the decline rules must never
                -- catch them. Active Self effects are an unconditional
                -- no-recast rule: cast the buff once, then leave it alone
                -- until its effects end.
                if isEscapeSpell(record) then
                    -- Invisibility is a DEFENSIVE REACTION, never routine
                    -- buffing: the escape branch of reactionSpell decides it,
                    -- and only at 20% health or less.
                    debugLog('Self spell skipped — invisibility is only cast at 20% health or less: ' .. spellId)
                elseif selfSpellStillActive(record) then
                    debugLog('Self spell skipped — effects still active: ' .. spellId)
                elseif not hasSelfRestoreHealthEffect(record)
                    and Tactics.buffRecastBlocked(record, now) then
                    -- Same-buff recast lockout: the buff is no longer (or
                    -- not detectably) active, but this actor cast it too
                    -- recently to cast it again yet.
                    debugLog('Self spell skipped — same buff cast within recast cooldown: ' .. spellId)
                else
                    local bucket = hasSelfRestoreHealthEffect(record) and Spells.heal or Spells.buff
                    bucket[#bucket + 1] = record
                end
            elseif healsAtNonSelfRange(record) then
                -- Healing is self-only: never quick-cast a heal at the combat
                -- target (it would heal the player).
                debugLog(Anim.RANGE_STRS[range] .. ' heal spell skipped — healing spells are self-only: ' .. spellId)
            elseif range == RANGE.Touch then
                if magickaCurrent - (record.cost or 0) < reserveFloor then
                    debugLog('Spell skipped — magicka reserve: ' .. spellId)
                else
                    local blocked = false
                    if Tactics.isTimed(record) then
                        if not targetKeysBuilt then
                            targetKeysBuilt = true
                            targetKeys = target and Tactics.targetEffectKeys(target) or nil
                        end
                        blocked = Tactics.expiryBlocks(target, now, record, targetKeys)
                    end
                    if blocked then
                        debugLog('Spell skipped — timed effect still on target (expiry): ' .. spellId)
                    elseif flags.comboWeakness
                        and not flags.priorityDamage then
                        -- A PURE Strict Weakness setup is never ordinary
                        -- offense: it is selected only when a usable matching
                        -- damage type exists, then arms the forced follow-up.
                        -- A setup that also deals damage stays ordinary
                        -- offense (it is a damage source itself, so diverting
                        -- it could leave the actor with no legal follow-up and
                        -- stop it casting offense at all).
                        Spells.comboTouch[#Spells.comboTouch + 1] = record
                    else
                        Spells.touch[#Spells.touch + 1] = record
                        if flags.priorityDamage then
                            Spells.priorityTouch[#Spells.priorityTouch + 1] = record
                            Tactics.addDamageTags(flags, Spells.damageTagsTouch)
                        end
                    end
                end
            else
                if magickaCurrent - (record.cost or 0) < reserveFloor then
                    debugLog('Spell skipped — magicka reserve: ' .. spellId)
                else
                    local blocked = false
                    if Tactics.isTimed(record) then
                        if not targetKeysBuilt then
                            targetKeysBuilt = true
                            targetKeys = target and Tactics.targetEffectKeys(target) or nil
                        end
                        blocked = Tactics.expiryBlocks(target, now, record, targetKeys)
                    end
                    if blocked then
                        debugLog('Spell skipped — timed effect still on target (expiry): ' .. spellId)
                    elseif flags.comboWeakness
                        and not flags.priorityDamage then
                        -- Pure setup only; see the Touch branch above.
                        Spells.comboTarget[#Spells.comboTarget + 1] = record
                    else
                        Spells.target[#Spells.target + 1] = record
                        if flags.priorityDamage then
                            Spells.priorityTarget[#Spells.priorityTarget + 1] = record
                            Tactics.addDamageTags(flags, Spells.damageTagsTarget)
                        end
                    end
                end
            end
        end
    end
    debugLogf('Spell pools: heal=%d buff=%d touch=%d (healthDamage=%d combo=%d) target=%d (healthDamage=%d combo=%d)',
        #Spells.heal, #Spells.buff, #Spells.touch, #Spells.priorityTouch,
        #Spells.comboTouch, #Spells.target, #Spells.priorityTarget,
        #Spells.comboTarget)
end

local function pick(list)
    return list[math.random(#list)]
end

-- Weighted pick between Touch and Target pools. Empty categories drop out and
-- the remaining weights are renormalised, so a caster with no Touch spells
-- still uses its Target spells. Taking the two reusable lists directly avoids
-- allocating an options table on every tactical poll.
local function weightedRangeBucket(touchList, targetList)
    local touchWeight = #touchList > 0 and math.max(0, Cfg.tactics.touchChance) or 0
    local targetWeight = #targetList > 0 and math.max(0, Cfg.tactics.touchTargetChance) or 0
    local total = touchWeight + targetWeight
    if total <= 0 then
        -- Every weight is zero (or every weighted bucket is empty): preserve
        -- the existing Touch-first fallback.
        if #touchList > 0 then return touchList, 'touch' end
        if #targetList > 0 then return targetList, 'touch_target' end
        return nil, nil
    end
    local roll = math.random() * total
    if touchWeight > 0 and roll <= touchWeight then return touchList, 'touch' end
    return targetList, 'touch_target'
end

-- ── Reactions (NPCAIReactions) ─────────────────────────────────────────────
-- A reaction is a Self spell used as an ANSWER to danger, not as routine
-- buffing, so it is decided before the offensive pools and it ignores their
-- cooldowns:
--   LowHealth — below the heal threshold, an escape spell
--               (Invisibility / Chameleon) is cast. Vanilla NPCs answer a
--               losing fight by vanishing; without this the setting had no
--               effect at all on an actor whose only Self spells were
--               offensive buffs.
--   Broad     — the same on low health, plus a protective Self spell
--               (Sanctuary / Shield / Reflect / Spell Absorption) whenever an
--               incoming hit landed within REACTION_HIT_WINDOW.
--   Off       — never.
-- The chosen spell must already be legal in every other way (known, castable
-- type, declined/ignored filters, magicka, not already running) — a reaction
-- only changes WHERE the decision sits in the priority order, never whether a
-- spell is allowed.
Combat.REACTION_COOLDOWN   = 6.0
Combat.REACTION_HIT_WINDOW = 2.0

--- Health (percent of maximum) an ESCAPE reaction is allowed at: "low health
--- only (20% and less)". Invisibility is a defensive answer to being nearly
--- dead, not a general-purpose escape — cast at 40% it made the actor stop
--- fighting while it still had a fight in it, and (because any attack breaks
--- it) wasted the magicka. The threshold is the spell's own gate, independent
--- of the heal threshold: healing starts at that one, vanishing only at
--- this one.
Combat.REACTION_ESCAPE_MAX_HEALTH_PCT = 20

--- 'escape' for a hiding spell, 'protection' for a damage-avoidance one.
local function reactionTag(record, broad, healthPct)
    for _, effect in ipairs(record.effects or {}) do
        if effect.range == RANGE.Self then
            local key = reactionEffectKey(effect)
            if key:find('invisibility', 1, true) or key:find('chameleon', 1, true) then
                -- At most 20% health, and never above it (see
                -- REACTION_ESCAPE_MAX_HEALTH_PCT): a spell the actor would
                -- otherwise never pick.
                if healthPct ~= nil
                    and healthPct > Combat.REACTION_ESCAPE_MAX_HEALTH_PCT then
                    return nil
                end
                return 'escape'
            elseif broad and (key:find('sanctuary', 1, true)
                or key:find('shield', 1, true) or key:find('reflect', 1, true)
                or key:find('spellabsorption', 1, true)) then
                return 'protection'
            end
        end
    end
    return nil
end

--- The Self spell this reaction would cast right now, or nil.
--- The cheapest eligible candidate wins, so a reaction never burns the
--- caster's whole magicka reserve on the first answer.
local function reactionSpell(now)
    if Cfg.reactions == 'Off' then return nil, nil end
    local health = types.Actor.stats.dynamic.health(self)
    local healthPct = health.current / math.max(1, health.base) * 100
    local lowHealth = healthPct < Cfg.healThresholdPct
    local hit = Cast.lastIncomingHitAt ~= nil
        and (now - Cast.lastIncomingHitAt) <= Combat.REACTION_HIT_WINDOW
    if not hit then Cast.lastIncomingHitAt = nil end
    local broad = Cfg.reactions == 'Broad'
    if broad then
        if not (lowHealth or hit) then return nil, nil end
    elseif not lowHealth then
        return nil, nil
    end
    if now < Cast.nextReactionAt then return nil, nil end
    local magicka = types.Actor.stats.dynamic.magicka(self)
    local best, bestCost, bestTag
    for spellId in pairs(Cast.knownSpells) do
        local record = spellRecords[spellId]
        local firstEffect = record and record.effects[1]
        if firstEffect and firstEffect.range == RANGE.Self
            and isCastableSpellType(record)
            and not OSSCExternal.isIgnored(spellId)
            and not Tactics.isDeclinedSpell(spellId, record)
            and magicka.current >= (record.cost or 0)
            and not selfSpellStillActive(record) then
            local tag = reactionTag(record, broad, healthPct)
            local cost = record.cost or 0
            if tag and (best == nil or cost < bestCost) then
                best, bestCost, bestTag = record, cost, tag
            end
        end
    end
    return best, bestTag
end

-- Tactical selection, in strict priority order:
--   1. A needed Self heal below the heal threshold.
--   2. Every Self buff that is not already active, one at a time. Active buffs
--      are never re-cast; once all are running, selection advances to offense.
--   3. A pending Strict Sequence follow-up, or a qualifying Weakness setup.
--   4. Eligible Health-damaging offense (Damage Health, Fire/Frost/Shock
--      Damage or Poison) before secondary offense such as Damage Attribute.
--   5. In vanilla touch reach, a Touch or Target spell using their relative
--      touch-band weights. Outside touch reach, only Target spells are eligible.
-- This keeps Touch spells inside the GMST-based vanilla contact range and
-- makes a caster prepare with its buffs before attacking.
local function selectTacticalSpell(target, now, reaction)
    categorizeSpells(target, now)
    -- A reaction outranks every ordinary pool, including the needed heal: an
    -- escape spell is what lets the caster survive the next hit at all, and a
    -- Self heal can still follow it once the caster is out of sight.
    if reaction then return reaction, 'reaction' end
    local health = types.Actor.stats.dynamic.health(self)
    local healthPct = health.current / math.max(1, health.base) * 100
    if healthPct < Cfg.healThresholdPct and #Spells.heal > 0 then
        return pick(Spells.heal), 'heal'
    end
    if #Spells.buff > 0 then return pick(Spells.buff), 'buff' end

    -- Use the same vanilla touch test as Touch spell validation. Its distance
    -- threshold comes from fCombatDistance × fHandToHandReach, capped by
    -- iMaxActivateDist and checked with vanilla contact/cone/LOS rules — not
    -- the unrelated quick-cast chance bands.
    local inTouchReach = target ~= nil and isTouchTargetInReach(target)

    -- A committed Strict Sequence owns the next offensive choice. It does not
    -- release a nuke merely because the setup was cast: the matching weakness
    -- must be visible on this target first. If the projectile missed or the
    -- matching damage is temporarily unavailable, wait until the sequence
    -- succeeds or its bounded window expires; heals/buffs above still work.
    local sequenceTags, weaknessLanded = Tactics.sequenceState(target, now)
    if sequenceTags then
        if not weaknessLanded then return nil, 'strict_wait' end
        for i = 1, #Spells.priorityTouch do
            local record = Spells.priorityTouch[i]
            if Tactics.damageMatchesTags(Tactics.flagsOf(record), sequenceTags) then
                Spells.comboPickTouch[#Spells.comboPickTouch + 1] = record
            end
        end
        for i = 1, #Spells.priorityTarget do
            local record = Spells.priorityTarget[i]
            if Tactics.damageMatchesTags(Tactics.flagsOf(record), sequenceTags) then
                Spells.comboPickTarget[#Spells.comboPickTarget + 1] = record
            end
        end
        if not inTouchReach then
            if #Spells.comboPickTarget > 0 then
                return pick(Spells.comboPickTarget), 'strict_damage'
            end
            return nil, 'strict_wait'
        end
        local followup = weightedRangeBucket(
            Spells.comboPickTouch, Spells.comboPickTarget)
        if followup then return pick(followup), 'strict_damage' end
        return nil, 'strict_wait'
    end

    -- Without a pending follow-up, Strict Sequences gets first chance to set
    -- one up. Filter strong-enough weakness spells against the damage tags that
    -- survived every current eligibility gate. A weakness with no usable
    -- same-type damage spell is therefore never selected. This is the only
    -- mode: Combo Chains is fixed to Strict Sequences, so there is no switch
    -- to skip it.
    for i = 1, #Spells.comboTouch do
        local record = Spells.comboTouch[i]
        if Tactics.weaknessMatchesAvailable(Tactics.flagsOf(record), inTouchReach) then
            Spells.comboPickTouch[#Spells.comboPickTouch + 1] = record
        end
    end
    for i = 1, #Spells.comboTarget do
        local record = Spells.comboTarget[i]
        if Tactics.weaknessMatchesAvailable(Tactics.flagsOf(record), inTouchReach) then
            Spells.comboPickTarget[#Spells.comboPickTarget + 1] = record
        end
    end
    if not inTouchReach then
        if #Spells.comboPickTarget > 0 then
            return pick(Spells.comboPickTarget), 'strict_weakness'
        end
    elseif #Spells.comboPickTouch > 0 or #Spells.comboPickTarget > 0 then
        local setup = weightedRangeBucket(
            Spells.comboPickTouch, Spells.comboPickTarget)
        if setup then return pick(setup), 'strict_weakness' end
    end

    if not inTouchReach then
        if #Spells.priorityTarget > 0 then
            return pick(Spells.priorityTarget), 'ranged_target'
        end
        if #Spells.target > 0 then return pick(Spells.target), 'ranged_target' end
        return nil, 'none'
    end

    -- Apply the damage tier BEFORE choosing Touch versus Target. Otherwise a
    -- high Touch weight can still let Damage Attribute beat a legal Target
    -- Fire spell (the reported failure). If either priority subset is non-
    -- empty, secondary offense is absent from both range buckets for this
    -- decision; normal range weights still choose between priority Touch and
    -- priority Target spells.
    local touchPool, targetPool = Spells.touch, Spells.target
    if #Spells.priorityTouch > 0 or #Spells.priorityTarget > 0 then
        touchPool, targetPool = Spells.priorityTouch, Spells.priorityTarget
    end
    local chosen, tag = weightedRangeBucket(touchPool, targetPool)
    if not chosen then return nil, 'none' end
    return pick(chosen), tag
end

-- ── Firing ─────────────────────────────────────────────────────────────────
local CAST_USER_DATA = { OSSC = true, NPC = true }

local function fireSpellPayload()
    if Cast.hasFiredThisCast or not Cast.isCasting then return end
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
    if core.getSimulationTime() < Cast.reentryGuardUntil then
        debugLog('fireSpellPayload suppressed — inside reentry guard window')
        cleanupCast('reentry guard')
        return
    end
    Cast.hasFiredThisCast = true
    local spell = Cast.currentSpell
    local range = Cast.currentRange
    local startPos = getCasterSpawnPos(Cast.currentAnimGroup)
    local direction = self.rotation * Vec.FORWARD
    local target, hitObject = nil, nil
    -- Where the bolt is aimed (target position + the shared aim offset); kept
    -- outside the branch so the bystander walk can use the exact launch line.
    local aimPoint = nil
    if range == RANGE.Self then
        target, hitObject = self, self
    else
        -- M2: aim at the target chosen at evaluation time; fall back to the
        -- live engine combat target if it went stale/invalid mid-cast (the
        -- protection guard upstream already vetted the engine target).
        local aimed = Cast.aimTarget
        if not aimed or not aimed:isValid() or types.Actor.isDead(aimed) then
            aimed = getCombatTarget()
        end
        target = aimed
        if target then
            -- Vanilla parity (CastSpell::launchMagicBolt): the bolt is aimed
            -- at the actor's bounding-box CENTRE, which is also the impact
            -- point Spell Framework Plus anchors the hit effect on. The old
            -- fixed +70 landed wherever that happened to be on that body —
            -- low on a tall actor, on the ground for a short one.
            local aim = castRules.actorAimPoint(target, Vec.TARGET_AIM_OFFSET.z)
                or (target.position + Vec.TARGET_AIM_OFFSET)
            aimPoint = aim
            direction = (aim - startPos):normalize()
            -- Each target-range cast gets one private 50/50 decision; the
            -- direction, hitObject and aim offset otherwise stay unchanged.
            if range == RANGE.Target then
                local now = core.getSimulationTime()
                if targetLead.shouldLead(self.id, now) then
                    targetLead.track(target, now)
                    local led = targetLead.launchDirection{
                        startPos      = startPos,
                        aimPoint      = aim,
                        target        = target,
                        effects       = spell.effects,
                        effectRecords = effectRecords,
                        now           = now,
                        gmstBaseSpeed = F_TARGET_SPELL_MAX_SPEED,
                    }
                    if led then
                        direction = led
                        debugLogf('Moving-target lead applied: %s', tostring(target.recordId))
                    end
                end
            end
            if range == RANGE.Touch then
                -- Release-time reach check (player parity: the crosshair
                -- target is dropped when it is out of touch reach at the
                -- release moment, the gesture and the costs stay). Out of
                -- reach → no hitObject → the cast fizzles below.
                if isTouchTargetInReach(target) then
                    hitObject = target
                else
                    debugLog('Touch target out of reach at release: ' .. tostring(target.recordId))
                    target = nil
                end
            end
            if target and friendlyFire.isFriendlyFireBlocked(self, target, spell.effects) then
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
    -- pays the same MCP fatigue cost as the player's — sure casts included.
    Cfg.costs.payFatigue(cost)
    -- QuickCastChancePenalty (Gameplay settings): when enabled, the release
    -- is rolled exactly like the player's — vanilla base cast chance times
    -- the penalty scale. A failure keeps magicka and fatigue consumed and
    -- fizzles with the vanilla failure sound (player parity: the gesture
    -- played, the costs were paid, the spell does not land). While the
    -- setting is 'off' the cast lands unconditionally, as before. Sure casts
    -- (abilities, powers, Always Succeeds spells) are the one exemption from
    -- this chance roll: vanilla never rolls them, so they land
    -- unconditionally whatever the chance penalty says.
    if not isSureCastSpell(spell) and Cfg.costs.penaltyActive() then
        local baseChance, effectiveSchool = Cfg.costs.baseChance(spell)
        local chanceScale = Cfg.costs.chanceScale(effectiveSchool)
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
    if range == RANGE.Touch and not hitObject then
        -- Player parity: a Touch cast released with nothing in reach has paid
        -- its magicka/fatigue and fizzles — no effect, no target.
        core.sound.playSound3d('Spell Failure', self, { volume = 1.0 })
        cleanupCast('touch fizzled — nothing in reach')
        return
    end
    local effectScale = getQuickCastEffectScale(spell)
    -- NPCProjectilesPassThroughBystanders (default on, vanilla parity): a bolt
    -- aimed at this actor's own target must not be eaten by somebody standing
    -- in the line of fire, and that somebody must not be hurt either.
    --
    -- The setting toggles exactly one thing: the launch names the actor it was
    -- aimed at (`userData.targetObject`) and asks Spell Framework Plus for the
    -- pass-through (`userData.passThroughBystanders`). SF+ then flies the bolt
    -- through EVERY actor that is not that mark — beside it, in front of it,
    -- sharing its record id — and stops it on the mark. No scan, no radius and
    -- no record-id list decides who is a bystander, so nothing can leave one
    -- out and nothing can make the bolt fly past the actor it was aimed at.
    --
    -- The mark is the target the Combat AI chose: OSSC only ever quick-casts at
    -- actors from `getActiveTarget`/`getTargets('Combat')`.
    --
    -- SF+'s `piercing` modifier is deliberately NOT used. It does not mean
    -- "fly through nothing"; it means "keep flying and apply the spell to every
    -- actor crossed" (`MagExp_OnProjectilePierce` -> `applySpellToActor`), and
    -- the only thing that ends it is a pierce budget counted per actor met. So
    -- enabling it made bolts pierce — and damage — the enemy they were aimed
    -- at, and even burned through to whoever stood behind.
    --
    -- With the setting off nothing is sent: physics decides, and the first
    -- living actor the bolt meets takes the spell.
    local userData = CAST_USER_DATA
    -- The blast radius Spell Framework Plus will use for this launch. An area
    -- spell must keep the ordinary collision (its blast detonates where it
    -- lands), so it is also what switches the pass-through below off.
    local boltArea = castRules.impactArea(spell)
    if Cfg.projectilesPassThroughBystanders and range == RANGE.Target
        and boltArea <= 0 then
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
    -- VFX if that actor can interpret its AddVfx event; the global side
    -- attaches the handler (only a global script may).
    if target and target ~= self then
        core.sendGlobalEvent('OSSC_EnsureHitVfx', { actor = target })
    end
    debugLogf('QUICKCAST DISPATCHED: Spell=%s Range=%d MagickaRemaining=%.0f/%.0f Target=%s',
        spell.id, range, magicka.current, magicka.base, target and tostring(target.recordId) or 'none')
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker       = self,
        caster         = self,
        spellId        = spell.id,
        startPos       = startPos,
        direction      = direction,
        area           = boltArea,
        isFree         = true,
        hitObject      = hitObject,
        -- The impact point the bolt is aimed at (mid-actor), so downstream
        -- impact/hit-effect code has the same centre the aim used.
        hitPos         = range ~= RANGE.Self and aimPoint or nil,
        isGodMode      = false,
        effectScale    = effectScale,
        showAllCastVfx = true,
        userData       = userData,
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
    local mode = settingOr(Cfg.general, 'ShieldCastingPenalty', 'off')
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
    if Cfg.randomAnims then
        if not Anim.rolled then rollAnimSet() end
        local rolled = Anim.rolled[school]
        local group = rolled and rolled[range]
        if group and group ~= '' then return group end
    end
    local keys = Anim.SETTING_KEYS[school]
    local group = keys and Cfg.anim:get(keys[range])
    if group and group ~= '' then return group end
    local bySchool = Anim.BY_SCHOOL_AND_RANGE[school]
    if bySchool and bySchool[range] then return bySchool[range] end
    if range == RANGE.Self then return 'quickbuff' end
    return 'quickcast'
end

local function getCastSpeed(group, school)
    local speed = (Cfg.animSpeed:get(Anim.SPEED_KEYS[group] or 'AnimSpeed_Quickcast') or 1.0)
        * (Cfg.animSpeed:get('AnimSpeedScale') or 1.0)
        * getShieldCastingPenaltyMult(school)
    if speed <= 0 then return 1.0 end
    -- Clamp so the finish timer can never grow past ~12 s (the global script's
    -- safe-detach window assumes bounded cast timers): the finish fallback is
    -- castRules.FINISH_FALLBACK, and 2.4 / 0.2 is that same 12 s bound.
    if speed < 0.2 then return 0.2 end
    return speed
end

-- NPC cast blend — the SAME rule the player script uses:
--   * LeftArm + RightArm + Torso at PRIORITY.Hit (6) normally. This beats
--     weapon-stance idles, but stays below PRIORITY.Weapon (7) so a real
--     weapon attack can still win its bones.
--   * When a 1H / H2H / thrown attack is playing, or a 1H charge is held
--     (the wind-up parks on a text key and anim.isPlaying() is false), the
--     cast is LeftArm-ONLY. Claiming RightArm/Torso there used to make the
--     quickcast disappear entirely while VFX kept playing.
--   * Relaxed/Nothing stance also uses the casting hand alone, exactly like
--     ossc_player.buildCastBlendOptions. 'eqcastr' keeps its right-hand rule.
--   * LowerBody is NOT in the blend mask: NPC locomotion keeps its root
--     motion for the whole cast.
-- Every bone in the mask gets an explicit priority: playBlended seeds
-- unlisted groups with PRIORITY.Default (0). The shared helper in
-- ossc_cast_rules.lua builds the fresh options table for every cast.
Cast.playOptions = nil
Cast.castSpeed   = 1.0

local function prepareCastPlayOptions(speed, group)
    -- Attack override: a quick-cast ALWAYS outranks weapon attacks (the
    -- setting is gone). The cast is played one priority step ABOVE
    -- PRIORITY.Weapon and claims the whole upper body — without it an attack
    -- animation that is already running (Mercy CAO swings its own weapons every
    -- few seconds) out-ranks the cast on RightArm/Torso and the quickcast never
    -- becomes visible even though its text keys, VFX and payload all ran.
    local override = true
    local preserve = false
    local opts = castRules.buildCastBlendOptions{
        speed          = speed,
        animGroup      = group,
        -- Pre-press stance captured before startQuickcast draws a weapon.
        stance         = Cast.lastNonSpellStance,
        preserveAttack = preserve,
        attackOverride = override,
        -- A ready / unready transition in flight keeps RightArm + Torso: the
        -- cast stays on the casting hand instead of freezing the draw.
        weaponTransition = castRules.drawTransitionActive(Cast.drawTransition),
        -- No LowerBody claim: movement/root motion must survive the cast.
        lowerBody      = false,
    }
    Cast.playOptions = opts
    if Cfg.debugMode then
        debugLogf('Cast blend: %s (mask=%d, armPriority=%s, override=%s, '
            .. 'preserveAttack=%s)',
            tostring(group), tostring(opts.blendMask),
            tostring(opts.priority[anim.BONE_GROUP.LeftArm]),
            tostring(override), tostring(preserve))
    end
end

local function playCastAnimation(group, speed)
    prepareCastPlayOptions(speed, group)
    local controller = I.AnimationController
    if controller and controller.playBlendedAnimation then
        controller.playBlendedAnimation(group, Cast.playOptions)
    elseif anim.playBlended then
        anim.playBlended(self, group, Cast.playOptions)
    end
    anim.setSpeed(self, group, speed)
end

-- A skeleton without the rolled/configured group plays nothing: fall back to
-- the two groups every OSSC animation set ships.
local function onFallbackTimer(castId)
    if not Cast.isCasting or Cast.currentCastId ~= castId then return end
    if anim.isPlaying(self, Cast.currentAnimGroup) then return end
    Cast.currentAnimGroup = Cast.currentRange == RANGE.Self and 'quickbuff' or 'quickcast'
    playCastAnimation(Cast.currentAnimGroup, Cast.castSpeed or 1.0)
end

local function onReleaseTimer(castId)
    if not Cast.isCasting or Cast.currentCastId ~= castId or Cast.hasFiredThisCast then return end
    fireSpellPayload()
end

local function onFinishTimer(castId)
    if not Cast.isCasting or Cast.currentCastId ~= castId then return end
    if not Cast.hasFiredThisCast then fireSpellPayload() end
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
    if not settingOr(Cfg.general, 'BlockTargetSpellsWhileSwimming', true) then return false end
    return hasTargetRangeEffect(spell) and types.Actor.isSwimming(self)
end

local function startQuickcast(spell, target)
    if Cast.isCasting then return end
    -- Defense in depth for direct callers and races: the vanilla Spell stance
    -- always belongs to the engine's cast, never to an OSSC quick-cast.
    if Combat.vanillaSpellStanceActive() then
        debugLog('Cast blocked — vanilla Spell stance: engine owns this cast')
        return
    end
    -- A caster standing in the engine's Spell stance never starts a quick-cast
    -- animation, whoever owns the spell list: the stance IS a spell being
    -- readied, and blending OSSC's gesture over it put two animations on the
    -- same arms. The Mercy CAO window leaves Spell stance BEFORE it casts (it
    -- swaps to Weapon first), so a yielded window is unaffected.
    if not castRules.quickcastStanceAllowed(types.Actor.getStance(self),
                                              Cfg.allowCastInSpellStance) then
        debugLog('Cast blocked — Spell stance: leave spell stance to quick-cast')
        return
    end
    if swimmingBlocksCast(spell) then
        debugLog('Cast blocked — swimming: target spells cannot be quick-cast')
        return
    end
    -- Mod cast veto (see ossc_cast_rules.castPayload): another mod's rule about
    -- what this actor may cast, asked before anything is paid or played.
    if castRules.hasCastVeto() then
        local payload = castRules.castPayload(spell,
            { source = 'npc', caster = self })
        local vetoAllowed, vetoReason, vetoMessage =
            castRules.checkCastVeto(payload)
        if not vetoAllowed then
            castRules.reportVetoedCast(self, payload, vetoReason, vetoMessage, {
                log    = debugLog,
                fizzle = settingOr(Cfg.general, 'CastVetoFeedback', 'Vanilla') ~= 'Silent',
            })
            return
        end
    end
    local firstEffect = spell.effects[1]
    local range = firstEffect.range
    local school = schoolName(effectRecords[firstEffect.id])
    local group = chooseAnimGroup(school, range)
    local speed = getCastSpeed(group, school)

    Cast.isCasting = true
    Cast.hasFiredThisCast = false
    Cast.currentSpell = spell
    Cast.currentAnimGroup = group
    Cast.currentRange = range
    -- M2: the aim decided at evaluation time travels with the cast; the
    -- payload re-reads it at release instead of re-deriving the engine
    -- combat target (Self spells store nil — they never aim).
    Cast.aimTarget = (range ~= RANGE.Self) and target or nil
    Cast.currentCastId = Cast.currentCastId + 1
    local castId = Cast.currentCastId
    Cast.attackSuppressedDuringCast = false

    local now = core.getSimulationTime()
    -- The animation's own `Release` text key is the authoritative moment the
    -- hand is forward; these timers are only the fallback for a cast whose keys
    -- never arrive (no animation, a blended group the engine does not report,
    -- a lost key). They therefore sit AFTER the authored keys of the shipped
    -- animations (release 0.80-1.10 s, stop 1.90-2.33 s from the group's
    -- Start — see castRules.castTimings), so the key always wins the race and
    -- the bolt leaves the hand on the gesture, not before it.
    local releaseDelay, finishDelay = castRules.castTimings(speed)
    Cast.pendingTimersUntil = math.max(Cast.pendingTimersUntil, now + finishDelay + 0.3)
    -- Hard deadline for the whole cast (and for the heavy-attack block it
    -- arms): if the finish timer is lost, the watchdog in onUpdate resolves
    -- the cast here instead of leaving the actor unable to swing again.
    Cast.deadline = now + finishDelay + Anim.deadlineMargin
    -- A cast that actually started owns the rest of the Mercy window. Extend
    -- the safety timeout past the cast deadline so the window never expires
    -- mid-gesture, but cleanupCast still closes it at its natural 'stop' key.
    if Cast.mercyWindowActive then
        Cast.mercyWindowStage = 'casting'
        Cast.mercyWindowUntil = math.max(Cast.mercyWindowUntil,
            Cast.deadline + 0.5)
        debugLog('Mercy quick-cast window committed to cast')
    end

    local stance = types.Actor.getStance(self)
    if stance == STANCE.Weapon or stance == STANCE.Nothing then Cast.lastNonSpellStance = stance end
    types.Actor.clearSelectedCastable(self)
    -- Mercy CAO picks the draw state while it drives this actor, and the
    -- engine's setStance interrupts an attack being prepared — for a
    -- Mercy-driven NPC that is the swing Mercy is winding up. Spell stance
    -- was vetoed above; never take it away from a vanilla cast here.
    if mercyOwnsBody() then
        Cast.mercyCast = true
    else
        Cast.mercyCast = false
        if stance ~= STANCE.Spell then
            types.Actor.setStance(self, STANCE.Weapon)
        end
    end
    -- Invisibility is broken by CASTING, exactly as the player's own cast
    -- breaks it (ossc_player.lua sends the same event at cast start; vanilla
    -- only breaks it on an attack, which is why an actor could quick-cast while
    -- invisible without ever being revealed). Sent at the commit point, after
    -- every gate above has passed, so a blocked cast never reveals the actor.
    core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = self })
    Cast.isBound2HWeaponCast = hasBound2HWeaponEffect(spell)
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
        Cast.castSpeed = speed
        playCastAnimation(group, speed)
        async:newUnsavableSimulationTimer(0.01, function() onFallbackTimer(castId) end)
    else
        -- Non-biped skeletons carry none of the quickcast animation groups:
        -- the release/finish timers below drive the cast on their own.
        debugLog('Non-biped cast — no cast animation available, timers drive the cast')
    end
    async:newUnsavableSimulationTimer(releaseDelay, function() onReleaseTimer(castId) end)
    async:newUnsavableSimulationTimer(finishDelay, function() onFinishTimer(castId) end)
end

-- Text keys that end a quick-cast are only honoured once the engine is
-- actually playing that cast group. A stale 'release' / 'stop' of the previous
-- cast can arrive on the same frame the next one starts (the engine keeps
-- sending keys of a play it ended), and it used to unlock the new cast before
-- its own gesture had played a single frame — the "first quick-cast after
-- taking control fires mid-draw" symptom in the field log.
local function animPlaying(groupname)
    if type(anim.isPlaying) ~= 'function' then return true end
    return anim.isPlaying(self, groupname) == true
end

local function onTextKey(groupname, key)
    if not Cast.isCasting or groupname ~= Cast.currentAnimGroup then return end
    local k = tostring(key):lower()
    if (k == 'release' or k == 'stop') and not animPlaying(groupname) then
        -- The safety/finish timers resolve this cast if the group never plays.
        debugLog('TextKey [' .. groupname .. "] '" .. k
            .. "' ignored — the cast group is not playing")
        return
    end
    if k == 'start' or k == 'equip start' then
        playCastSoundOnce(Cast.currentSpell)
    elseif k == 'release' then
        fireSpellPayload()
    elseif k == 'stop' then
        if not Cast.hasFiredThisCast then fireSpellPayload() end
        cleanupCast('stop key')
    end
end

-- ── Combat evaluation ──────────────────────────────────────────────────────
local function castChance(distance)
    if distance <= Cfg.minDist then return Cfg.baseChance end
    if distance > Cfg.maxDist then return 0 end
    local ratio = (distance - Cfg.minDist) / math.max(1, Cfg.maxDist - Cfg.minDist)
    local chance = Cfg.baseChance * (1 - ratio)
    -- Defence in depth: refreshSettings nests the bands, but a hand-edited
    -- setting must never turn the distance roll into a certainty or a
    -- negative chance.
    if chance < 0 then return 0 end
    if chance > Cfg.baseChance then return Cfg.baseChance end
    return chance
end

local function evaluateCombatQuickcast(now, target)
    if Cast.isCasting or isActorIncapacitated() then return end
    -- A local script can attach before deferred Actor.spells():add() calls
    -- land. Retry here as well as on the 1 Hz settings refresh, so the first
    -- tactical poll after the spells appear can actually cast.
    if knownSpellCount() == 0 then
        updateKnownSpellsCache()
        if knownSpellCount() == 0 then
            debugGate(now, 'no cached castable spells (Actor.spells() empty or undecoded)')
            return
        end
    end
    -- Vanilla Spell stance is the engine's cast. No RNG, cooldown or stance
    -- write may happen on top of it.
    if Combat.vanillaSpellStanceActive() then
        debugLog('Cast blocked — vanilla Spell stance: engine owns this cast')
        return
    end
    -- Spell stance is never quick-cast from, whatever owns the spell list; the
    -- per-cast gate in startQuickcast repeats this for direct callers.
    if not castRules.quickcastStanceAllowed(types.Actor.getStance(self),
                                              Cfg.allowCastInSpellStance) then
        debugGate(now, 'Spell stance — leave spell stance to quick-cast')
        return
    end
    -- A mod just refused a cast from this actor: do not re-ask the veto (and do
    -- not consume RNG, or fizzle the same failure sound) several times a second
    -- while the refusal stands.
    if castRules.hasCastVeto() and castRules.vetoRecentlyRefused(self, now) then
        debugGate(now, 'cast refused by a mod moments ago')
        return
    end
    -- Fleeing (engine ActionFlee): pause quick-casting entirely — movement
    -- stays clean, matching vanilla (nothing is cast while fleeing). No RNG
    -- is consumed on a fleeing eval. Absent API (older harnesses) = no pause.
    if self._isFleeing and self:_isFleeing() then
        debugLog('Cast paused — actor is fleeing')
        return
    end
    if combatAnimBlocksCast(now) then return end
    -- Cell re-entry guard (resetAfterActivation): the window right after
    -- onInit/onLoad/onActive, where the engine can still restore transient
    -- stance/selection state and where fireSpellPayload refuses to launch a
    -- projectile into a cell transition. A cast that STARTED inside the
    -- window was pure waste — the gesture played, the cooldown burned and the
    -- release fizzled on the guard. Start nothing until the window closes.
    if now < Cast.reentryGuardUntil then
        -- The guard doubles as the combat opening: its duration is the
        -- one second after combat attach before buffing may start. Pin the
        -- next evaluation to the moment it expires so the first cast attempts
        -- exactly at that mark instead of drifting to the next poll tick.
        Cast.nextActionTime = math.min(Cast.nextActionTime, Cast.reentryGuardUntil)
        return
    end
    if shouldBlockDuringNgardeParry() then
        debugLog('Cast blocked — NGarde parry is active')
        return
    end
    -- Resolve the cast aim BEFORE any distance math — chance, spell
    -- scoring, LOS, expiry notes and the payload all share one target.
    -- Target-range spells may use ANY live engine Combat target with LOS,
    -- not just the active package target: the AI target list is exactly
    -- how the engine reports another actor/player this actor sees.
    local visibleTargets = Combat.collectVisibleTargets()
    -- Self buffs and leader support do not need an enemy in sight: keep
    -- evaluating those even when the AI has no visible Combat target. Only
    -- offensive (Touch/Target) spells are gated on the visible pool below.
    local aim
    if #visibleTargets > 0 then
        aim = Tactics.pickCombatTarget(visibleTargets[1], now, visibleTargets)
    else
        -- Refresh the engine target pool for ally scoring, but keep a
        -- zero-distance aim so a Self buff never inherits a distant target's
        -- cast-chance roll.
        Tactics.pickCombatTarget(target or self, now, nil)
        aim = self
        debugLog('No visible live combat target — only Self/ally casts remain eligible')
    end
    local distance = (aim.position - self.position):length()
    local chance = castChance(distance)
    if Cfg.debugMode then
        local magicka = types.Actor.stats.dynamic.magicka(self)
        debugLogf('Eval tick: Dist=%.1f Chance=%.1f%% Cooldown=%.2fs Target=%s Magicka=%.0f/%.0f Stance=%s',
            distance, chance * 100, math.max(0, Cast.nextCastAllowedTime - now), tostring(aim.recordId),
            magicka.current, magicka.base, tostring(types.Actor.getStance(self)))
    end
    if core.isWorldPaused() or not Cfg.enabled or chance <= 0 then return end
    -- Peek whether the pending selection is a Self buff, WITHOUT touching the
    -- RNG: buffs bypass both the cooldown and the chance roll below, and every
    -- non-buff eval must keep drawing exactly like it did before (the roll and
    -- the tactical pick keep their old order and count — the peek adds no
    -- draws). The mirror of selectTacticalSpell's priority head: a needed Self
    -- heal always wins over buffs.
    -- One grant attempt per eval, before the pools are read, so a freshly
    -- granted Waterbreathing spell is available to this very selection.
    Tactics.maybeGrantWaterbreathing()
    categorizeSpells(aim, now)
    -- Decided here, before the cooldown/chance gates, because a reaction is
    -- not part of the offense rhythm (see reactionSpell).
    local reaction = reactionSpell(now)
    if #Spells.heal == 0 and #Spells.buff == 0 and #Spells.touch == 0
        and #Spells.target == 0 and #Spells.comboTouch == 0
        and #Spells.comboTarget == 0 then
        debugGate(now,
            'cached spells exist but none are eligible (ignored/declined/cost/effects)')
    end
    if Cast.allyPoolsDirty then buildAllyPools() end
    local peekHealth = types.Actor.stats.dynamic.health(self)
    local peekHealPct = peekHealth.current / math.max(1, peekHealth.base) * 100
    local healWins = peekHealPct < Cfg.healThresholdPct
        and #Spells.heal > 0 and reaction == nil
    -- M2 ally casting: leader-only support, evaluated after the self-heal
    -- priority is known (a dying caster never spends its cast on someone
    -- else) and before the buff rhythm and the roll. The leader's LOS is
    -- checked here: a blocked leader just drops this poll's ally attempt
    -- and the combat path proceeds untouched — the extra raycast happens
    -- only when an ally cast was a real candidate.
    local allyLeader, allySpell, allyIsBuff
    if not healWins and reaction == nil then
        allyLeader, allySpell, allyIsBuff = Tactics.pickAllyCast(now)
        if allySpell and allySpell.effects[1].range ~= RANGE.Self
            and not hasLineOfSight(getCasterSpawnPos(nil),
                allyLeader.position + Vec.LOS_TARGET_OFFSET, allyLeader) then
            allySpell = nil
        end
    end
    local isBuff
    if allySpell then
        isBuff = allyIsBuff
    else
        isBuff = reaction == nil and #Spells.buff > 0 and not healWins
    end
    if isBuff then
        if now < Cast.nextBuffAllowedTime then
            -- Flat rhythm: wake exactly when the buff spacing ends so the
            -- poll interval cannot stretch the 2.2 s between buff casts.
            Cast.nextActionTime = math.min(Cast.nextActionTime, Cast.nextBuffAllowedTime)
            return
        end
    elseif reaction == nil and now < Cast.nextCastAllowedTime then
        return
    end
    -- Missing Self buffs also ignore the distance chance roll: combat must
    -- open with the buff routine on schedule (one second after it begins),
    -- never waiting for a lucky roll at range. Offense and heals keep it.
    -- A reaction ignores both the cooldown and the roll for the same reason:
    -- waiting for a lucky roll while being hit is how an actor dies instead.
    local roll = chance
    if not isBuff and reaction == nil then
        roll = math.random()
        if roll > chance then return end
    end
    local spell, strategy, aimTarget
    if allySpell then
        -- The leader already passed its LOS check above, and the ally path
        -- never enters selectTacticalSpell — the tactical RNG stream is
        -- untouched whenever no leader conditions are met (the harness
        -- case, and every actor without a Follow package).
        spell, strategy, aimTarget = allySpell,
            allyIsBuff and 'allyBuff' or 'allyHeal', allyLeader
    else
        spell, strategy = selectTacticalSpell(aim, now, reaction)
        aimTarget = aim
    end
    if not spell then return end
    -- Invisible and the player can see this actor: every cast would break the
    -- invisibility (startQuickcast), so only a heal the actor needs to stay
    -- alive is still allowed. Everything else waits for the player to look
    -- away, which is what releases the hold (Combat.updateHidden).
    if Cast.hiddenHold and strategy ~= 'heal' and strategy ~= 'allyHeal' then
        debugLogf('Cast withheld — invisible and the player can see this actor '
            .. '(would have cast %s as %s)', tostring(spell.id), tostring(strategy))
        return
    end
    if not allySpell and spell.effects[1].range ~= RANGE.Self then
        -- Visibility is a Target/Touch-spell requirement, not a blanket
        -- precondition for the whole evaluation (Self buffs and leader
        -- support above must still run with no enemy in sight).
        if #visibleTargets == 0 then
            debugLog('Cast blocked — non-Self spell needs a visible live combat target')
            return
        end
        local spawnPos = getCasterSpawnPos(nil)
        local losOk = hasLineOfSight(spawnPos,
            aim.position + Vec.LOS_TARGET_OFFSET, aim)
        if not losOk then
            -- The aim moved between the visibility scan and spell selection:
            -- retry another visible engine combat target rather than dropping
            -- the whole evaluation. Only candidate keys are compared because
            -- the engine can hand back a fresh proxy for the same actor.
            local aimKey = actorKey(aim)
            for i = 1, #visibleTargets do
                local candidate = visibleTargets[i]
                if actorKey(candidate) ~= aimKey
                    and hasLineOfSight(spawnPos,
                        candidate.position + Vec.LOS_TARGET_OFFSET, candidate) then
                    aimTarget = candidate
                    aim = candidate
                    distance = (candidate.position - self.position):length()
                    losOk = true
                    break
                end
            end
            if not losOk then return end
        end
    end
    local cooldown
    if strategy == 'reaction' then
        -- One hit buys one answer: the trigger is consumed and the answer is
        -- not repeated before it has had a chance to work. The ordinary cast
        -- clock is pushed too, so the next offensive spell does not land in
        -- the same instant as the escape.
        cooldown = Combat.REACTION_COOLDOWN
        Cast.nextReactionAt = now + cooldown
        Cast.lastIncomingHitAt = nil
        Cast.nextCastAllowedTime = now + cooldown
    elseif isBuff then
        -- Buffing has no cooldown: the next buff is due on the flat spacing
        -- regardless of the configured random cooldown settings.
        cooldown = Anim.buffSpacing
        Cast.nextBuffAllowedTime = now + cooldown
    else
        cooldown = Cfg.cooldownMin + math.random() * (Cfg.cooldownMax - Cfg.cooldownMin)
        Cast.nextCastAllowedTime = now + cooldown
    end
    debugLogf("Eval tick: Dist=%.1f Chance=%.1f%% Rolled=%.1f%% -> SUCCESS! Selected spell='%s' (strategy=%s, cd=%.1fs)",
        distance, chance * 100, roll * 100, spell.id, strategy, cooldown)
    -- Timed non-Self spells book their post-cast expiry block here — the
    -- moment the cast is committed, not when it was merely considered.
    Tactics.noteExpiry(aimTarget, spell, now)
    -- Strict setup arms the matching-damage lock at the same commit point;
    -- its matching follow-up clears it. Merely considering a spell does not
    -- mutate sequence state.
    Tactics.noteComboCast(aimTarget, spell, strategy, now)
    -- Decision trace (NPCAIDecisionTrace): one line per decision CHANGE,
    -- built only inside this branch — zero cost when the setting is off.
    if Cfg.trace then
        local key = spell.id .. '|' .. tostring(strategy) .. '|'
            .. tostring(aimTarget.recordId or aimTarget.id or '')
        if key ~= Cast.lastTraceKey then
            Cast.lastTraceKey = key
            local hpPct = -1
            local healthFn = types.Actor.stats.dynamic and types.Actor.stats.dynamic.health
            if healthFn then
                local hp = healthFn(aimTarget)
                if hp and hp.base and hp.base > 0 then
                    hpPct = hp.current / hp.base * 100
                end
            end
            print(('%sAI decision: %s -> %s (target=%s, dist=%.0f, targetHP=%.0f%%)')
                :format(Cfg.logPrefix, strategy, spell.id,
                    tostring(aimTarget.recordId or aimTarget.id or '?'), distance, hpPct))
        end
    end
    startQuickcast(spell, aimTarget)
    -- Same-buff recast lockout: stamp the buff only if the cast actually
    -- started (a swimming-blocked ally buff, for instance, never did), so
    -- the next NPCAIBuffRecastCooldown seconds skip this exact spell in
    -- both the Self and the ally buff picks.
    if (strategy == 'buff' or strategy == 'allyBuff')
        and Cast.isCasting and Cast.currentSpell == spell then
        Tactics.noteBuffCast(spell, now)
    end
end

-- The play handler vetoes heavy-attack plays while the cast owns the hands,
-- but an attack can already be in flight when the cast starts. Abort it the
-- SAFE way: release the engine attack input first (so the character
-- controller can leave its wind-up state on its own), then cancel the
-- animation.
local function abortHeavyAttack()
    -- Mercy CAO drives the attack input and the attack animations itself; a
    -- heavy attack it started is its business, and cancelling the animation
    -- under it is the one thing that permanently breaks an AI actor's attacks
    -- (see releaseEngineAttack above).
    if mercyOwnsBody() then return end
    local group = playingGroup(Combat.HEAVY_GROUPS)
    -- A weapon DRAW is not an attack. Cancelling it before the engine's
    -- 'equip attach' key fires leaves the actor holding an equipped but
    -- INVISIBLE two-hander — it then attacks the player with an empty hand
    -- that hits like a warhammer. The draw and the attack input are both left
    -- alone: the AI holds `use` while its weapon comes out, and releasing it
    -- here would throw that queued attack away (and, with a mod driving the
    -- actor, cancel the draw in the engine's own state machine).
    if group and castRules.isDrawPlaying(Cast.drawTracker, group) then
        debugLog('Left ' .. group .. ' weapon draw playing during the quickcast '
            .. '(equip, not an attack)')
        return
    end
    releaseEngineAttack()
    Cast.attackSuppressedDuringCast = true
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
    -- The whole heuristic reads the engine's mirrored attack input to spot an
    -- engine wind-up that stranded itself. With Mercy CAO driving, that input
    -- is Mercy's, a long hold is Mercy holding a charged attack on purpose,
    -- and releasing it under Mercy is the stall this self-heal is meant to
    -- cure (see scripts/ossc/ossc_mercy.lua).
    if mercyOwnsBody() then
        Cast.stuckAttackInputSince = nil
        return
    end
    if Cast.isCasting or not isEngineAttackInputHeld()
        or types.Actor.getStance(self) ~= STANCE.Weapon
        or getExcludedWeaponGroup() == nil
        or playingGroup(Combat.HEAVY_GROUPS) then
        Cast.stuckAttackInputSince = nil
        return
    end
    if Cast.stuckAttackInputSince == nil then
        Cast.stuckAttackInputSince = now
        return
    end
    if now - Cast.stuckAttackInputSince <= Anim.stuckAttackInputTimeout then return end
    debugLog('Self-heal: releasing stuck engine attack input (dead-locked wind-up)')
    releaseEngineAttack()
    Cast.stuckAttackInputSince = now -- re-arm in case it sticks again
end

-- Debug heartbeat, independent from combat/cast logic: one line per poll
-- interval while debug logging is enabled.
local function stanceName(value)
    if value == STANCE.Spell then return 'Spell' end
    if value == STANCE.Weapon then return 'Weapon' end
    if value == STANCE.Nothing then return 'Nothing' end
    return tostring(value)
end

local function debugHeartbeat(now, dt)
    Cast.nextDebugTick = now + math.max(0.1, Cfg.pollInterval)
    local target = getCombatTarget()
    local targetId, distance = 'NONE', -1
    if target then
        targetId = tostring(target.recordId)
        distance = (target.position - self.position):length()
    end
    local magicka = types.Actor.stats.dynamic.magicka(self)
    local stance = types.Actor.getStance(self)
    local spellStanceFor = Cast.spellStanceSince > 0
        and now - Cast.spellStanceSince or 0.0
    debugLogf('DEBUG TICK | dt=%.3f | sim=%.2f | combat=%s | casting=%s | suspended=%s | detachPending=%s | target=%s | dist=%.1f | stance=%s | magicka=%.0f/%.0f | nextCast=%.2f | spells=%d | stripped=%s | enabled=%s | maxDist=%.0f | nextAction=%.2f | mercyDriving=%s | window=%s | windowStage=%s | mercyWait=%s | realCast=%s | castCycle=%s | unequipWait=%.2f | castKey=%s | bareFor=%.2f | vanillaLeft=%d | vanillaRoll=%d | vanillaDodged=%d',
        dt, now, tostring(Cast.inCombat), tostring(Cast.isCasting),
        tostring(Pause.suspended), tostring(Pause.detachPending), targetId, distance,
        stanceName(stance), magicka.current, magicka.base,
        Cast.nextCastAllowedTime, knownSpellCount(),
        tostring(Cast.spellsTemporarilyRemoved), tostring(Cfg.enabled),
        Cfg.maxDist, Cast.nextActionTime, tostring(Cfg.mercyDriving),
        tostring(Cast.mercyWindowActive), tostring(Cast.mercyWindowStage),
        -- A Mercy hold that arrived mid-cast and is waiting for it to finish.
        tostring(Cast.mercyPauseDeferred ~= nil),
        tostring(Combat.realVanillaSpellcastActive()),
        tostring(vanillaSpellcast.cyclePending(Cast)),
        vanillaSpellcast.remaining(Cast, now, Cfg.vanillaCastUnequipTimeout),
        tostring(Cast.vanillaSpellcastLastKey or '-'), spellStanceFor,
        Combat.vanillaCastsRemaining(), Cast.vanillaCastsRolled,
        Cast.vanillaCastsDone)
end

local function onUpdate(dt)
    if IS_SPELL_VENDOR then return end
    local now = core.getSimulationTime()

    -- Cast watchdog: a cast whose 'stop' text key AND finish timer never
    -- arrived would otherwise stay "casting" for the rest of the fight.
    if Cast.isCasting and now > Cast.deadline then
        debugLog('Cast watchdog — cast outlived its window, resolving it')
        if not Cast.hasFiredThisCast then fireSpellPayload() end
        cleanupCast('watchdog')
    end

    if shouldBlockHeavyAttack() then abortHeavyAttack() end
    healStuckAttackInput(now)

    if Cast.isCasting and not Cast.hasFiredThisCast and isActorIncapacitated() then
        debugLog('Quickcast cancelled — incapacitated mid-cast')
        cleanupCast('incapacitated mid-cast')
        return
    end

    if Cfg.debugMode and now >= Cast.nextDebugTick then debugHeartbeat(now, dt) end

    if not isActorEligible() or types.Actor.isDead(self) then
        -- No new casts, and hand the spell list back to the engine AI so it
        -- is not left stripped. A window is session state and must not
        -- outlive the actor it was negotiated on.
        debugGate(now, 'actor ineligible or dead')
        if Cast.isCasting then cleanupCast('actor ineligible') end
        Combat.endMercyWindow('actor ineligible')
        refreshMercyDriver(false)
        restoreAllCastableSpells()
        return
    end

    -- Pick up settings changes mirrored into global storage (cheap, 1 Hz).
    if now >= Cast.nextSettingsRefresh then
        Cast.nextSettingsRefresh = now + 1.0
        refreshSettings()
        -- Mods add spells at combat start with deferred Actor.spells():add()
        -- calls that can land after onInit. Re-read the live list once a second
        -- even when the tactical poll is held by a range/pause gate.
        updateKnownSpellsCache()
        -- Mercy's hold is the one pause reason OSSC owns the release for: it
        -- only ever comes from Mercy's own onUpdate (see releaseStaleMercyHold).
        releaseStaleMercyHold(now)
    end

    -- A missing SpellCast Unequip Stop must not deadlock the actor even while
    -- the combat target is temporarily out of range.
    Combat.expireVanillaCastCycle(now)

    -- A vanilla window is not just "OSSC keeps its hands off": the actor has
    -- to actually OWN the spells for as long as the window lasts. Re-assert
    -- them here, before every early exit below (no target, out of range, a
    -- pause, a stand-down), so the engine never looks at an empty list.
    Combat.ensureVanillaCastSpells(now)

    -- Close a spent or timed-out vanilla-cast allowance. Closing only clears
    -- the bookkeeping: the ordinary strip guard below hands the engine spell
    -- list back to OSSC on the next frame it is allowed to.
    if Cast.vanillaCastAllowanceArmed then
        local stopReason = Combat.vanillaCastAllowanceStopReason(now)
        if stopReason then
            Combat.closeVanillaCastAllowance(stopReason)
            Cast.spellStanceSince = 0.0
        end
    end

    -- OSSC owns casting inside Maximum Cast Distance. Outside that distance,
    -- the vanilla engine is allowed to use its normal spell stance.
    local target = getCombatTarget()
    Cast.inCombat = target ~= nil
    -- Refreshed before every exit path below, so the flag is never left
    -- claiming Mercy drives an actor that is not even in combat.
    refreshMercyDriver(target ~= nil)
    local targetDistance = target and (target.position - self.position):length() or -1
    if not target or targetDistance > Cfg.maxDist then
        debugGate(now, 'no combat target inside OSSC range (dist=%.1f max=%.0f)',
            targetDistance, Cfg.maxDist)
        if not Cast.isCasting then
            restoreAllCastableSpells()
            Combat.endMercyWindow('combat target lost or out of range')
        end
        return
    end

    -- A real vanilla cast cycle owns the actor until SpellCast Unequip Stop.
    -- Hold every quick-cast path and keep the engine spell list restored while
    -- it is still pending. The fallback timeout was checked above.
    if Combat.realVanillaSpellcastActive() then
        if Cast.isCasting then cleanupCast('vanilla cast cycle started') end
        Combat.endMercyWindow('vanilla cast cycle started')
        restoreAllCastableSpells()
        debugGate(now, 'waiting for SpellCast Unequip Stop before quick-casts '
            .. '(wait=%.2fs key=%s)',
            vanillaSpellcast.remaining(Cast, now, Cfg.vanillaCastUnequipTimeout),
            tostring(Cast.vanillaSpellcastLastKey or '-'))
        return
    end

    -- A Mercy or vanilla bare Spell posture, or Mercy's outside-FIGHT hold, can
    -- otherwise keep OSSC paused for the whole fight. Open a short window
    -- before evaluating the normal gates, then advance it every frame.
    Combat.maybeBeginMercyWindow(now, target)
    Combat.updateMercyWindow(now)
    local pauseBlocks = Combat.pauseBlocksOSSC()

    -- Keep the pause-grace bookkeeping expiring, then hand the whole actor to
    -- the engine while its vanilla magic stance is up. The engine needs its
    -- selected castable, its spell list and its gesture untouched; an OSSC
    -- cast that started a frame earlier is cleaned up rather than blended over
    -- a vanilla cast. A Mercy-only pause is deliberately bypassed during a
    -- quick-cast window: Mercy yielded that pause with the body.
    local mercyVanillaCast = not pauseBlocks and mercyVanillaCastActive(now)
    local externalPauseGrace = not pauseBlocks and externalPauseGraceActive(now)
    local vanillaCastProtected = mercyVanillaCast or externalPauseGrace
    -- The allowance is a count, not a grace: it outlives a single stance and
    -- keeps OSSC out of the way until the engine has finished its casts.
    local vanillaAllowance = not pauseBlocks
        and Combat.vanillaCastAllowanceActive(now)
    local spellStanceFor = Cast.spellStanceSince > 0
        and now - Cast.spellStanceSince or 0.0
    if Combat.vanillaSpellStanceActive() then
        debugGate(now, 'vanilla Spell stance stand-down (realCast=%s cycle=%s unequipWait=%.2fs key=%s bareFor=%.2fs vanillaLeft=%d)',
            tostring(Combat.realVanillaSpellcastActive()),
            tostring(vanillaSpellcast.cyclePending(Cast)),
            vanillaSpellcast.remaining(Cast, now, Cfg.vanillaCastUnequipTimeout),
            tostring(Cast.vanillaSpellcastLastKey or '-'), spellStanceFor,
            Combat.vanillaCastsRemaining())
        if Cast.isCasting then cleanupCast('vanilla spell stance') end
        restoreAllCastableSpells()
        return
    end
    -- The stand-down detector has decided this is a bare posture. Any grace
    -- left from a bare-stance pause release is stale: clear it so the engine
    -- spell list can actually be stripped on this frame.
    if vanillaCastProtected and not Combat.realVanillaSpellcastActive() then
        Cast.externalPauseGraceUntil = 0.0
        Cast.mercyVanillaCastUntil = 0.0
        externalPauseGrace = false
        mercyVanillaCast = false
        vanillaCastProtected = false
    end

    if Cast.reentryGuardUntil > now and not vanillaAllowance then
        types.Actor.clearSelectedCastable(self)
    end
    -- While a detach is pending (combat ended, timers draining or waiting for
    -- removal) never start a new cast and never re-strip engine spells: new
    -- timers would re-create the removal race, and re-stripped spells would
    -- stay hidden once the script is gone. A pause release grace can still
    -- protect a vanilla cast from another mod.
    if not Cast.spellsTemporarilyRemoved and not pauseBlocks
        and not vanillaCastProtected and not vanillaAllowance then
        removeAllCastableSpells()
    end
    -- ── Draw state ownership ──────────────────────────────────────────────
    -- A SPELL stance is the engine's: OSSC never takes a bare Spell posture
    -- over any more ("Take Over Bare Spell Stance" is permanently off), so the
    -- old per-frame "flip a bare posture to Weapon stance" write is gone. In
    -- the field that write re-fired on every frame — the Mercy AI (or the
    -- engine AI) put the actor back into Spell stance between frames, OSSC
    -- flipped it to Weapon again, the flip started a weapon draw, and the log
    -- filled with `Bare Spell posture taken over` / `Weapon stance taken over`
    -- thirty times a second while the actor looped draw/sheathe forever. It
    -- also cancelled a quick-cast already in flight: `setStance` interrupts the
    -- attack/spell being readied, and a stance flip on the frame a cast starts
    -- ended the left-hand gesture the moment the actor was told to ready or
    -- unready its weapon. A quick-cast in flight now always keeps its hands.
    --
    -- Relaxed hands (Nothing) are drawn once, at cast start, where the draw is
    -- wanted; a stance change the player or another mod asked for is never
    -- overwritten here.
    if not mercyOwnsBody() and not vanillaAllowance and not Cast.isCasting then
        local stance = types.Actor.getStance(self)
        -- `stance` is what the actor stood in when this frame began, i.e. the
        -- state OSSC's last write left it in: Weapon means the takeover held
        -- and the next one earns its own wait.
        if stance == STANCE.Weapon then Cast.equipArmed = false end
    end
    -- Sample the combat target each tick so an eligible target-range cast can
    -- estimate its movement over the engine's 0.25 s AI reaction window. The
    -- per-cast 50/50 decision is made at release, never per frame.
    if target then targetLead.track(target, now) end
    -- Invisible: keep the "can the player see me" answer fresh and hold the
    -- actor's attacks/casts while it can (see Combat.updateHidden).
    Combat.updateHidden(now)
    -- The weapon OSSC drew when it took the body back has to be out first:
    -- that is the readiness delay (NPCQuickCastEquipReadiness), and it holds
    -- only the FIRST cast — `Cast.nextActionTime` is not advanced, so the poll
    -- that was already due fires as soon as the draw is done.
    local equipPending = Combat.equipReadinessPending(now)
    if pauseBlocks or vanillaCastProtected or vanillaAllowance
        or equipPending or now < Cast.nextActionTime then
        if pauseBlocks then
            debugGate(now, 'caster paused (suspended=%s detachPending=%s)',
                tostring(Pause.suspended), tostring(Pause.detachPending))
        elseif vanillaAllowance then
            debugGate(now, 'vanilla cast allowance — waiting for the engine to '
                .. 'finish %d more vanilla cast(s), left=%.1fs',
                Combat.vanillaCastsRemaining(),
                Cast.vanillaCastAllowanceUntil ~= 0.0
                    and math.max(0.0, Cast.vanillaCastAllowanceUntil - now) or -1.0)
        elseif vanillaCastProtected then
            debugGate(now, 'pause-resume vanilla cast grace (mercy=%s external=%s)',
                tostring(mercyVanillaCast), tostring(externalPauseGrace))
        elseif equipPending then
            debugGate(now, 'weapon draw after taking the body over — first '
                .. 'quick-cast held (%.2fs left)',
                math.max(0.0, Cast.equipReadyUntil - now))
        else
            debugGate(now, 'waiting for next tactical poll (nextAction=%.2f now=%.2f)',
                Cast.nextActionTime, now)
        end
        return
    end
    Cast.nextActionTime = now + Cfg.pollInterval
    -- Mercy CAO's body is committed (mid attack burst, casting one of its own
    -- spells, repositioning, or in a routine that is not a straight fight):
    -- OSSC waits for a moment that belongs to it. Read live off Mercy's state
    -- rather than off the hold Mercy sends, so the gate does not depend on the
    -- frame order between the two scripts (see mercyCastBlockReason).
    local mercyReason = mercyCastBlockReason()
    if mercyReason then
        debugLogf('Mercy CAO holds this cast (%s)', mercyReason)
        return
    end
    if isFollowProtected(target) then
        debugGate(now, 'combat target is this actor\'s own follow leader')
        return
    end
    evaluateCombatQuickcast(now, target)
end

-- ── Engine attack plays ──
-- Never veto equip/unequip plays (weapon attach would desync).
local function isEquipPlay(options)
    return castRules.isEquipPlay(options)
end

-- One text-key sink for both the all-keys handler and playBlended start
-- keys. It updates the shared cycle state AND owns the engine spell list
-- handshake: real cast keys restore spells, SpellCast Unequip Stop strips
-- them again and re-arms OSSC quick-casts.
local function onVanillaSpellcastKey(groupname, key)
    local kind, newCycle = Combat.noteVanillaSpellcastKey(groupname, key)
    if kind == 'unequip_stop' then
        Combat.endVanillaCastCycle('SpellCast Unequip Stop: ' .. tostring(key))
    elseif kind then
        Combat.beginVanillaCastCycle(kind, key, newCycle)
    end
    return kind
end

-- Mid-cast heavy-weapon attack block (BlockWeaponDuringQuickcast): if the
-- engine starts a 2H / bow / crossbow attack while the cast animation has the
-- hands busy, VETO the play (options.skip — the built-in animation controller
-- then never plays it) and release the engine attack input so the character
-- controller immediately drops back out of its wind-up state. One-handed /
-- hand-to-hand / thrown groups are never touched.
local function onPlayBlendedAnimation(groupname, options)
    if type(groupname) ~= 'string' then return end
    -- The engine can start a real vanilla cast with a playBlended request
    -- whose start key is one of self/target/touch start. Note it immediately;
    -- the text-key handler will keep the hold alive through Release / Stop.
    if type(options) == 'table' and vanillaSpellcast.isSpellcastGroup(groupname) then
        local startKey = options.startKey or options.startkey
        if type(startKey) == 'string'
            and vanillaSpellcast.keyKind(groupname, startKey) == 'start' then
            onVanillaSpellcastKey(groupname, startKey)
        end
    end
    -- Weapon ready / unready animations are the actor's own stance transition:
    -- record which way it went. A quick-cast in flight keeps its casting hand
    -- through it (see prepareCastPlayOptions) and is never cancelled by it. The
    -- 'spellcast' group is the ENGINE's cast, not a weapon transition, and only
    -- real equip / unequip keys count.
    if not vanillaSpellcast.isSpellcastGroup(groupname) then
        castRules.noteTransition(Cast.drawTransition, groupname, options)
    end
    -- A ready / unready must not take the casting hand of a cast in flight.
    -- The engine plays a weapon transition as ONE blended play whose mask is
    -- All bones, LeftArm included — toggling readiness mid-quickcast used to
    -- freeze the gesture. The transition keeps its attach keys and plays
    -- normally, it just stops claiming the casting arm (same rule as the
    -- player script's pre-play handler). Only the actor's OWN body is touched:
    -- while Mercy drives it the transition is Mercy's animation.
    if Cast.isCasting and type(options) == 'table' and not mercyOwnsBody()
        and castRules.isEquipPlay(options) then
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
    -- Engine attack wind-ups are started with a blended play whose stop key
    -- ends in "min attack"/"max attack": open the charge window (the text
    -- key handler closes it once the attack is released). The engine passes
    -- the keys as stopKey; Lua callers may use the lowercase spelling.
    if Combat.ANIM_GROUP_SET[groupname] then
        local stopKey = options.stopKey or options.stopkey
        if type(stopKey) == 'string' and isChargeKey(stopKey) then
            Cast.chargeUntil = core.getSimulationTime() + Anim.chargeHoldWindow
        end
    end
    if not Combat.HEAVY_GROUP_SET[groupname] then return end
    -- Draw or swing? A heavy group carries both. An equip play arms the draw
    -- tracker (so the per-frame abort leaves it alone) and is never vetoed —
    -- skipping it would leave the weapon equipped with no mesh. Any other play
    -- of this group is a real attack and clears the marker.
    if isEquipPlay(options) then
        castRules.noteDraw(Cast.drawTracker, groupname)
        return
    end
    castRules.clearDraw(Cast.drawTracker, groupname)
    if not shouldBlockHeavyAttack() then return end
    -- Mercy CAO drives the weapon animations while it drives this actor; a
    -- veto here would skip a swing Mercy asked for and then release the input
    -- under it (see releaseEngineAttack).
    if mercyOwnsBody() then return end
    debugLog('Vetoed ' .. groupname .. ' attack play during quickcast')
    -- Remember that this cast took an attack away from the actor: the input
    -- has to be handed back when the cast ends (rearmSuppressedAttack),
    -- otherwise the AI is left holding it with a wind-up that can never
    -- progress.
    Cast.attackSuppressedDuringCast = true
    options.skip = true
    -- The engine switches to its attack wind-up state even for a vetoed
    -- play; without this release the AI would be stranded in that state.
    releaseEngineAttack()
end

for i = 1, #Anim.QUICKCAST_GROUPS do
    I.AnimationController.addTextKeyHandler(Anim.QUICKCAST_GROUPS[i], onTextKey)
end
-- Listen to ALL text keys but only react to the nine real vanilla spellcast
-- Start / Release / Stop markers and SpellCast Unequip Stop. Registering ''
-- also covers builds that pass a differently-cased group name (e.g.
-- "SpellCast") or a full NIF key.
I.AnimationController.addTextKeyHandler('', onVanillaSpellcastKey)
for i = 1, #Combat.ANIM_GROUPS do
    I.AnimationController.addTextKeyHandler(Combat.ANIM_GROUPS[i], onCombatAnimTextKey)
end
-- Light attacks are not in ANIM_GROUPS (they must never veto a quickcast), but
-- their charge keys are exactly how a parked 1H wind-up is detected.
for i = 1, #Combat.LIGHT_GROUPS do
    I.AnimationController.addTextKeyHandler(Combat.LIGHT_GROUPS[i], onCombatAnimTextKey)
end
I.AnimationController.addPlayBlendedAnimationHandler(onPlayBlendedAnimation)

-- ── Hit / Death animation abort ────────────────────────────────────────────
-- If the caster takes a hit or dies while quickcasting, abort the cast
-- immediately so the hit / death animation is not fighting the cast anim.
local function onHitDeathTextKey(groupname, key)
    if not Cast.isCasting then return end
    local lowerKey = tostring(key):lower()
    if lowerKey ~= 'start' then return end
    debugLog('Hit/death animation \'' .. groupname .. '\' started — aborting quickcast')
    local castGroup = Cast.currentAnimGroup  -- capture before cleanupCast clears it
    cleanupCast('hit/death interrupt [' .. groupname .. ']')
    if castGroup then
        anim.cancel(self, castGroup)
        debugLog('Cancelled cast animation group: ' .. castGroup)
    end
end

Combat.HIT_DEATH_GROUPS = {
    'hit1','hit2','hit3','hit4','hit5',
    'death1','death2','death3','death4','death5',
    'swimhit','swimdeath1',
}
for i = 1, #Combat.HIT_DEATH_GROUPS do
    I.AnimationController.addTextKeyHandler(Combat.HIT_DEATH_GROUPS[i], onHitDeathTextKey)
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────
local function logCachedSpells(stage)
    if not Cfg.debugMode then return end
    local ids = {}
    for spellId in pairs(Cast.knownSpells) do ids[#ids + 1] = spellId end
    debugLogf('%s: cached %d castable spells: [%s]', stage, #ids, table.concat(ids, ', '))
    if #ids == 0 then
        debugLog('Spell cache empty at ' .. stage
            .. ' — deferred Actor.spells() adds will be retried every second')
    end
end

local function onSave()
    -- setEquipment applies after the save is written; carry the hidden shield
    -- in the save data so onLoad can restore it after this cleanup.
    local hiddenShield = Cast.suppressedShield
    restoreShieldAfterCast()
    -- The key names are the pre-refactor local names on purpose: they are the
    -- save-game format, and onLoad reads them back.
    return {
        hiddenShield             = hiddenShield,
        nextCastAllowedTime      = Cast.nextCastAllowedTime,
        nextBuffAllowedTime      = Cast.nextBuffAllowedTime,
        buffLastCastAt           = Cast.buffLastCastAt,
        lastNonSpellStance       = Cast.lastNonSpellStance,
        cachedKnownSpells        = Cast.knownSpells,
        spellsTemporarilyRemoved = Cast.spellsTemporarilyRemoved,
        rolledAnims              = Anim.rolled,
    }
end

local function onLoad(data)
    refreshSettings()
    if IS_SPELL_VENDOR then
        -- Older saves may contain OSSC state from before vendor exclusion was
        -- added: restore those spells, but do not otherwise touch the vendor.
        if data then
            Cast.knownSpells = data.cachedKnownSpells or {}
            Cast.knownSpellsDirty = true
            Cast.spellsTemporarilyRemoved = data.spellsTemporarilyRemoved or false
        end
        restoreAllCastableSpells()
        return
    end
    resetAfterActivation('onLoad')
    local hiddenShield = data and data.hiddenShield
    if hiddenShield and hiddenShield:isValid() then
        local eq = types.Actor.getEquipment(self)
        if not eq[SLOT.CarriedLeft] then
            eq[SLOT.CarriedLeft] = hiddenShield
            types.Actor.setEquipment(self, eq)
        end
    end
    if data then
        Cast.nextCastAllowedTime = data.nextCastAllowedTime or 0
        Cast.nextBuffAllowedTime = data.nextBuffAllowedTime or 0
        Cast.buffLastCastAt = data.buffLastCastAt or {}
        Cast.lastNonSpellStance = data.lastNonSpellStance or STANCE.Weapon
        Cast.knownSpells = data.cachedKnownSpells or {}
        Cast.knownSpellsDirty = true
        Cast.spellsTemporarilyRemoved = data.spellsTemporarilyRemoved or false
        Anim.rolled = data.rolledAnims
    end
    -- Keep the animation set rolled before the save; only roll a fresh one
    -- for saves made by an older OSSC version that never stored it.
    if not Anim.rolled then rollAnimSet() end
    if not isActorEligible() then return end
    Combat.syncSpellListWithStance()
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
    if not Anim.rolled then rollAnimSet() end -- rolled at attach, kept while attached
    Combat.syncSpellListWithStance()
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
    Combat.syncSpellListWithStance()
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
    if Cast.isCasting and types.Actor.isDead(self) then cleanupCast('dead') end
    if Cast.isCasting or core.getSimulationTime() < Cast.pendingTimersUntil then
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
    async:newUnsavableSimulationTimer(math.max(0.05, Cast.pendingTimersUntil - core.getSimulationTime() + 0.05), detachAckTick)
end

-- Sent by the global attachment manager immediately before detaching the
-- script: restore the spells hidden from the vanilla AI, stop any in-flight
-- cast and ack once the unsavable cast timers have drained.
local function onCombatEnded()
    restoreAllCastableSpells()
    if Cast.isCasting then cleanupCast('combat ended') end
    -- The cast timers cannot be cancelled, and external pause reasons remain
    -- owned by their callers. Preserve both while resetting combat state.
    local pendingTimersUntil, pauseReasons = Cast.pendingTimersUntil, Pause.reasons
    resetAfterActivation('combat ended')
    Cast.pendingTimersUntil, Pause.reasons = pendingTimersUntil, pauseReasons
    Pause.refresh()
    armDetachAck()
end

-- Pending detach cancelled.
local function onCombatResumed()
    Pause.detachPending = false
    -- An external pause, if any, keeps its own hold on the gate.
    Pause.refresh()
    -- Combat (re)started: grant the same one-second opening as a fresh
    -- attach, so the buff routine begins one second from here rather than
    -- instantly on the resume event.
    Cast.reentryGuardUntil = math.max(Cast.reentryGuardUntil,
        core.getSimulationTime() + Anim.reentryGuardDuration)
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
        isCasting   = function() return Cast.isCasting end,
        isSuspended = function() return Pause.suspended end,
        -- `unpause()` with no reason releases every pause; `unpause('scene')`
        -- releases only that one, so a mod cannot resume an actor another mod
        -- is still holding.
        pause   = function(reason) return Pause.set(true, reason) end,
        unpause = function(reason) return Pause.set(false, reason) end,

        -- ── Mercy CAO (Combat AI Overhaul) ────────────────────────────────
        -- Live read-outs of the bridge in scripts/ossc/ossc_mercy.lua, so a
        -- same-actor script (or a Mercy extension) can see what OSSC decided
        -- without guessing from the content-file order.
        --- True while Mercy's AI drives this actor and OSSC has handed it the
        --- draw state and the attack input.
        isMercyDriving = function() return Cfg.mercyDriving == true end,
        --- Vanilla-cast allowance read-out: casts still owed to the engine, the
        --- count rolled for this hand-back, how many it already used, and
        --- whether the allowance is currently holding OSSC back at all.
        isVanillaCastAllowanceActive = function()
            return Combat.vanillaCastAllowanceActive() == true
        end,
        --- True while OSSC holds this actor's castables (quick-cast mode) and
        --- false while the engine holds them (vanilla-cast mode).
        isSpellListStripped = function() return Combat.osscOwnsSpellList() end,
        vanillaCastsRemaining = function() return Combat.vanillaCastsRemaining() end,
        vanillaCastsRolled    = function() return Cast.vanillaCastsRolled end,
        vanillaCastsDone      = function() return Cast.vanillaCastsDone end,
        --- Why OSSC will not start a cast of its own right now, or nil.
        mercyCastBlockReason = mercyCastBlockReason,
        --- True while a short OSSC quick-cast window has Mercy yielded.
        isMercyQuickcastWindow = function() return Cast.mercyWindowActive == true end,
        --- The window's current stage: idle / prepare / armed / casting.
        mercyQuickcastWindowStage = function() return Cast.mercyWindowStage end,
        --- Fixed compatibility policy: OSSC cooperates with Mercy CAO.
        mercyMode = function() return mercy.MODE_COOPERATE end,

        -- Settings read-out for same-actor scripts: the distance (game units)
        -- at or below which this actor's quick-cast probability is at its
        -- maximum — the "100% chance distance" of the NPC settings
        -- (NPCQuickCastMinDistance, default 500).  This is the live value
        -- castChance() rolls against, refreshed from the settings mirror
        -- once a second, so it tracks menu changes without a reload.
        getQuickCastFullChanceDistance = function() return Cfg.minDist end,

        -- Every NPC/creature quick-cast setting (the SettingsOSSC_NPC group)
        -- as a live snapshot table — the same read-out as
        -- I.OSSC_Casters.getNPCSettings(), from this actor script's view of
        -- the settings mirror. Unset keys answer with their registered
        -- defaults; the result is a fresh copy, safe to keep or mutate.
        -- (The shared schema module is required inline — this main chunk is
        -- at Lua's 200-local limit and cannot spare a top-level local.)
        getNPCSettings = function()
            return require('scripts.ossc.ossc_caster_utils').readNPCSettings(Cfg.npc)
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
        -- Vanilla delivers Hit to the victim: record when it happened, and
        -- reactionSpell() decides whether NPCAIReactions answers it. Only the
        -- timestamp is kept — nothing about the hit is interpreted.
        Hit = function()
            Cast.lastIncomingHitAt = core.getSimulationTime()
        end,
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
                Cast.followTargetKey = actorKey(pkg.target)
                Cast.followObj = pkg.target
            elseif pkg == 'Follow' then
                scanFollowPackage()
            end
        end,
        RemoveAIPackages = function(pkg)
            if pkg == nil or isFollowPackage(pkg) or pkg == 'Follow' then
                Cast.followTargetKey = nil
                Cast.followObj = nil
            end
        end,
    },
}
