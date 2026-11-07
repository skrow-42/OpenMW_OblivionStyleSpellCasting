---@omw-context player
-- ── PureMultiMark UI compatibility: global exports ──
-- PMM UI modules run via require in this env and need these as globals.
-- Must stay ABOVE the locals below, or assignments hit the locals instead.
core  = require('openmw.core')
util  = require('openmw.util')
ui    = require('openmw.ui')
async = require('openmw.async')
input = require('openmw.input')
v2    = util.vector2

local core    = require('openmw.core')
local types   = require('openmw.types')
local input   = require('openmw.input')
local anim    = require('openmw.animation')
local self    = require('openmw.self')
local async   = require('openmw.async')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local ui      = require('openmw.ui')
local ambient = require('openmw.ambient')
local storage = require('openmw.storage')
local I       = require('openmw.interfaces')
local debug   = require('openmw.debug')
local nearby  = require('openmw.nearby')
local vfs     = require('openmw.vfs')

-- ── Hot-path aliases (cod3x) ────────────────────────────────────────────────
local STANCE     = types.Actor.STANCE
local SLOT       = types.Actor.EQUIPMENT_SLOT
local RANGE      = core.magic.RANGE
local SPELL_TYPE = core.magic.SPELL_TYPE
local ENCHTYPE   = core.magic.ENCHANTMENT_TYPE or {}
local spellRecs  = core.magic.spells.records
local enchRecs   = core.magic.enchantments.records
local effectRecs = core.magic.effects.records
local staticRecs = types.Static.records
local BONE       = anim.BONE_GROUP
local PRIO       = anim.PRIORITY
local BMASK      = anim.BLEND_MASK

-- ── Cached Settings Sections ────────────────────────────────────────────────
local Cfg = {
    general    = storage.playerSection('SettingsOSSC_General'),
    keys       = storage.playerSection('SettingsOSSC_Keys'),
    anim       = storage.playerSection('SettingsOSSC_Animations'),
    animSpeed  = storage.playerSection('SettingsOSSC_AnimSpeeds'),
    npc        = storage.playerSection('SettingsOSSC_NPC'),
    pmm        = storage.playerSection('SettingsPureMultiMark'),
    pmmInstalled = vfs.fileExists('scripts/puremultimark/PMM_markWindow.lua') == true,
    magExp     = storage.playerSection('SettingsMagExp_General'),
    qsKeyboard = storage.playerSection('SettingsQuickSelectKeyboard'),
    qs         = storage.playerSection('SettingsQuickSelect'),
    debugMode  = false,
}
Cfg.debugMode = Cfg.general and Cfg.general:get('DebugMode') or false

-- ── Animation data ─────────────────────────────────────────────────────────
-- The animation groups and weapon classes the cast gates consult, plus the
-- per-group speed settings, in ONE table. Same reason as Cfg / Cast / PMM /
-- Stance below: every file-scope local costs the big handlers an upvalue, and
-- a Lua chunk may only hold 200 of them at all.
local Anim = {}

-- ── Cached GMST Constants ───────────────────────────────────────────────────
-- Vanilla Morrowind ships fFatigueSpellBase AND fFatigueSpellMult as 0 — no
-- fatigue cost for spells at all — and fFatigueSpellCostMult is a GMST the
-- engine never actually reads (OpenMW's Research:Magic lists it as unused),
-- so it must not be part of the formula. UseFatigue is the setting that
-- turns the drain on; when the two GMSTs are still the untuned vanilla pair
-- (both 0), handleCastCosts falls back to a built-in default so the setting
-- has a visible effect instead of silently draining nothing.
local GMST = {
    fEffectCostMult       = core.getGMST('fEffectCostMult') or 1.0,
    sMagicInsufficientSP  = core.getGMST('sMagicInsufficientSP') or "You do not have enough Magicka to cast this spell.",
    sMagicInsufficientCharge = core.getGMST('sMagicInsufficientCharge') or "Item does not have enough charge",
    sPowerAlreadyUsed     = core.getGMST('sPowerAlreadyUsed') or "You can only use this power once per day.",
    fFatigueSpellBase     = core.getGMST('fFatigueSpellBase') or 0,
    fFatigueSpellMult     = core.getGMST('fFatigueSpellMult') or 0,
    -- Touch reach / cone / activate distance are read where they are used
    -- (scripts/ossc/ossc_cast_rules.lua), so the player and the actor scripts
    -- can never drift apart on the vanilla formula.
    fTargetSpellMaxSpeed   = core.getGMST('fTargetSpellMaxSpeed') or 1000,
    sSkillUp               = core.getGMST('sSkillUp') or "Your %s skill has increased to %d.",
}

-- Quick-cast penalty values and the multiplier each one means are shared with
-- the settings menu, so the two can never disagree; see
-- scripts/ossc/ossc_penalty.lua.
local Penalty = require('scripts.ossc.ossc_penalty')
-- The skill progression modes, shared with the settings menu. Reading the mode
-- through this normalises the dropped 'ncg+se' choices to 'skillevo' even in a
-- save the settings script has not rewritten yet; see
-- scripts/ossc/ossc_skillmodes.lua.
local SkillModes = require('scripts.ossc.ossc_skillmodes')
-- Shared caster helpers: the spell classification and the SettingsOSSC_NPC
-- schema (every key + its registered default) that I.OSSC.getNPCSettings
-- exposes to other mods; see scripts/ossc/ossc_caster_utils.lua.
local casterUtils = require('scripts.ossc.ossc_caster_utils')

-- Launch offsets are user-editable data, so the SHAPE is validated and a file
-- that does not provide it falls back to built-in defaults. A syntax error is
-- a different thing: that is a broken file and should surface as one rather
-- than be swallowed into a silent fallback.
local launchOffsets = require('scripts.ossc.ossc_launch_offsets')
if type(launchOffsets) ~= 'table' or type(launchOffsets.get) ~= 'function' then
    print('[OSSC] WARNING: scripts/ossc/ossc_launch_offsets.lua failed to load — using built-in offsets')
    launchOffsets = {
        get = function(_, firstPerson)
            if firstPerson then return { forward = 40, left = 35, up = -8 } end
            return { forward = 40, left = 25, up = 115 }
        end,
        getGrimoire = function(_, firstPerson)
            if firstPerson then return { forward = 40, left = -30, up = -16 } end
            return { forward = 40, left = -20, up = 115 }
        end,
    }
end

-- Friendlier Fire gate. Spell Framework Plus applies OSSC casts from Lua
-- (ActiveSpells:add()), which FF's sweep cannot see, so OSSC detects friendly
-- fire itself (mirroring FF's test) before launching a harmful spell at a
-- follower/summon. No-op without FF/FDU.
local friendlyFire = require('scripts.ossc.ossc_friendlyfire')

-- Moving-target lead for quick-cast projectiles: a Lua clone of the OpenMW
-- engine's AI spell leading (mwmechanics/aicombat.cpp AimDirToMovingTarget,
-- AI_REACTION_TIME velocity window, fTargetSpellMaxSpeed bolt speed). Feeds
-- on crosshair samples taken in onUpdate and is consulted by
-- processPendingLaunches for target-range casts at a living actor. Pure math
-- + position tracking lives in scripts/ossc/ossc_target_lead.lua; nothing in
-- it reads the stance, so leading applies identically to casts started from
-- Weapon stance or relaxed hands (a quick-cast never starts in Spell stance —
-- see ossc_cast_rules.quickcastStanceAllowed).
local targetLead = require('scripts.ossc.ossc_target_lead')
-- Where an impact's hit statics are drawn (OSSC owns the placement).
local impactVfx = require('scripts.ossc.ossc_impact_vfx')
-- Shared cast rules: the Spell-stance gate and the modder cast-veto hooks live
-- there so the player, NPC and item casters cannot drift apart.
local castRulesModule = require('scripts.ossc.ossc_cast_rules')

-- ── Stagger / knockdown interruption rules ─────────────────────────────────
-- Vanilla cancels a cast when the caster is staggered; OSSC must do the same.
--   * KNOCK_GROUPS   — every animation group with 'knock' in its name. While
--                      any of these is playing, casting is forbidden.
--   * STAGGER_GROUPS — hit-reaction groups (stun-lock). While any of these is
--                      playing, casting is forbidden, and an already-started
--                      OSSC cast is cancelled instead of launching.
-- The lists below are also checked again at launch time (the 'release' moment)
-- so a stagger that lands mid-animation cancels the spell with no cost.
Anim.KNOCK_GROUPS = {
    "knockdown", "knockout", "swimknockdown", "swimknockout", "hit1", "hit2", "hit3", "hit4", "hit5",
    "swimhit1", "swimhit2", "swimhit3",
}

Anim.STAGGER_GROUPS = {
        "hit1", "hit2", "hit3", "hit4", "hit5",
    "swimhit1", "swimhit2", "swimhit3",
}

Anim.INCAPACITATED_GROUPS = {
    "spellcast", "knockdown", "knockout", "swimknockout", "swimknockdown",
    "hit1", "hit2", "hit3", "hit4", "hit5",
    "swimhit1", "swimhit2", "swimhit3",
}

-- Animation groups that block quick-casting when BlockDuringCombatAnims is on.
-- shield        — Shield: Block
-- weapontwohand — WeaponTwoHand: Chop / Slash / Thrust
-- weapontwowide — WeaponTwoWide: Chop / Slash / Thrust
-- bowandarrow   — BowAndArrow: Shoot (draw + release)
-- crossbow      — Crossbow: Shoot (aim + release)
Anim.COMBAT_ANIM_GROUPS = {
    "shield", "weapontwohand", "weapontwowide", "bowandarrow", "crossbow",
}

-- Weapon record types that belong to the animation groups above. While an
-- attack charge is being held, the weapon animation parks on a text key
-- ("min attack" / "max attack") and anim.isPlaying() returns false, so the
-- group check alone would let a quick-cast through the hold. When the attack
-- button is held with one of these weapons equipped, quick-casting is
-- therefore blocked as well.
Anim.EXCLUDED_WEAPON_TYPE_TO_GROUP = {
    [types.Weapon.TYPE.LongBladeTwoHand]  = "weapontwohand",
    [types.Weapon.TYPE.BluntTwoClose]     = "weapontwohand",
    [types.Weapon.TYPE.AxeTwoHand]        = "weapontwohand",
    [types.Weapon.TYPE.SpearTwoWide]      = "weapontwowide",
    [types.Weapon.TYPE.BluntTwoWide]      = "weapontwowide",
    [types.Weapon.TYPE.MarksmanBow]       = "bowandarrow",
    [types.Weapon.TYPE.MarksmanCrossbow]  = "crossbow",
}

-- Attack animation groups that the BlockWeaponDuringQuickcast setting cancels
-- while an OSSC quickcast is playing ("the hand is free of the weapon"). These
-- are the attack groups of two-handed melee and ranged weapons — the same
-- heavy weapons guarded by Block Quick Cast During Combat Animations. Shield
-- blocking is not an attack, so 'shield' is intentionally left out.
Anim.HEAVY_ATTACK_GROUPS = {
    "weapontwohand", "weapontwowide", "bowandarrow", "crossbow",
}

-- One-handed / hand-to-hand / thrown attack groups. These must stay usable
-- mid-cast (Allow Attacking While Quick-Casting / the 1H exception to
-- BlockWeaponDuringQuickcast). OpenMW gives each bone to exactly one active
-- animation: if the quickcast claims RightArm/Torso while a 1H swing is
-- already playing, the cast steals those bones and the swing freezes mid-
-- attack even though its priority is higher on paper. Detect these groups so
-- the cast can leave the swinging arm alone, and so no cancel path ever
-- touches them. 'weapononehand1' is the ReAnimation alternating 1H group.
Anim.LIGHT_ATTACK_GROUPS = {
    "weapononehand", "weapononehand1", "handtohand", "throwweapon",
}

-- True for every group the engine uses to put a weapon (or bare hands) into
-- the ready pose: the light groups plus the heavy ones, i.e. exactly the
-- groups whose draw and sheathe plays belong to a weapon-ready transition.
-- One predicate over the two attack lists above, so a duplicated copy of the
-- names cannot drift out of sync with them.
local function isWeaponReadyGroup(groupname)
    for _, g in ipairs(Anim.LIGHT_ATTACK_GROUPS) do
        if groupname == g then return true end
    end
    for _, g in ipairs(Anim.HEAVY_ATTACK_GROUPS) do
        if groupname == g then return true end
    end
    return false
end

-- Single lookup: nil means hand-to-hand (a worn shield is not a weapon).
local function getEquippedRightWeapon()
    local equipment = types.Actor.equipment(self)
    local weapon = equipment and equipment[SLOT.CarriedRight]
    if not weapon or not weapon:isValid() or weapon.type ~= types.Weapon then return nil end
    return weapon
end

-- Excluded combat group of the equipped weapon, or nil.
local function getExcludedWeaponGroup()
    local weapon = getEquippedRightWeapon()
    if not weapon then return nil end
    local rec = types.Weapon.record(weapon)
    if rec and rec.type ~= nil then
        return Anim.EXCLUDED_WEAPON_TYPE_TO_GROUP[rec.type]
    end
    return nil
end

-- True while the player is holding the attack button down (attack charge /
-- wind-up). ActorControls.use: 0 none, 1 attack, 2 cast spell.
local function isAttackUseHeld()
    return self.controls and self.controls.use == 1
end

-- True while a one-handed / hand-to-hand / thrown attack animation is the
-- active upper-body motion. Used to keep the cast off the swinging arm so a
-- mid-swing quickcast cannot freeze the attack mid-animation.
local function isLightAttackPlaying()
    for _, groupName in ipairs(Anim.LIGHT_ATTACK_GROUPS) do
        if anim.isPlaying(self, groupName) then return true end
    end
    return false
end

-- True when the cast must leave the weapon arm free so a 1H / H2H swing can
-- keep playing (or finish) through the quickcast. Covers both an already-
-- playing light attack and a held 1H charge that is about to release into one.
local function shouldPreserveLightAttackBones()
    if isLightAttackPlaying() then return true end
    -- Held charge with a non-heavy weapon: the release will play a light
    -- attack group. Keep RightArm free so that release is not stolen by the
    -- cast the moment it starts.
    if isAttackUseHeld() and getExcludedWeaponGroup() == nil then
        return true
    end
    return false
end

-- buildCastBlendOptions lives below the Stance table: it reads the quickkey
-- suppression state, so it must be defined after Stance (and debugLog).

-- True while the actor is staggered (hit reactions) or knocked down/out.
-- Used to cancel an in-flight OSSC cast at launch time.
local function isStaggeredOrKnocked()
    for _, groupName in ipairs(Anim.KNOCK_GROUPS) do
        if anim.isPlaying(self, groupName) then return true end
    end
    for _, groupName in ipairs(Anim.STAGGER_GROUPS) do
        if anim.isPlaying(self, groupName) then return true end
    end
    return false
end

local function debugLog(msg)
    if Cfg.debugMode then
        print("[OSSC] " .. tostring(msg))
    end
end

-- ── State ──
-- Shared state lives in tables (Cast/PMM/Stance): LuaJIT 60-upvalue limit.
-- Add new shared state as table fields, not new locals.
local Cast = {
    isCasting           = false,
    hasFiredThisCast    = false,
    pendingLaunches     = {},
    currentSpell        = nil,
    hasQueuedLaunch     = false,
    -- Set once by handleCastCosts and copied into each queued launch;
    -- launches must never re-read it from Cast.
    currentIsPaid       = false,
    -- nil when the casting framework already told the player.
    currentCostMessage  = nil,
    -- Latched separately from anim/audio: never debit the same cast twice.
    costPaidCastId      = nil,
    -- Latches start sound/VFX/safety timer to once per quickcast.
    startKeyCastId      = nil,
    spellvfx            = false,
    isGlowActive        = false,
    castFailed          = false,  -- true when cast was blocked (no magicka / failed roll); suppresses hit sound
    castStartTime       = 0,
    currentCastId       = 0,
    currentAnimGroup    = nil,
    currentAnimPriority = anim.PRIORITY.Scripted,
    prevTriggerValue    = 0.0,
    currentFinalSpeed   = 1.0,
    isBound2HWeaponCast = false,
    ngardeParryControlActive = false,
    -- One-time flag for the outdated-NGarde warning in setNgardeParryControl.
    ngardeMissingWarned = false,
}
-- Shared with the onUpdate stance mirror; one table for the upvalue limit.
local QuickkeyPress = {
    slot                  = nil,   -- QuickKey slot index of the pending press
    timer                 = 0,     -- countdown; the press resolves when it hits 0
    startedInSpellStance  = false, -- pre-press stance was Spell (captured at press time)
    sawSpellStance        = false, -- true once a Spell-stance raise was observed
    prePressStance        = nil,   -- stance immediately before this quickkey
    cooldownUntil         = 0,     -- retained for save/state compatibility
    cooldownActive        = false, -- held for the entire quick-slot cast animation
    blockedByCooldown     = false, -- this press only exists to suppress native stance
}
QuickkeyPress.prevSpellRecordId = nil    -- recordId (stable across loads)
QuickkeyPress.prevItemRecordId  = nil    -- recordId (stable across loads)
QuickkeyPress.lastMagicItemSlot = nil    -- last magic-item hotkey slot pressed
-- ── Pure Multi Mark Compatibility State & Functions ─────────────────────────
-- (One table for the same 60-upvalue reason as the Cast table above.)
local PMM = {
    pmmLocations            = {},
    isWaitingForPMMInput    = false,
    pmmSelectedDestination  = nil,
    pmmVanillaRecall        = false,
    pmmCancelled            = false,
    isCurrentCastMark       = false,
    isCurrentCastRecall     = false,
    pmmDeferredRecall       = false,  -- see the comment block below
    pmmUiClosedAt           = nil,    -- see the comment block below
    pmmUiOpenedAt           = nil,    -- see the comment block below
}
-- After-cast window: recall launch held at 'release' until a mark is picked;
-- any other exit cancels the recall (vanilla mark must not go through).
local resolvePMMRecall        -- assigned below, once animUnlock is defined

local function isPMMCompatEnabled()
    local val = Cfg.general and Cfg.general:get('PureMultiMarkCompat')
    if val ~= nil then
        return val == true
    end
    return true
end

-- ── Weapon attack lock (BlockWeaponDuringQuickcast) ───────────────────────
-- The reverse of Block Quick Cast During Combat Animations: while an OSSC
-- quick cast is in progress — and only while the cast animation actually has
-- the hands busy ("the hand is free of the weapon") — the player may not fire
-- the same heavy weapons that setting guards (two-hand and two-wide melee,
-- bows, crossbows). Two mechanisms work together:
--   1. The Fighting control switch (blocks weapon-attack input wholesale),
--      engaged only while an excluded weapon is actually equipped, so
--      swinging a one-hander mid-cast keeps working.
--   2. An animation-level cancel (see the playBlendedAnimation handler at the
--      bottom of this file) that aborts any heavy-weapon attack animation the
--      moment it starts, so a tap that slips past the switch is smoothed away
--      instead of playing over the cast.
-- Both are reconciled every frame (equip swaps / setting flips / cast end
-- take effect immediately).
Cast.weaponAttackLockActive = false
Cast.combatBlockActive      = false

-- True while a quickcast is in progress and its cast animation is meant to be
-- occupying the hands. This is the "hand is free of the weapon" gate: while
-- the cast is in flight, 2H / bow / crossbow attacks must not slip through.
-- We deliberately do NOT gate this on anim.isPlaying(self, currentAnimGroup):
-- a quickcast animation can transiently report not playing between text keys
-- or while it is being blended/re-fallback'd, and that gap is exactly when a
-- held two-handed attack would sneak past. The whole Cast.isCasting window is
-- therefore treated as "hands busy with the spell"; once the cast resolves
-- (stop key / safety timer / menu cleanup) the flags clear and attacks resume.
local function isHandFreeDuringCast()
    return Cast.isCasting
        and Cast.currentAnimGroup ~= nil
end

local function canUseFightingControlSwitch()
    return input and input.setControlSwitch and input.CONTROL_SWITCH
end

-- Heavy-weapon block condition; takes priority over AllowAttackingWhileCasting.
local BOUND_2H_EFFECT_IDS = {
    [core.magic.EFFECT_TYPE.BoundSpear]     = true,
    [core.magic.EFFECT_TYPE.BoundBattleAxe] = true,
    [core.magic.EFFECT_TYPE.BoundLongbow]   = true,
    ['boundspear']     = true,
    ['boundbattleaxe'] = true,
    ['boundlongbow']   = true,
}

local function hasBound2HWeaponEffect(activeSpell)
    if not activeSpell then return false end
    if activeSpell.effects then
        for _, eff in ipairs(activeSpell.effects) do
            if eff and eff.id and BOUND_2H_EFFECT_IDS[eff.id] then return true end
        end
    end
    local rec = spellRecs[activeSpell.id]
    if rec and rec.effects then
        for _, eff in ipairs(rec.effects) do
            if eff and eff.id and BOUND_2H_EFFECT_IDS[eff.id] then return true end
        end
    end
    if activeSpell.item and activeSpell.item:isValid() and activeSpell.item.type and activeSpell.item.type.record then
        local itemRec = activeSpell.item.type.record(activeSpell.item)
        if itemRec and itemRec.enchant and itemRec.enchant ~= "" then
            local enchRec = core.magic.enchantments.records[itemRec.enchant]
            if enchRec and enchRec.effects then
                for _, eff in ipairs(enchRec.effects) do
                    if eff and eff.id and BOUND_2H_EFFECT_IDS[eff.id] then return true end
                end
            end
        end
    end
    return false
end

local function shouldBlockHeavyAttack()
    if Cast.isBound2HWeaponCast then return false end
    if not (Cfg.general and Cfg.general:get('BlockWeaponDuringQuickcast')) then return false end
    if not isHandFreeDuringCast() then return false end
    return getExcludedWeaponGroup() ~= nil
end

Cast.suppressedBlockSkill = nil  -- unused, kept as placeholder so onSave/onLoad calls are harmless

Cast.suppressedShield    = nil   -- shield item unequipped during cast
Cast.shieldGhostVfxId    = 'OSSC_ShieldGhost'

-- Equipment is authoritative: bound spells, inventory equips and other mods
-- all reach this check. Never keep a cast's cosmetic shield over a 2H weapon.
-- Forget the saved shield too, so cleanup cannot overwrite the new loadout.
local function reconcileShieldWeapon()
    -- No ghost for hand-to-hand or a 2H weapon. If the right hand emptied
    -- mid-cast (weapon broke, bound weapon expired), give the hidden shield back.
    local rightWeapon = getEquippedRightWeapon()
    if rightWeapon ~= nil and getExcludedWeaponGroup() == nil then return false end
    anim.removeVfx(self, Cast.shieldGhostVfxId)
    if rightWeapon == nil and Cast.suppressedShield and Cast.suppressedShield:isValid() then
        local eq = types.Actor.getEquipment(self)
        if not eq[SLOT.CarriedLeft] then
            eq[SLOT.CarriedLeft] = Cast.suppressedShield
            types.Actor.setEquipment(self, eq)
        end
    end
    Cast.suppressedShield = nil
    return true
end

-- Unequip the shield to prevent blocking, but attach its mesh to the left-hand
-- bone via addVfx so it stays visually in place during the quickcast window.
local function suppressShieldDuringCast()
    if reconcileShieldWeapon() then return end
    if Cast.suppressedShield then return end
    local eq = types.Actor.getEquipment(self)
    local item = eq[SLOT.CarriedLeft]
    local armorRec = item and item.type == types.Armor
        and types.Armor.record(item) or nil
    local isShield = armorRec ~= nil and armorRec.type == types.Armor.TYPE.Shield
    -- One shared rule for both scripts (ossc_cast_rules.shouldGhostShield):
    -- the ghost VFX belongs to a cast that frees a WEAPON grip. Hand-to-hand
    -- (nothing in the right hand) is intentionally vanilla-looking: the shield
    -- stays on and no shield mesh ever appears next to the fists. A two-handed
    -- weapon / bow / crossbow already lost the shield (reconcileShieldWeapon
    -- above), and a cast with no shield has nothing to hide. Never leave a
    -- ghost behind from an earlier cast either.
    if not require('scripts.ossc.ossc_cast_rules').shouldGhostShield({
        rightWeapon    = getEquippedRightWeapon(),
        excludedWeapon = getExcludedWeaponGroup() ~= nil,
        shield         = isShield and item or nil,
        setting        = (Cfg.general
                          and Cfg.general:get('BlockShieldDuringQuickcast')) == true,
    }) then
        anim.removeVfx(self, Cast.shieldGhostVfxId)
        return
    end
    -- Attach the shield mesh as a looping VFX on the left-hand bone so the
    -- player still sees it while the equipment slot is vacant.
    if armorRec.model and armorRec.model ~= '' then
        anim.addVfx(self, armorRec.model, {
            loop            = true,
            vfxId           = Cast.shieldGhostVfxId,
            boneName        = 'Bip01 L Hand',
            useAmbientLight = false,
        })
        debugLog('Shield ghost VFX added: ' .. armorRec.model)
    end
    Cast.suppressedShield = item
    eq[SLOT.CarriedLeft] = nil
    types.Actor.setEquipment(self, eq)
    debugLog('Shield unequipped for blocking suppression: ' .. tostring(item.recordId))
end

-- Remove the ghost VFX and re-equip the shield after the cast ends.
local function restoreShieldAfterCast()
    reconcileShieldWeapon()
    anim.removeVfx(self, Cast.shieldGhostVfxId)
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

-- Shield block anims are cancelled by both the anim handler and onUpdate.
local function shouldBlockShield()
    if not (Cfg.general and Cfg.general:get('BlockShieldDuringQuickcast')) then return false end
    return isHandFreeDuringCast()
end

local function setWeaponAttackLock(locked)
    if not canUseFightingControlSwitch() then return end
    input.setControlSwitch(input.CONTROL_SWITCH.Fighting, not locked)
    Cast.weaponAttackLockActive = locked
    debugLog("Weapon attack lock " .. (locked and "engaged" or "released"))
end

local function setCombatBlock(locked)
    if not I.Controls or not I.Controls.overrideCombatControls then return end
    I.Controls.overrideCombatControls(locked)
    Cast.combatBlockActive = locked
    debugLog("Combat block " .. (locked and "engaged" or "released"))
end

local function shouldHoldCombatBlock()
    if not Cast.isCasting then return false end
    if not (Cfg.general and Cfg.general:get('AllowAttackingWhileCasting')) then
        return true
    end
    -- Priority over AllowAttackingWhileCasting; bound 2H spells exempt so the mesh initialises.
    if not Cast.isBound2HWeaponCast
        and Cfg.general:get('BlockWeaponDuringQuickcast') == true
        and getExcludedWeaponGroup() ~= nil then
        return true
    end
    return false
end

local function reconcileWeaponAttackLock()
    local wantLock = shouldBlockHeavyAttack()
    if wantLock ~= Cast.weaponAttackLockActive then
        setWeaponAttackLock(wantLock)
    end
end

local function reconcileCombatBlock()
    local wantLock = shouldHoldCombatBlock()
    if wantLock ~= Cast.combatBlockActive then
        setCombatBlock(wantLock)
    end
end

-- NGarde exclusion: start gate rejects cast-after-parry, this rejects parry-after-cast.
local function setNgardeParryControl(active)
    -- Truthy check must match triggerQuickCast's gate.
    local settingOn = Cfg.general and Cfg.general:get('BlockDuringNGardeParry')
    active = (active == true) and (settingOn and true or false)
    local ngarde = I.NGardePlayer
    if ngarde and type(ngarde.externalParryControl) == 'function' then
        if active and type(ngarde.forceLowerGuard) == 'function' then
            ngarde.forceLowerGuard()
        end
        ngarde.externalParryControl(active)
        Cast.ngardeParryControlActive = active
        debugLog('NGarde parry control ' .. (active and 'engaged (guard raises blocked during cast)' or 'released'))
    else
        Cast.ngardeParryControlActive = false
        -- Interface without externalParryControl = outdated NGarde: warn once.
        if active and ngarde ~= nil and not Cast.ngardeMissingWarned then
            Cast.ngardeMissingWarned = true
            print('[OSSC] WARNING: Block Quick Cast During NGarde Parry is on, but this NGarde version has no externalParryControl — guards can still rise mid-cast. Update NGarde.')
        end
    end
end

local function isPMMInstalled()
    return Cfg.pmmInstalled == true
end

local function getPMMMaxMarks()
    local baseline = Cfg.pmm and Cfg.pmm:get('MARKS_BASELINE') or 1
    local skillStep = Cfg.pmm and Cfg.pmm:get('SKILL_STEP') or 20
    baseline = tonumber(baseline) or 1
    skillStep = tonumber(skillStep) or 20
    if skillStep <= 0 then skillStep = 20 end

    local actorIntelligence = types.Player.stats.attributes['intelligence'](self).modified or 0
    local actorMysticism = types.Player.stats.skills['mysticism'](self).modified or 0

    local maxMarks = baseline + math.floor((actorMysticism + actorIntelligence * 0.2) / skillStep)
    for _, sp in pairs(types.Actor.spells(self)) do
        if sp.id == 'roguelite_mark' then
            maxMarks = maxMarks + 2
            break
        end
    end
    return math.max(1, maxMarks)
end

local function checkMarkRecall(spell)
    if not spell then return false, false end
    local isMark, isRecall = false, false
    local function checkEffects(effects)
        if not effects then return end
        for _, eff in ipairs(effects) do
            if eff.id == 'mark' then isMark = true end
            if eff.id == 'recall' then isRecall = true end
        end
    end
    checkEffects(spell.effects)
    if not isMark and not isRecall and spell.id then
        local rec = spellRecs[spell.id] or enchRecs[spell.id]
        if rec then checkEffects(rec.effects) end
    end
    return isMark, isRecall
end

local function handlePMMMark()
    if not self.cell then return end
    local maxMarks = getPMMMaxMarks()
    local slot = #PMM.pmmLocations + 1
    if slot > maxMarks then
        slot = maxMarks
        ui.showMessage('last mark overwritten (' .. slot .. '/' .. maxMarks .. ')')
    end

    local name = self.cell.name
    if not name or name == '' then
        name = self.cell.region
        if not name or name == '' then
            name = self.cell.id
        elseif core.regions and core.regions.records[name] then
            name = core.regions.records[name].name
        end
    end
    if not name or name == '' then name = 'Marked Location' end

    if self.cell.isExterior then
        name = name .. ' ' .. self.cell.gridX .. '/' .. self.cell.gridY
        print('[OSSC PMM] Marked ' .. name .. ' (slot ' .. slot .. '/' .. maxMarks .. ')')
        PMM.pmmLocations[slot] = {
            name = name,
            gridX = self.cell.gridX,
            gridY = self.cell.gridY,
            position = self.position,
            rotation = self.rotation,
        }
    else
        print('[OSSC PMM] Marked ' .. name .. ' (slot ' .. slot .. '/' .. maxMarks .. ')')
        PMM.pmmLocations[slot] = {
            name = name,
            cell = self.cell.id,
            position = self.position,
            rotation = self.rotation,
        }
    end
end

-- Global callbacks expected by PMM_markWindow.
function selectedMark(id)
    PMM.isWaitingForPMMInput = false
    PMM.pmmUiClosedAt = core.getSimulationTime()
    PMM.pmmUiOpenedAt = nil
    PMM.pmmCancelled = false
    if I.UI and I.UI.setMode then I.UI.setMode() end
    if Cast.isCasting then
        if id and id > 0 and resolvePMMRecall then
            -- Mark picked: resolve the held recall now.
            PMM.pmmSelectedDestination = id
            PMM.pmmVanillaRecall = false
            resolvePMMRecall('PMM mark selected')
        else
            -- No mark picked: cancel; the vanilla mark must not go through.
            PMM.pmmSelectedDestination = nil
            PMM.pmmVanillaRecall = false
            PMM.pmmCancelled = true
            debugLog('[OSSC PMM] Recall cancelled — vanilla mark does not go through')
        end
    end
end

function cancelCasting()
    PMM.pmmCancelled = true
    PMM.isWaitingForPMMInput = false
    PMM.pmmUiClosedAt = core.getSimulationTime()
    PMM.pmmUiOpenedAt = nil
    PMM.pmmSelectedDestination = nil
    if I.UI and I.UI.setMode then I.UI.setMode() end
end

-- Guard: the global is defined by PMM_markWindow and may be missing.
local function destroyPMMWindow()
    if destroyTeleportWindow then destroyTeleportWindow() end
end

function getMaxMarks()
    return getPMMMaxMarks()
end

local function openPMMRecallWindow()
    PMM.isWaitingForPMMInput = true
    PMM.pmmSelectedDestination = nil
    PMM.pmmVanillaRecall = false
    PMM.pmmCancelled = false
    PMM.pmmUiClosedAt = nil
    PMM.pmmUiOpenedAt = core.getSimulationTime()

    -- PMM_markWindow reads these globals (engine modules are exported at file top).
    saveData = { locations = PMM.pmmLocations }
    playerSection = Cfg.pmm
    LIST_ENTRIES = playerSection and playerSection:get('LIST_ENTRIES') or 15
    local ok, rd = pcall(require, 'scripts.puremultimark.PMM_renameDialog')
    if ok and rd then
        renameDialog = rd
    else
        if not ok then
            debugLog('[OSSC PMM] Failed to load PMM_renameDialog: ' .. tostring(rd))
        end
        -- PMM_markWindow calls renameDialog unconditionally: inert stubs.
        renameDialog = {
            isOpen = function() return false end,
            close  = function() end,
            show   = function() end,
        }
    end
    DEMO_MODE = false
    onFrameFunctions = onFrameFunctions or {}
    currentScrollPos = currentScrollPos or 1
    controllerRow = controllerRow or 0
    controllerColumn = controllerColumn or 1
    controllerConfirmDown = controllerConfirmDown or false

    local windows = {}
    if I.UI and I.UI.isWindowVisible then
        for _, windowName in pairs(I.UI.WINDOW) do
            if I.UI.isWindowVisible(windowName) then
                table.insert(windows, windowName)
            end
        end
    end
    if I.UI and I.UI.setMode then
        local controllerMode = playerSection and playerSection:get('CONTROLLER_MODE')
        I.UI.setMode('Interface', { windows = not controllerMode and windows or {} })
    end

    if package and package.loaded then
        package.loaded['scripts.puremultimark.PMM_markWindow'] = nil
    end
    local loadOk, err = pcall(require, 'scripts.puremultimark.PMM_markWindow')
    if not loadOk then
        debugLog('[OSSC PMM] Failed to load PMM_markWindow: ' .. tostring(err))
        PMM.isWaitingForPMMInput = false
        PMM.pmmUiClosedAt = core.getSimulationTime()
        PMM.pmmUiOpenedAt = nil
        -- Caller cancels the recall; the vanilla mark must not go through.
        if I.UI and I.UI.setMode then I.UI.setMode() end
    end
end

-- ── Stance suppression (CastOnQuickkeys / SuppressSpellStance) ──
local Stance = {
    lastNonSpellStance = nil,   -- initialised just below
    -- Weapon DRAW tracker shared with the actor script: a 2H draw and a 2H
    -- attack are the same animation group, and cancelling the draw before the
    -- engine's 'equip attach' key leaves the weapon equipped with no mesh.
    -- The per-frame attack cancel below skips whatever group is drawing.
    drawTracker        = require('scripts.ossc.ossc_cast_rules').newDrawTracker(),
    spellStanceAllowed = false, -- persistent toggle: user pressed R, wants spell stance open
    prevStance         = nil,   -- stance on the previous frame (pre-toggle intent, see onFrame)
    prevSpellKeyDown   = false,
    prevWeaponKeyDown  = false,
    isGrimoireIdlePlaying = false, -- grimoire idle animation state (see below)
    -- ── Previous-frame baseline ──
    -- The engine applies quickkeys BEFORE Lua input handlers, so this end-of-frame
    -- snapshot is the true pre-press state. Refreshed by updatePrevFrameStore / onLoad.
    prevFrameSpell     = nil,
    prevFrameItem      = nil,
    prevFrameStance    = nil,
    prevFrameEquipment = nil,
    -- ── Stance to restore after a quickkey cast ──
    -- Cleared only by animUnlock; a spam press must NOT clear it.
    postCastRestore    = nil,
    -- Post-press suppression window for delayed native Spell raises;
    -- separate from QuickkeyPress.slot, which may already be consumed.
    nativeQuickkeySuppression       = false,
    nativeQuickkeySuppressionUntil  = 0,
    nativeQuickkeyRestoreTarget     = nil,
    nativeQuickkeyWeapon            = nil,
    prevFrameWeapon                 = nil,
    -- Stance a quickkey press started from, read by triggerQuickCast's
    -- spell-stance gate (the live stance is already the engine's raise by then).
    quickkeyCastStance              = nil,
}
Stance.lastNonSpellStance = types.Actor.getStance(self)
if Stance.lastNonSpellStance == STANCE.Spell then
    Stance.lastNonSpellStance = STANCE.Nothing
end
Stance.prevStance = types.Actor.getStance(self)
-- (spellStanceAllowed / prevStance / prevSpellKeyDown / prevWeaponKeyDown /
--  isGrimoireIdlePlaying now live in the Stance table above.)

-- Per-bone-group priorities + blend mask for an OSSC cast. When a light
-- attack owns the weapon arm the cast is restricted to LeftArm (+ legs at
-- WeaponLowerBody) so the swing keeps RightArm/Torso; otherwise the full
-- upper-body mask is used so 2H grip idles cannot pin the casting arm.
local function buildCastBlendOptions(finalSpeed, animGroup)
    -- Relaxed stance (Nothing -- weapon sheathed, nothing readied): no grip
    -- idle pins the casting arm, so the cast stays on the casting hand alone.
    -- A suppressed quickkey cast is still standing in the engine's transient
    -- Spell raise when the cast starts (the revert lands right after
    -- triggerQuickCast): judge the pre-press stance the actor actually casts
    -- in, not the transient raise.
    local stance = types.Actor.getStance(self)
    if Stance.nativeQuickkeySuppression and Stance.nativeQuickkeyRestoreTarget ~= nil then
        stance = Stance.nativeQuickkeyRestoreTarget
    end
    local preserveAttack = shouldPreserveLightAttackBones()
    -- One rule for every OSSC caster (player, NPC, creature):
    -- scripts/ossc/ossc_cast_rules.lua. Required inline: this chunk is at
    -- Lua's 200-local limit.
    local opts, leftArmOnly = require('scripts.ossc.ossc_cast_rules').buildCastBlendOptions{
        speed = finalSpeed, animGroup = animGroup, stance = stance, preserveAttack = preserveAttack,
    }
    if leftArmOnly then
        debugLog("Cast blend: LeftArm-only cast (" .. tostring(animGroup)
            .. " stance=" .. tostring(stance)
            .. " midSwing=" .. tostring(preserveAttack) .. ")")
    end
    return opts
end

-- ── NEW — grimoire idle state ──────────────────────────────────────────────
local OSSC_PowerCooldowns = {}

local function isSpeedyMagickInstalled()
    -- Decided by load order. Do not probe storage sections: reading creates them.
    if I.SpeedyMagick or I.yksuiSpeedyMagick or I.yksui_speedy_magick then
        return true
    end
    local wanted = 'yksuispeedymagick.omwscripts'
    if core.contentFiles.has('yksuiSpeedyMagick.omwscripts') then return true end
    for _, name in ipairs(core.contentFiles.list or {}) do
        if type(name) == 'string' and name:lower() == wanted then return true end
    end
    return false
end

local function getSpeedyMagickSpeedMult()
    if not Cfg.general or Cfg.general:get('EnableSpeedyMagick') ~= true then
        return 1.0
    end

    local spd = types.Actor.stats.attributes.speed(self).modified or 50.0
    if spd <= 0 then spd = 50.0 end
    return 2.0 / (1.0 + 2.0 ^ -(spd / 100.0))
end

-- ── Ralts Nifty Spell Pack — Alacrity compatibility ──
-- NSP only speeds the vanilla 'spellcast' group; apply the same multiplier here.
local NSP_ALACRITY_EFFECT_ID = 'nsp_alacrity'
local NSP_ALACRITY_MAX_SPEED = 4.0
local hasNspAlacrity = (core.magic.effects.records[NSP_ALACRITY_EFFECT_ID] ~= nil)

local function getNSPAlacritySpeedMult()
    if not hasNspAlacrity then return 1.0 end

    local activeEffects = types.Actor.activeEffects(self)
    if activeEffects then
        local effect = activeEffects:getEffect(NSP_ALACRITY_EFFECT_ID)
        local magnitude = effect and effect.magnitude or 0
        if magnitude > 0 then
            local mult = 1 + (magnitude / 100 * (NSP_ALACRITY_MAX_SPEED - 1))
            debugLog("NSP Alacrity active: magnitude=" .. tostring(magnitude) .. " → speedMult=" .. tostring(mult))
            return mult
        end
    end
    return 1.0
end

-- ── Shield Casting Penalty ──
-- capacity = (Str + Proficiency)/2; penalty = W*45/(capacity+45); mult = 1 - penalty/100*v
-- W = shield weight capped at 45; mult clamped to >= 0.55.
local function getShieldCastingPenaltyMult(schoolStr, isItem)
    if not Cfg.general then return 1.0 end
    local mode = Cfg.general:get('ShieldCastingPenalty')
    local skillBased = Penalty.isSkillBased(mode)
    local v = skillBased and 1.0 or Penalty.shield.strength(mode)
    if v <= 0 then return 1.0 end

    local equipment = types.Actor.equipment(self)
    local shield = equipment and equipment[SLOT.CarriedLeft]
    if not shield or not shield:isValid() or shield.type ~= types.Armor then return 1.0 end

    local rec = types.Armor.record(shield)
    local W = (rec and rec.weight) or 0
    if W <= 0 then return 1.0 end
    if W > 45 then W = 45 end

    local S = types.Actor.stats.attributes.strength(self).modified or 0
    local skillId = (isItem and 'enchant') or schoolStr
    local P = 0
    local accessor = types.NPC.stats.skills[skillId]
    local skill = accessor and accessor(self)
    if skill then P = skill.modified or 0 end

    if skillBased then v = Penalty.shield.skillStrength(P) end
    if v <= 0 then return 1.0 end

    local capacity = (S + P) / 2
    local penalty  = W * 45 / (capacity + 45)
    local mult = 1 - (penalty / 100) * v
    if mult < 0.55 then mult = 0.55 end

    debugLog(string.format("Shield penalty: W=%s S=%s P=%s (%s) → penalty=%s mult=%s",
        tostring(W), tostring(S), tostring(P), tostring(skillId), tostring(penalty), tostring(mult)))

    return mult
end

local MAGIC_SKILLS = {
    alteration  = { attribute = 'willpower',    specialization = 'magic', name = 'Alteration' },
    conjuration = { attribute = 'intelligence', specialization = 'magic', name = 'Conjuration' },
    destruction = { attribute = 'willpower',    specialization = 'magic', name = 'Destruction' },
    illusion    = { attribute = 'personality',  specialization = 'magic', name = 'Illusion' },
    mysticism   = { attribute = 'willpower',    specialization = 'magic', name = 'Mysticism' },
    restoration = { attribute = 'willpower',    specialization = 'magic', name = 'Restoration' },
    enchant     = { attribute = 'intelligence', specialization = 'magic', name = 'Enchant' }
}

local SCHOOL_STRS = {
    [0]="alteration",[1]="conjuration",[2]="destruction",
    [3]="illusion",[4]="mysticism",[5]="restoration"
}

-- Effective skill for the cast's school (Enchant for items); school may be a name or 0-5 index.
local function getMagicSkillValue(caster, school, isItem)
    if not (caster and caster.isValid and caster:isValid()) then return 0 end
    local skillId = isItem and 'enchant' or school
    if type(skillId) == "number" then skillId = SCHOOL_STRS[skillId] end
    if type(skillId) ~= "string" then return 0 end
    local accessor = types.NPC.stats.skills[skillId]
    if not accessor then return 0 end
    local s = accessor(caster)
    return (s and s.modified) or 0
end

local function isParalyzedOrSilenced(caster)
    local paralyze = 0
    local silence = 0
    local activeEffects = types.Actor.activeEffects(caster)
    if activeEffects then
        local parEffect = activeEffects:getEffect("paralyze")
        local silEffect = activeEffects:getEffect("silence")
        if parEffect then paralyze = parEffect.magnitude or 0 end
        if silEffect then silence = silEffect.magnitude or 0 end
    end
    return (paralyze > 0) or (silence > 0)
end

local function isOverEncumbered(actor)
    local encumbrance = types.Actor.getEncumbrance(actor)
    local capacity = types.Actor.getCapacity(actor)
    return type(encumbrance) == 'number'
        and type(capacity) == 'number'
        and encumbrance > capacity
end

local function isQuickcastInterrupted()
    if types.Actor.isDead(self) then return true end
    -- Actor.canMove is also false while overencumbered. Over capacity prevents
    -- locomotion, not spellcasting/teleport magic; treating it as a stagger
    -- cancelled Mark/Recall after their animation and success sound. Preserve
    -- the canMove fallback for real knockdowns, but exclude encumbrance.
    if not types.Actor.canMove(self) and not isOverEncumbered(self) then return true end
    if isParalyzedOrSilenced(self) then return true end
    for _, groupName in ipairs(Anim.INCAPACITATED_GROUPS) do
        if anim.isPlaying(self, groupName) then return true end
    end
    return false
end

-- Match OpenMW's data-mw/scripts/omw/playerskillhandlers.lua without
-- re-entering the external skillUsed handler chain (a caller may already be
-- inside that chain when it calls awardSkillProgress).
local function getSkillClass()
    local npc = types.NPC.record(self)
    return npc and npc.class and types.NPC.classes.record(npc.class)
end

local function classHasSkill(skills, skillId)
    for _, id in pairs(skills or {}) do
        if id == skillId then return true end
    end
    return false
end

local function skillProgressRequirement(skillId, base)
    local cls = getSkillClass()
    local rec = core.stats.Skill.record(skillId)
    local factor = core.getGMST('fMiscSkillBonus') or 1.25
    if cls then
        if classHasSkill(cls.majorSkills, skillId) then
            factor = core.getGMST('fMajorSkillBonus') or 0.75
        elseif classHasSkill(cls.minorSkills, skillId) then
            factor = core.getGMST('fMinorSkillBonus') or 1.0
        end
        if rec and rec.specialization == cls.specialization then
            factor = factor * (core.getGMST('fSpecialSkillBonus') or 0.8)
        end
    end
    return (base + 1) * factor
end

local function levelUpSkill(skillId, newBaseValue)
    local skill = types.NPC.stats.skills[skillId](self)
    skill.base = newBaseValue
    -- Vanilla usage raises at most one level and discards overflow.
    skill.progress = 0
    local skillData = core.stats.Skill.record(skillId) or MAGIC_SKILLS[skillId]
    local displayName = skillData and skillData.name or skillId
    ui.showMessage(string.format(GMST.sSkillUp, displayName, newBaseValue))
    core.sound.playSound3d("skillraise", self)
    local levelStats = types.Player.stats.level(self)
    if levelStats then
        local cls = getSkillClass()
        local levelGain = 0
        -- This spelling is the engine's actual GMST id.
        local attributeGain = core.getGMST('iLevelupMiscMultAttriubte') or 1
        if cls and classHasSkill(cls.minorSkills, skillId) then
            levelGain = core.getGMST('iLevelUpMinorMult') or 1
            attributeGain = core.getGMST('iLevelUpMinorMultAttribute') or 1
        elseif cls and classHasSkill(cls.majorSkills, skillId) then
            levelGain = core.getGMST('iLevelUpMajorMult') or 1
            attributeGain = core.getGMST('iLevelUpMajorMultAttribute') or 1
        end
        levelStats.progress = (levelStats.progress or 0) + levelGain
        if skillData and skillData.attribute then
            local attr = skillData.attribute
            levelStats.skillIncreasesForAttribute[attr] =
                (levelStats.skillIncreasesForAttribute[attr] or 0) + attributeGain
        end
        if skillData and skillData.specialization then
            local spec = skillData.specialization
            levelStats.skillIncreasesForSpecialization[spec] =
                (levelStats.skillIncreasesForSpecialization[spec] or 0)
                + (core.getGMST('iLevelupSpecialization') or 1)
        end
        if levelStats.progress >= (core.getGMST('iLevelUpTotal') or 10) then
            ui.showMessage(core.getGMST('sLevelUpMsg') or '#{sLevelUpMsg}')
        end
    end
end

-- ============================================================
-- [SKILL] Public skill-progression entry point
--
-- 'none' in the Skill Progression Mode setting means OSSC awards no experience
-- at all, because another mod owns spellcasting progression.  That other mod
-- needs a supported way to apply its own gain - without one, 'none' leaves it
-- writing skill.progress by hand and re-implementing Morrowind's level-up
-- bookkeeping.  So the award function lives here, on the public interface, and
-- is deliberately NOT gated by the setting.
-- ============================================================

--- Raw skill-use points, not a fraction of a level. A ratio of 1 uses the
--- loaded skill record unchanged, including changes made by content mods.
local function defaultSkillGain(skillId, useType)
    local rec = core.stats.Skill.record(skillId)
    local gain = rec and rec.skillGain and rec.skillGain[useType + 1]
    local ratio = tonumber(Cfg.general and Cfg.general:get('SkillExperience')) or 1
    return (gain or 0) * ratio
end

--- Award spellcasting skill experience to the player.
---
---     I.OSSC.awardSkillProgress('destruction', { skillGain = 0.35 })
---
--- Works whatever the Skill Progression Mode setting says, 'none' included.
---
--- @param skillId string  skill record id: 'destruction', 'enchant', ... or a
---                        custom skill with an NPC stat and skill record
--- @param options table?
---   skillGain number   raw vanilla skill-use points, as in SkillProgression.
---                      Divided by (base + 1) and the class/specialization
---                      factor. An explicit gain is not scaled by settings.
---   useType   number   SkillProgression use type (0..3), selects the skill
---                      record gain when skillGain is absent; also forwarded
---                      on backend = 'external'. Defaults to Enchant_UseMagicItem ("Cast
---                      When Used") for skillId 'enchant' - the only enchant
---                      raise a quick-cast can trigger is a CastOnUse item -
---                      and to Spellcast_Success for every other skill.
---   backend   string   'stat' (default): apply it to the player's skill here.
---                      'external': hand the use to I.SkillProgression.skillUsed
---                      (NCG / Skill Evolution / MBSP / SUS), which then owns
---                      the formula.
--- @return boolean true when the gain was applied or handed on
--- @return string? why it was not, when it was not
local function awardSkillProgress(skillId, options)
    options = (type(options) == 'table') and options or {}
    if type(skillId) ~= 'string' or skillId == '' then
        return false, 'skillId must be a non-empty string'
    end

    local accessor = types.NPC.stats.skills[skillId]
    if not accessor then return false, 'unknown skill: ' .. skillId end
    local stat = accessor(self)
    if not stat or stat.progress == nil then
        return false, 'skill stat is not available: ' .. skillId
    end
    if (stat.base or 0) >= 100 then return false, 'skill is already at 100' end

    local useType = options.useType
    if useType == nil then useType = skillId == 'enchant' and 1 or 0 end
    if type(useType) ~= 'number' or useType ~= math.floor(useType)
        or useType < 0 or useType > 3 then
        return false, 'useType must be an integer from 0 to 3'
    end
    local gain = tonumber(options.skillGain)
    if options.skillGain ~= nil and (not gain or gain ~= gain or math.abs(gain) == math.huge) then
        return false, 'skillGain must be a finite number'
    end

    if options.backend == 'external' then
        if not (I.SkillProgression and I.SkillProgression.skillUsed) then
            return false, 'no external skill-progression interface is installed'
        end
        I.SkillProgression.skillUsed(skillId, {
            useType   = useType,
            skillGain = gain,
        })
        debugLog("[OSSC] handed " .. skillId .. " to I.SkillProgression.skillUsed")
        return true
    end

    if types.NPC.isWerewolf and types.NPC.isWerewolf(self) then
        return false, 'werewolves do not gain skill experience'
    end
    gain = gain or defaultSkillGain(skillId, useType)
    if gain ~= gain or gain == math.huge or gain <= 0 then return false, 'nothing to award' end
    local requirement = skillProgressRequirement(skillId, stat.base)
    if requirement <= 0 then return false, 'skill progress requirement must be positive' end

    local progress = stat.progress + gain / requirement
    if progress >= 1 then
        levelUpSkill(skillId, stat.base + 1)
    else
        stat.progress = progress
    end
    debugLog(string.format("[OSSC] awarded %.4f skill-use points (%.4f progress) to %s",
        gain, gain / requirement, skillId))
    return true
end

-- Maps a stored quick-cast penalty value onto the multiplier applied to the
-- success chance / the spell's effects. The accepted values and their meaning
-- live in scripts/ossc/ossc_penalty.lua, shared with the settings menu.
local getPenaltyScale = Penalty.scale

-- Powers never pay the Quick Cast Effect Penalty: the setting only ever
-- described magnitude/duration on spells, and a Power burning its once-a-day
-- use must land at full strength.  When the scroll exclusion toggle is on,
-- scrolls are excluded too: a scroll is consumed by the cast, so a penalised
-- one would be lost for a weakened effect.  Scrolls are recognised the same
-- way upcalls see them — as CastOnce enchantments.  Regular spells and
-- equipped magic items (CastOnUse / ConstantEffect) are always penalised.
--
-- Sure casts (powers, abilities, "Always Succeeds" spells) are exempt from
-- the Quick Cast Chance Penalty (getCastChance answers 100 before any
-- scaling — vanilla never rolls a sure cast). The Quick Cast Effect Penalty
-- keeps its own, separate rule: Powers — and Powers alone — never pay it
-- (effectPenaltyExempt below). UseFatigue and the Shield Casting Penalty
-- apply to every cast.
local function isSureCastSpell(spell)
    if not spell then return false end
    -- An enchanted-item cast must never be read as a spell record: an
    -- enchantment record's `type` is an EnchantmentType whose numbers overlap
    -- SPELL_TYPE's (CastOnUse == Ability == 1). Every cast through
    -- ossc_actor_items.lua is flagged `item` / `enchantment`.
    if spell.item or spell.enchantment then return false end
    if casterUtils.isSureCastRecord(spell) then return true end
    local rec = spell.id and spellRecs[spell.id] or nil
    return casterUtils.isSureCastRecord(rec)
end

--- Whether the Quick Cast Effect Penalty skips this cast. Two rules: Powers
--- never pay it (unconditional — a Power burning its once-a-day use must
--- land at full strength; abilities and "Always Succeeds" spells are NOT
--- covered, their only exemption is the chance penalty — see
--- isSureCastSpell), and the QuickCastEffectPenaltyScrollsExempt toggle
--- excludes scrolls — and scrolls alone — when it is on. Scrolls are
--- recognised the same way upcalls see them — as CastOnce enchantments.
--- Enchanted items are always penalised: every cast through
--- ossc_actor_items.lua is flagged `item`. An enchanted-item cast's records
--- are never read as SPELL records (an enchantment record's `type` is an
--- EnchantmentType whose numbers overlap SPELL_TYPE's).
local function effectPenaltyExempt(spell)
    if not spell then return false end

    -- Powers never pay the Quick Cast Effect Penalty (unconditional).
    if not spell.item and not spell.enchantment then
        if spell.type == SPELL_TYPE.Power then return true end
        local rec = spell.id and spellRecs[spell.id] or nil
        if rec and rec.type == SPELL_TYPE.Power then return true end
    end

    -- The exclusion toggle covers scrolls ONLY.  While it is off, nothing
    -- else is exempt.
    if not (Cfg.general and Cfg.general:get('QuickCastEffectPenaltyScrollsExempt')) then
        return false
    end

    -- Toggle on.  A scroll is the CastOnce enchantment form and is exempt; a
    -- spell (no enchantment record) or a CastOnUse / ConstantEffect item is
    -- still penalised.
    local ench = spell.enchantment or (spell.id and enchRecs[spell.id])
    return ench ~= nil and ench.type == ENCHTYPE.CastOnce
end

--- Vanilla skill-progression gate, mirroring the engine's own
--- `spellIncreasesSkill` (mwmechanics/spellutil.cpp): a cast raises
--- Spellcast_Success only when it is a plain ST_Spell record without the
--- "Always Succeeds" flag.  Abilities, Powers, diseases/curses and
--- always-succeed spells raise no skill in vanilla, so OSSC must neither
--- award nor announce one for them - OSSC_SkillProgressSkipped tells a
--- consumer to grant progress vanilla never would have granted.  The same
--- sure casts that skip the cast-chance roll skip skill progress.  A cast
--- whose record carries no type at all (a custom spell table) is treated as
--- a regular spell: the default-award side of an unknown.
local function spellIncreasesSkill(spell)
    if not spell then return false end
    -- An enchanted-item cast is never a SPELL record (see isSureCastSpell):
    -- its `type` is an EnchantmentType whose numbers overlap SPELL_TYPE's.
    if spell.item or spell.enchantment then return false end
    local rec = (spell.id and spellRecs[spell.id]) or spell
    if rec.item or rec.enchantment then return false end
    if rec.alwaysSucceedFlag == true then return false end
    if rec.type == nil then return true end
    return rec.type == SPELL_TYPE.Spell
end

--- Vanilla Enchant progression gate (engine `CastSpell::cast(item)`): using
--- an enchanted item raises Enchant only for CastOnUse - "Cast When Used" -
--- enchantments.  Scrolls (CastOnce) just destroy themselves and
--- ConstantEffect items are passive; CastOnStrike raises its own use type
--- and never passes a quick-cast.  Since a CastOnUse quick-cast is the ONLY
--- way an OSSC cast can raise Enchant, `skillId == 'enchant'` unambiguously
--- means "Cast When Used" from there on - no separate isEnchant signal is
--- needed anywhere in the skill-gain path.
local function itemIncreasesEnchantSkill(spell)
    if not spell then return false end
    local ench = spell.enchantment or (spell.id and enchRecs[spell.id])
    return ench ~= nil and ench.type == ENCHTYPE.CastOnUse
end

local function getDominantSkillSchool(spell)
    if not (spell and spell.effects) then return nil end
    local totals = {}
    for _, eff in ipairs(spell.effects) do
        local mgef = effectRecs[eff.id]
        if mgef and mgef.school then
            local school = (type(mgef.school)=="string") and mgef.school:lower() or SCHOOL_STRS[mgef.school]
            if school then
                local mag = ((eff.magnitudeMin or 0)+(eff.magnitudeMax or eff.magnitudeMin or 0))*0.5
                local dur = math.max(1, eff.duration or 1)
                local areaFactor = 1+((eff.area or 0)/100)
                local weight = math.max(1,mag)*dur*areaFactor
                totals[school] = (totals[school] or 0)+weight
            end
        end
    end
    local bestSchool, bestWeight = nil, -1
    for school, weight in pairs(totals) do
        if weight > bestWeight then bestWeight=weight; bestSchool=school end
    end
    return bestSchool
end

-- ── Enchanted item cost / charge ──
-- Paid from item charge, no skill roll. Cost = 0.01*(110 - Enchant)*spell cost;
-- prefer SFP's value so the gate and launch deduction cannot disagree.
local function getEnchantmentCost(spell)
    if I.MagExp_Player and I.MagExp_Player.Helpers
        and I.MagExp_Player.Helpers.getModifiedSpellCost then
        local cost = I.MagExp_Player.Helpers.getModifiedSpellCost(self, spell.id, true)
        if tonumber(cost) then return tonumber(cost) end
    end
    local skill = 0
    local stat = types.NPC.stats.skills.enchant(self)
    if stat then skill = stat.modified or stat.base or 0 end
    return math.max(1, math.floor(0.01 * (110 - skill) * (spell.cost or 1)))
end

-- itemData() can be nil on a never-described item: fall back to full capacity.
local function getItemCharge(spell)
    local ench = spell.enchantment or (spell.id and enchRecs[spell.id])
    local charge = (ench and ench.charge) or 0
    local item = spell.item
    if item and item:isValid() and types.Item.itemData then
        local itemData = types.Item.itemData(item)
        if itemData and itemData.enchantmentCharge ~= nil then
            charge = itemData.enchantmentCharge
        end
    end
    return charge
end

-- CastOnce consumed whole; Constant Effect never spends charge; others need charge.
local function canAffordItemCast(spell)
    local ench = spell.enchantment or (spell.id and enchRecs[spell.id])
    local enchType = ench and ench.type
    if enchType == ENCHTYPE.CastOnce then
        local item = spell.item
        return item ~= nil and item:isValid() and (item.count or 0) > 0
    end
    if enchType == ENCHTYPE.ConstantEffect then return true end
    local cost = getEnchantmentCost(spell)
    if cost <= 0 then return true end
    return getItemCharge(spell) >= cost
end

local function getCastChance(spell, caster)
    -- ── Sure casts are sure ───────────────────────────────────────────────
    -- Vanilla never rolls to see whether a Power goes off; it spends the
    -- once-a-day use and the spell lands.  Abilities and "Always Succeeds"
    -- spells are the same kind of sure cast.  Spell Framework Plus agrees and
    -- reports a 100% chance for a power (magexp_helpers.getSpellCastChance),
    -- but the quick-cast chance penalty below multiplied that 100 by its own
    -- scale — and the skill scale at skill 0 is 0.5, so a power cast through
    -- the quick-cast system resolved at exactly 50% and the release-moment
    -- roll dropped every other one.  A sure cast is answered here, before the
    -- chance penalty can touch it: always 100, whatever the settings or the
    -- skill.  (That chance exemption is what this rule grants; the effect
    -- penalty keeps its own Powers-only exclusion, and fatigue and the
    -- shield slowdown apply to every cast.)
    if isSureCastSpell(spell) then
        return 100, getDominantSkillSchool(spell)
    end
    if spell.item then
        -- No skill roll for enchanted items (vanilla lets anybody use one):
        -- the item's charge decides the roll. It covers the cost, so the cast
        -- always lands; it does not, so it cannot be cast at all.
        return canAffordItemCast(spell) and 100 or 0
    end
    -- costAlreadyPaid: this roll happens at the LAUNCH, long after
    -- handleCastCosts deducted the spell's magicka at animation start, so the
    -- pool no longer holds the cost. Without the flag the framework's helper
    -- re-checked affordability against the drained pool and demanded the cost
    -- a second time — a 5-cost spell with exactly 5 magicka paid its 5, rolled
    -- against a pool of 0, "failed" the cast and never landed (the doubled
    -- requirement in the field report). The cost still feeds the chance
    -- formula exactly as before; only the redundant pool gate is skipped, and
    -- it is skipped only here, where the cast has already been paid for.
    local chance, school = I.MagExp_Player.Helpers.getSpellCastChance(spell.id, caster, {
        ignoreFatigue = not (Cfg.general and Cfg.general:get('UseFatigue')),
        costAlreadyPaid = true,
    })
    local baseChance = chance
    -- 'skill_based': the penalty follows the cast skill (0 → 50%, 100+ → none);
    -- anything else is a flat percentage (or off). The framework helper above
    -- supplies the vanilla base roll (cost, lowest effect school, Sound,
    -- modified attributes, and live fatigue); OSSC only scales that result.
    local chanceMode = Cfg.general and Cfg.general:get('QuickCastChancePenalty')
    local chanceScale
    if Penalty.isSkillBased(chanceMode) then
        chanceScale = Penalty.skillScale(getMagicSkillValue(caster, school, false))
    else
        chanceScale = getPenaltyScale(chanceMode)
    end
    chance = math.max(0, math.min(100, util.round(chance*chanceScale)))
    debugLog(string.format('Cast chance: vanilla=%s%% OSSC scale=%.3f final=%s%%',
        tostring(baseChance), chanceScale, tostring(chance)))
    return chance, school
end

-- ── Magicka-based XP cost calc (ported from MBSP GameSpell formula) ──────────
local spellCostCache  = {}
local function calcSpellCost(spell)
    if not spell or not spell.id then return 0 end
    if spellCostCache[spell.id] then return spellCostCache[spell.id] end
    local effects = spell.effects
    if not effects or #effects == 0 then
        local cost = spell.cost or 0
        spellCostCache[spell.id] = cost
        return cost
    end
    local total = 0
    local isAutocalc = false
    local spellRec = spellRecs[spell.id]
    if spellRec then isAutocalc = spellRec.autocalcFlag or false end
    for _, eff in ipairs(effects) do
        local mgef = effectRecs[eff.id]
        if mgef then
            local hasMag = mgef.hasMagnitude
            local hasDur = mgef.hasDuration
            local appliedOnce = mgef.isAppliedOnce
            local minMag = math.max(1, hasMag and (eff.magnitudeMin or 1) or 1)
            local maxMag = math.max(1, hasMag and (eff.magnitudeMax or minMag) or 1)
            local dur    = hasDur and (eff.duration or 1) or 1
            if not appliedOnce then dur = math.max(1, dur) end
            local x = 0.5 * (minMag + maxMag)
            x = x * (0.1 * (mgef.baseCost or 1))
            x = x * dur
            x = x + (0.05 * (eff.area or 0) * (mgef.baseCost or 1))
            x = x * GMST.fEffectCostMult
            if eff.range == RANGE.Target then x = x * 1.5 end
            total = total + math.max(0, x)
        end
    end
    local cost
    if isAutocalc then
        cost = math.floor(total + 0.5)
    else
        cost = math.floor((spell.cost or total) + 0.5)
    end
    spellCostCache[spell.id] = cost
    return cost
end

-- ── MBSP Magicka Refund (cloned 1:1 from MBSP_p.lua) ──
-- Spells only, positive only, never in god mode.
local mbspSpellDB = {}
local function mbspCheckSpell(spell)
    local spellId = spell.id
    if not mbspSpellDB[spellId] then
        mbspSpellDB[spellId] = {}
        local s = mbspSpellDB[spellId]
        s.schools = {}
        s.calculatedCost = 0
        s.autoCalculated = spell.autocalcFlag
        if s.autoCalculated == nil then
            local spellRec = spellRecs[spellId]
            if spellRec then s.autoCalculated = spellRec.autocalcFlag or false end
        end
        s.isSpell = spell.type == SPELL_TYPE.Spell
        for _, effect in ipairs(spell.effects or {}) do
            local mgef = effect.effect or (effect.id and effectRecs[effect.id])
            if mgef then
                local school = mgef.school
                if type(school) == "number" then school = SCHOOL_STRS[school] end
                local hasMagnitude = mgef.hasMagnitude
                local hasDuration  = mgef.hasDuration
                local appliedOnce  = mgef.isAppliedOnce
                local minMagn = hasMagnitude and effect.magnitudeMin or 1
                local maxMagn = hasMagnitude and effect.magnitudeMax or 1
                minMagn = math.max(1, minMagn)
                maxMagn = math.max(1, maxMagn)
                local duration = hasDuration and effect.duration or 1
                if not appliedOnce then
                    duration = math.max(1, duration)
                end
                local x = 0.5 * (minMagn + maxMagn)
                x = x * (0.1 * (mgef.baseCost or 1))
                x = x * duration
                x = x + (0.05 * (effect.area or 0) * (mgef.baseCost or 1))
                x = x * GMST.fEffectCostMult
                if effect.range == RANGE.Target then
                    x = x * 1.5
                end
                x = math.max(0, x)
                s.schools[school] = (s.schools[school] or 0) + x
                s.calculatedCost = s.calculatedCost + x
            end
        end
        if s.autoCalculated then
            s.cost = math.floor(s.calculatedCost + 0.5)
        else
            s.cost = math.floor((spell.cost or s.calculatedCost) + 0.5)
        end
    end
    return mbspSpellDB[spellId]
end

local function mbspGetAverageSkill(spell, s)
    -- MBSP: willpower/5 + luck/10 + school skills weighted by cost share.
    local skill = types.NPC.stats.attributes['willpower'](self).modified / 5
                + types.NPC.stats.attributes['luck'](self).modified / 10
    for school, cost in pairs(s.schools) do
        local st = types.NPC.stats.skills[school](self)
        if st then
            skill = skill + st.modified * (cost / math.max(1, s.calculatedCost))
        end
    end
    return skill
end

local function mbspCalcRefund(spell, refundStart, refundMult, levelScaling)
    local s = mbspCheckSpell(spell)
    if not s.isSpell then return 0 end
    local cost = s.cost
    local skill = mbspGetAverageSkill(spell, s) - refundStart
    local effectiveSpellCost = refundMult ^ (skill / levelScaling)
    effectiveSpellCost = effectiveSpellCost * cost
    local refund = cost - effectiveSpellCost
    return refund
end

-- Defaults match MBSP: skill req 35, cost scaling 50 (percent), level scaling 100.
local function getMagickaRefundSettings()
    return {
        enabled      = Cfg.general and Cfg.general:get('MagickaRefund') == true,
        refundStart  = Cfg.general and Cfg.general:get('MagickaRefundStart') or 35,
        refundMult   = ((Cfg.general and Cfg.general:get('MagickaRefundMult')) or 50) / 100,
        levelScaling = Cfg.general and Cfg.general:get('MagickaRefundLevelScaling') or 100,
    }
end

-- Refund only when positive, never in god mode; no upper clamp (matches MBSP).
local function applyMagickaRefund(spell)
    local st = getMagickaRefundSettings()
    if not st.enabled then return end
    if debug.isGodMode() then return end
    local refund = mbspCalcRefund(spell, st.refundStart, st.refundMult, st.levelScaling)
    if refund > 0 then
        types.Actor.stats.dynamic.magicka(self).current =
            types.Actor.stats.dynamic.magicka(self).current + refund
        debugLog(string.format("MBSP refund: %.2f magicka returned", refund))
    end
end

local function enableCombatBlock()
    reconcileCombatBlock()
end

local function disableCombatBlock()
    if not Cast.combatBlockActive then return end
    setCombatBlock(false)
end

-- Payment happens in handleCastCosts (SFP consumeSpellCost when registered).
local function hasMagicka(cost)
    local magicka = types.Actor.stats.dynamic.magicka(self)
    return magicka.current >= (cost or 0)
end

-- Returns paid, failMsg (nil when the framework already showed one).
local function handleCastCosts(spell)
    if debug.isGodMode() then return true end

    -- ── Enchanted item: the item's charge pays, magicka is untouched ──────
    if spell.item then
        if canAffordItemCast(spell) then
            -- SFP deducts item charge at launch (isFree = false). enchantmentCharge is
            -- global-script-only: never deduct here or it is charged twice.
            return true
        end
        local ench = spell.enchantment or (spell.id and enchRecs[spell.id])
        if ench and ench.type == ENCHTYPE.CastOnce then
            debugLog("Item cast blocked — no scroll/item left: " .. tostring(spell.id))
            return false, "You have no more of these to use."
        end
        debugLog(string.format("Item cast blocked — charge %s < cost %s (%s)",
            tostring(getItemCharge(spell)), tostring(getEnchantmentCost(spell)), tostring(spell.id)))
        return false, GMST.sMagicInsufficientCharge
    end

    -- ── Spell: magicka pays, and fatigue follows when enabled ─────────────
    local magickaCost = spell.cost or 0
    if I.MagExp_Player and I.MagExp_Player.Helpers
        and I.MagExp_Player.Helpers.getModifiedSpellCost then
        local cost = I.MagExp_Player.Helpers.getModifiedSpellCost(self, spell.id, false)
        if tonumber(cost) then magickaCost = tonumber(cost) end
    end

    local canAfford, failMsg = true, nil
    if I.MagExp_Player and I.MagExp_Player.consumeSpellCost then
        -- SFP checks, deducts, and toasts itself.
        canAfford = I.MagExp_Player.consumeSpellCost(spell.id, nil)
        debugLog(string.format("Magicka cost %s (consumeSpellCost → %s)",
            tostring(magickaCost), tostring(canAfford)))
    else
        -- No SFP consumer: pay at animation start (vanilla timing);
        -- launch then goes out isFree = true to avoid a second charge.
        canAfford = hasMagicka(magickaCost)
        if canAfford then
            if magickaCost > 0 then
                local magicka = types.Actor.stats.dynamic.magicka(self)
                -- [MAGICKA TRACE] Deduction site 3 of 3; never fires in the same cast as SFP's.
                local before = magicka.current
                magicka.current = math.max(0, magicka.current - magickaCost)
                debugLog(string.format(
                    "[MAGICKA TRACE] cast=%s deduct %.2f via OSSC handleCastCosts (no framework consumer): %.2f -> %.2f",
                    tostring(Cast.currentCastId), magickaCost, before, magicka.current))
                debugLog(string.format("Magicka cost %s paid at animation start (no framework consumer)",
                    tostring(magickaCost)))
            end
        else
            debugLog(string.format("Cast blocked — magicka %s < cost %s (%s)",
                tostring(types.Actor.stats.dynamic.magicka(self).current),
                tostring(magickaCost), tostring(spell.id)))
            failMsg = GMST.sMagicInsufficientSP
        end
    end

    if canAfford and Cfg.general and Cfg.general:get('UseFatigue') then
        local fatigue = types.Actor.stats.dynamic.fatigue(self)
        if fatigue then
            -- MCP: fatigue = magickaCost * (fFatigueSpellBase + enc% * fFatigueSpellMult)
            -- Both 0 (vanilla): default to 0.5x..1x magickaCost by encumbrance.
            local fBase = GMST.fFatigueSpellBase
            local fMult = GMST.fFatigueSpellMult
            if not (fBase > 0 or fMult > 0) then
                fBase, fMult = 0.5, 0.5
            end
            local enc = 0
            local encumbrance = types.Actor.getEncumbrance(self)
            local capacity = types.Actor.getCapacity(self)
            if type(encumbrance) == 'number' and type(capacity) == 'number' and capacity > 0 then
                enc = math.max(0, math.min(1, encumbrance / capacity))
            end
            local fatigueScale = Cfg.general and (Cfg.general:get('UseFatigueScale') or Cfg.general:get('FatigueScale'))
            if type(fatigueScale) ~= 'number' then
                fatigueScale = 1.0
            end
            local fatigueCost = (magickaCost or 0) * (fBase + enc * fMult) * math.max(0, fatigueScale)
            if fatigueCost > 0 then
                fatigue.current = math.max(0, fatigue.current - fatigueCost)
                debugLog(string.format("Fatigue cost %.2f paid (encumbrance %.0f%%, scale %.2f)",
                    fatigueCost, enc * 100, fatigueScale))
            end
        end
    end
    return canAfford, failMsg
end

-- ── VFX ───────────────────────────────────────────────────────────────────
local function add_cast_static_vfx(bone, vfx_id)
    local spell = Cast.currentSpell
    if not spell or not spell.effects then return end
    local spawnedModels = {}
    local isContinuous = spell.continuousVfx or false
    for i, eff in ipairs(spell.effects) do
        local mgef = effectRecs[eff.id]
        if mgef then
            local castStaticId = mgef.castStatic
            local static = castStaticId and staticRecs[castStaticId]
            if static and static.model and static.model ~= "" and not spawnedModels[static.model] then
                spawnedModels[static.model] = true
                local opts = { loop=isContinuous, vfxId=vfx_id .. "_" .. tostring(i) }
                if bone and bone ~= "" then opts.boneName = bone end
                anim.addVfx(self, static.model, opts)
            end
        end
    end
end

local function add_particle_swirl_vfx(bone, vfx_id)
    local spell = Cast.currentSpell
    if not spell or not spell.effects then return end
    local spawnedTextures = {}
    local isContinuous = spell.continuousVfx or false
    for i, eff in ipairs(spell.effects) do
        local mgef = effectRecs[eff.id]
        -- An effect whose cast static is a real record with no model has
        -- declared "no cast mesh" (drawn another way, e.g. by BeamFX):
        -- the hand swirl substitutes for a *missing* cast visual, and
        -- this one is missing on purpose, so do not substitute.
        local castStatic = mgef and mgef.castStatic and staticRecs[mgef.castStatic]
        local castSuppressed = castStatic ~= nil
            and (castStatic.model == nil or castStatic.model == "")
        if mgef and not castSuppressed then
            local texture = "vfx_starglow.tga"
            if mgef.particle and mgef.particle ~= "" and not mgef.particle:find("blank") then
                texture = mgef.particle
            end
            if not spawnedTextures[texture] then
                spawnedTextures[texture] = true
                local opts = { loop=isContinuous, vfxId=vfx_id .. "_" .. tostring(i), particleTextureOverride=texture }
                if bone and bone ~= "" then opts.boneName = bone end
                anim.addVfx(self, "meshes/magichand/spellvfx.nif", opts)
            end
        end
    end
end

local function add_hand_glow_vfx()
    local spell = Cast.currentSpell
    if not (spell and spell.effects and spell.effects[1]) then return end
    local mgef = effectRecs[spell.effects[1].id]
    if not mgef then return end
    local castGlowOn = Cfg.keys and Cfg.keys:get('EnableCastGlow')
    if not castGlowOn then return end
    local castStaticId = mgef.castStatic
    local static = castStaticId and staticRecs[castStaticId]
    if static and static.model and static.model ~= "" then
        local isContinuous = spell.continuousVfx or false
        anim.addVfx(self, static.model,
            { loop=isContinuous, vfxId="OSSC_HandGlow", boneName="Bip01 L Hand" })
    end
end

local function add_spell_vfx()
    if Cfg.keys and Cfg.keys:get('EnablePlayerSwirls') then add_cast_static_vfx(nil, "OSSC_PlayerSwirl") end
    if Cfg.keys and Cfg.keys:get('EnableHandSwirls') then add_particle_swirl_vfx("Bip01 L Hand", "OSSC_HandSwirl") end
    Cast.spellvfx = true
end

local function stop_all_vfx()
    for i = 1, 10 do
        anim.removeVfx(self, "OSSC_PlayerSwirl_" .. tostring(i))
        anim.removeVfx(self, "OSSC_HandSwirl_" .. tostring(i))
    end
    anim.removeVfx(self, "OSSC_HandGlow")
    Cast.spellvfx     = false
    Cast.isGlowActive = false
end

-- ── Cleanup phases ────────────────────────────────────────────────────────
local function launchCleanup(reason)
    debugLog("LaunchCleanup: " .. (reason or ""))
    stop_all_vfx()
    Cast.currentSpell    = nil
    Cast.hasQueuedLaunch = false
    -- Drop only THIS cast's launches; an earlier paid, released launch may still be queued.
    for i = #Cast.pendingLaunches, 1, -1 do
        if Cast.pendingLaunches[i].castId == Cast.currentCastId then
            table.remove(Cast.pendingLaunches, i)
        end
    end
end

-- ── The quickkey window (helpers on Stance, for the upvalue limit) ──
-- A press and the cast it starts are one window; the engine re-raises Spell during it.
-- Cast.isCasting check ignores a stale postCastRestore (e.g. after load).
function Stance.quickkeyWindowActive()
    return QuickkeyPress.slot ~= nil
        or (Cast.isCasting and Stance.postCastRestore ~= nil)
        or Stance.nativeQuickkeySuppression
end

-- Stop engine equip/unequip sounds on Weapon<->Spell flips when SuppressSpellStance is on.
function Stance.suppressWeaponTransitionSounds()
    -- Local list: onUpdate/triggerQuickCast are at the 60-upvalue limit.
    local sounds = {
        "item weapon blunt up",
        "item weapon blunt down",
        "item weapon bow up",
        "item weapon bow down",
        "item weapon crossbow up",
        "item weapon crossbow down",
        "item weapon longblade up",
        "item weapon longblade down",
        "item weapon shortblade up",
        "item weapon shortblade down",
        "item weapon spear up",
        "item weapon spear down",
        "item armor heavy up",
        "item armor heavy down",
        "item armor light up",
        "item armor light down",
        "item armor medium up",
        "item armor medium down",
        "item ammo up",
        "item ammo down",
        -- Title Case variants as they appear in the CS / ESM
        "Item Weapon Blunt Up",
        "Item Weapon Blunt Down",
        "Item Weapon Bow Up",
        "Item Weapon Bow Down",
        "Item Weapon Crossbow Up",
        "Item Weapon Crossbow Down",
        "Item Weapon LongBlade Up",
        "Item Weapon LongBlade Down",
        "Item Weapon ShortBlade Up",
        "Item Weapon ShortBlade Down",
        "Item Weapon Spear Up",
        "Item Weapon Spear Down",
        "Item Weapon Longblade Up",
        "Item Weapon Longblade Down",
        "Item Weapon Shortblade Up",
        "Item Weapon Shortblade Down",
        "Item Armor Heavy Up",
        "Item Armor Heavy Down",
        "Item Armor Light Up",
        "Item Armor Light Down",
        "Item Armor Medium Up",
        "Item Armor Medium Down",
        "Item Ammo Up",
        "Item Ammo Down",
    }
    for _, sid in ipairs(sounds) do
        -- No pcall: stopping a sound that is not playing is a documented no-op
        -- in the engine, so wrapping this only served to hide a broken binding.
        core.sound.stopSound3d(sid, self)
    end
end

-- Bounded window owning Spell re-raises until the native transition and cast finish.
-- Kept out of QuickkeyPress, which is cleared before the cast animation begins.
local QUICKKEY_STANCE_SUPPRESSION_GRACE = 0.75

--- The window exists to put a quickkey-raised stance back DOWN so the cast can
--- start from a clean non-Spell posture. With Allow Quick-Cast In Spell Stance
--- on there is nothing to put down — the stance is where the cast starts — so
--- no window is armed and the raise survives to the cast.
local function allowCastInSpellStance()
    return Cfg.general and Cfg.general:get('AllowQuickCastInSpellStance') == true
end

local function activateQuickkeyStanceSuppression()
    if allowCastInSpellStance() then return end
    if not (Cfg.general and Cfg.general:get('SuppressSpellStance') == true) then return end
    Stance.nativeQuickkeySuppression      = true
    Stance.nativeQuickkeySuppressionUntil = core.getSimulationTime() + QUICKKEY_STANCE_SUPPRESSION_GRACE
    Stance.nativeQuickkeyRestoreTarget    = QuickkeyPress.prePressStance
        or Stance.lastNonSpellStance
        or STANCE.Nothing
    if Stance.nativeQuickkeyRestoreTarget == STANCE.Spell then
        Stance.nativeQuickkeyRestoreTarget = STANCE.Nothing
    end
    -- Use the previous-frame weapon: post-press equipment may already be changed.
    Stance.nativeQuickkeyWeapon = Stance.prevFrameWeapon
    -- Engine already started the sheathe and down sound before Lua runs.
    Stance.suppressWeaponTransitionSounds()
end

local function clearQuickkeyStanceSuppression()
    Stance.nativeQuickkeySuppression      = false
    -- A captured press stance never survives a load or a cleared window: it
    -- must describe the press that is being judged right now, nothing older.
    Stance.quickkeyCastStance             = nil
    Stance.nativeQuickkeySuppressionUntil = 0
    Stance.nativeQuickkeyRestoreTarget    = nil
    Stance.nativeQuickkeyWeapon           = nil
    Stance.transitionCancelDone           = false
    Stance.collapsedDrawGroup             = nil
end

--- Hand the engine's Spell stance to a quick-cast that is starting from it.
--- Only reachable with Allow Quick-Cast In Spell Stance on: the stance is the
--- engine's own posture, and the stance-suppression machinery would otherwise
--- put it back down under the cast the player just asked for (the quickkey
--- window reverts a raise, the update mirror repeats the revert, and the cast
--- ends up owning the arms while the stance underneath it is being swapped).
--- Releasing here means: this stance is the cast's, not the suppression
--- window's. `Stance.spellStanceAllowed` is deliberately NOT set — that flag
--- means "the user opened the stance by hand", and the next weapon key or
--- stance change still ends the window normally.
function Stance.releaseSpellStanceForCast()
    Stance.nativeQuickkeySuppression = false
    Stance.nativeQuickkeySuppressionUntil = 0
    Stance.transitionCancelDone = false
end

-- Groups playing before the press are real attacks; new ones are the quickkey sheathe.
function Stance.noteCombatAnimsAtPress()
    local copy = {}
    if Stance.prevCombatAnims then
        for groupName, playing in pairs(Stance.prevCombatAnims) do
            if playing then copy[groupName] = true end
        end
    end
    Cast.combatAnimsAtPress = copy
end

-- One-shot; consumed at triggerQuickCast's top even on refusal.
function Stance.beginQuickkeyCastAttempt()
    Cast.exemptWeaponTransitionBlock = true
    -- The native quickkey has already run, so a live read now may see the
    -- engine's own transient Spell raise. The end-of-previous-frame baseline is
    -- the stance the player actually pressed the key in.
    Stance.quickkeyCastStance = Stance.prevFrameStance
end

-- Weapon re-attaches only from a draw play: start at 'equip attach' and finish
-- the tail before render. Missing/late key: leave it to the engine fallback.
function Stance.collapseEquipPlay(groupname, options)
    local attachTime, stopTime
    if anim.getTextKeyTime then
        -- No pcall: `getTextKeyTime` reports a missing key as nil (an absent
        -- optional), so a raise here means the object has no animation system
        -- at all — an engine error worth seeing, not a "draw play without keys"
        -- case to swallow.
        local attach = anim.getTextKeyTime(self, groupname .. ': equip attach')
        local stop   = anim.getTextKeyTime(self, groupname .. ': equip stop')
        if type(attach) == 'number' then attachTime = attach end
        if type(stop) == 'number' then stopTime = stop end
    end
    if type(attachTime) == 'number' and attachTime >= 0
        and type(stopTime) == 'number' and attachTime < stopTime then
        options.startKey = 'equip attach'
        options.startkey = 'equip attach'
    end
    options.speed = 1000
    Stance.collapsedDrawGroup = groupname
    debugLog("[OSSC Stance] Collapsed native weapon draw (no re-equip): " .. groupname)
    -- The draw play triggers the up sound (Item Weapon ... Up). Silence it.
    Stance.suppressWeaponTransitionSounds()
end

-- Cancel the press-frame sheathe once, before 'unequip detach'; pre-existing groups untouched.
function Stance.cancelFreshWeaponTransition()
    if not Stance.nativeQuickkeySuppression or Stance.spellStanceAllowed then return end
    if Stance.transitionCancelDone then return end
    Stance.transitionCancelDone = true
    if isAttackUseHeld() then return end
    local baseline = Cast.combatAnimsAtPress
    local function stray(group)
        if group == Stance.collapsedDrawGroup then return end
        if not anim.isPlaying(self, group) then return end
        if baseline and baseline[group] then return end
        anim.cancel(self, group)
        debugLog("[OSSC Stance] Cancelled quickkey weapon transition: " .. group)
    end
    for _, g in ipairs(Anim.LIGHT_ATTACK_GROUPS) do stray(g) end
    for _, g in ipairs(Anim.HEAVY_ATTACK_GROUPS) do stray(g) end
    stray('shield')
    -- Also silence any down/up sound that the cancelled play already started.
    Stance.suppressWeaponTransitionSounds()
end

-- Restore only an empty right-hand slot; never overwrite a newer weapon.
local function restoreQuickkeyWeaponIfEmpty()
    local wanted = Stance.nativeQuickkeyWeapon
    if not wanted or not wanted.isValid or not wanted:isValid() then return end
    local equipment = types.Actor.getEquipment(self)
    if not equipment or equipment[SLOT.CarriedRight] ~= nil then return end
    equipment[SLOT.CarriedRight] = wanted
    types.Actor.setEquipment(self, equipment)
end

-- In-flight quickkey cast's recorded pre-press stance wins: the prev-frame
-- baseline may already contain the engine's late Spell raise.
function Stance.quickkeyRevertTarget()
    local target = Stance.postCastRestore
        or QuickkeyPress.prePressStance
        or Stance.nativeQuickkeyRestoreTarget
        or Stance.lastNonSpellStance
        or STANCE.Nothing
    if target == STANCE.Spell then target = STANCE.Nothing end
    return target
end

-- Restore the pre-press stance after a quickkey cast.
-- Only with SuppressSpellStance on, and only against the engine's Spell raise.
local function restoreStanceAfterCast(reason)
    local target = Stance.postCastRestore
    Stance.postCastRestore = nil
    if target == nil then return end
    if Stance.spellStanceAllowed then return end
    if not (Cfg.general and Cfg.general:get('SuppressSpellStance') == true) then
        clearQuickkeyStanceSuppression()
        return
    end
    -- Mirror may have already lowered the stance; weapon restore still needed.
    if types.Actor.getStance(self) ~= STANCE.Spell then
        restoreQuickkeyWeaponIfEmpty()
        return
    end
    if target == STANCE.Spell then target = STANCE.Nothing end
    debugLog("[OSSC Stance] Restoring post-cast stance (" .. tostring(reason or "") .. ")")
    types.Actor.setStance(self, target)
    Stance.suppressWeaponTransitionSounds()
    -- Put the original weapon back only if the slot is empty.
    restoreQuickkeyWeaponIfEmpty()
    -- Keep the pre-toggle intent reference exact for the next frame.
    Stance.prevStance = target
end

-- ReAnimation can leave the bow's mesh detached when its bow animation is
-- interrupted by an OSSC cast. Reassert the *same* right-hand bow at cast end
-- so OpenMW rebuilds the weapon attachment. This is deliberately limited to a
-- still-equipped bow: it never restores a weapon the player changed mid-cast.
local function refreshBowEquipmentAfterCast()
    if getExcludedWeaponGroup() ~= 'bowandarrow' then return end
    local equipment = types.Actor.getEquipment(self)
    local bow = equipment and equipment[SLOT.CarriedRight]
    if not bow or not bow.isValid or not bow:isValid() then return end
    equipment[SLOT.CarriedRight] = nil
    types.Actor.setEquipment(self, equipment)
    equipment[SLOT.CarriedRight] = bow
    types.Actor.setEquipment(self, equipment)
    debugLog('Reasserted equipped bow after quick-cast to restore its mesh attachment')
end

local function animUnlock(reason)
    if not Cast.isCasting then return end
    debugLog("AnimUnlock: " .. (reason or ""))
    -- Quick-slot throttle releases on the stop key, not a timer.
    QuickkeyPress.cooldownActive = false
    if Cast.ngardeParryControlActive then setNgardeParryControl(false) end
    Cast.isCasting           = false
    Cast.currentAnimGroup    = nil
    Cast.isBound2HWeaponCast = false
    restoreShieldAfterCast()
    disableCombatBlock()
    restoreStanceAfterCast(reason)
    refreshBowEquipmentAfterCast()
    self:sendEvent('OSSC_CastingState', { isCasting = Cast.isCasting })
end

local function fullCleanup(reason)
    debugLog("FullCleanup: " .. (reason or ""))
    PMM.isWaitingForPMMInput   = false
    PMM.pmmSelectedDestination = nil
    PMM.pmmVanillaRecall       = false
    PMM.pmmCancelled           = false
    PMM.pmmUiClosedAt          = nil
    PMM.pmmUiOpenedAt          = nil
    PMM.pmmDeferredRecall      = false
    PMM.isCurrentCastMark      = false
    PMM.isCurrentCastRecall    = false
    destroyPMMWindow()
    launchCleanup(reason)
    animUnlock(reason)
end

-- Resolve a deferred PMM recall to the picked mark. Idempotent.
resolvePMMRecall = function(reason)
    if not Cast.hasFiredThisCast then
        Cast.hasFiredThisCast = true
        if Cast.currentSpell then
            table.insert(Cast.pendingLaunches, {
                spell      = Cast.currentSpell,
                castId     = Cast.currentCastId,
                animGroup  = Cast.currentAnimGroup,
                isPaid     = Cast.currentIsPaid,
                timeToFire = core.getSimulationTime()
            })
            debugLog('[OSSC PMM] Deferred recall launch queued (' .. tostring(reason) .. ')')
        end
    end
    PMM.pmmDeferredRecall = false
    animUnlock(reason)
end

-- ── Eternal Grimoire helpers ──
local function hasEternalGrimoire()
    local equipment = types.Actor.equipment(self)
    if not equipment then return false end
    local item = equipment[SLOT.CarriedLeft]
    if not item or not item:isValid() then return false end
    local rid = item.recordId
    return rid ~= nil and rid:lower() == "eternal_grimoire"
end

-- Returns true when the player is currently in Spell stance.
local function isInSpellStance()
    return types.Actor.getStance(self) == STANCE.Spell
end

-- Combined gate used by both the idle loop and the cast override.
local function grimoireConditionMet()
    return hasEternalGrimoire() and not isInSpellStance()
end

-- Default priority so Scripted casts override without cancelling the loop.
local function startGrimoireIdle()
    if Stance.isGrimoireIdlePlaying then return end
    Stance.isGrimoireIdlePlaying = true
    debugLog("Grimoire idle: starting egidle2 loop")
    if I.AnimationController and I.AnimationController.playBlendedAnimation then
        I.AnimationController.playBlendedAnimation('egidle2', {
            priority  = {
                [BONE.LeftArm]   = PRIO.Default,
                [BONE.Torso]     = PRIO.Default,
                [BONE.RightArm]  = PRIO.Default,
                [BONE.LowerBody] = PRIO.Default,
            },
            startKey  = 'loop start',
            stopKey   = 'loop stop',
            blendMask = BMASK.LeftArm  + BMASK.Torso +
                        BMASK.RightArm + BMASK.LowerBody,
            speed     = 1.0,
        })
    end
end

-- Immediately cancels the egidle2 loop.
local function stopGrimoireIdle()
    if not Stance.isGrimoireIdlePlaying then return end
    Stance.isGrimoireIdlePlaying = false
    debugLog("Grimoire idle: stopping egidle2 loop")
    anim.cancel(self, 'egidle2')
end

-- ── END NEW ────────────────────────────────────────────────────────────────

-- ── Helper: Resolve item record & enchantment data ────────────────────────
local function getItemRecord(item)
    if not item or not item:isValid() then return nil end
    if types.Item and types.Item.record then
        return types.Item.record(item)
    end
    local t = item.type
    if t == types.Weapon       then return types.Weapon.record(item)
    elseif t == types.Armor    then return types.Armor.record(item)
    elseif t == types.Clothing then return types.Clothing.record(item)
    elseif t == types.Book     then return types.Book.record(item)
    elseif t == types.MiscItem then return types.MiscItem.record(item)
    elseif t == types.Potion   then return types.Potion.record(item)
    end
    return nil
end

local function resolveEnchantedItemSpell(item)
    if not item or not item:isValid() then return nil end
    local rec = getItemRecord(item)
    if rec and rec.enchant and rec.enchant ~= "" then
        local enchRec = enchRecs[rec.enchant]
        if enchRec then
            return {
                id          = rec.enchant,
                item        = item,
                enchantment = enchRec,
                effects     = enchRec.effects or {},
                cost        = enchRec.cost or 1,
                type        = enchRec.type
            }
        end
    end
    return nil
end

-- ── Swimming gate for target-range quick-casts ──
-- types.Actor.isSwimming: whole body in water (wading does not count).
local function isSwimmingActor(actor)
    return types.Actor.isSwimming(actor)
end

local function hasTargetRangeEffect(spell)
    if not spell or not spell.effects then return false end
    for _, eff in ipairs(spell.effects) do
        if eff.range == RANGE.Target then
            return true
        end
    end
    return false
end

-- ── Shared cast startup function ──────────────────────────────────────────
local function triggerQuickCast(opts)
    -- Read before any early return so a refused cast cannot leave it set.
    local exemptWeaponTransition = Cast.exemptWeaponTransitionBlock == true
    local transitionBaseline = Cast.combatAnimsAtPress
    Cast.exemptWeaponTransitionBlock = false
    -- The stance a quickkey press started from, captured before the native
    -- quickkey raised its transient Spell stance (see
    -- Stance.beginQuickkeyCastAttempt).
    local pressStance = Stance.quickkeyCastStance
    Stance.quickkeyCastStance = nil
    local ignoreUIMode = opts and opts.ignoreUIMode
    local ignoreWorldPause = opts and opts.ignoreWorldPause
    local uiMode = (ui and ui.activeMode)
    if not uiMode and I.UI and I.UI.getMode then uiMode = I.UI.getMode() end
    if (uiMode ~= nil and not ignoreUIMode) or (core.isWorldPaused() and not ignoreWorldPause) or Cast.isCasting then
        if Cast.isCasting then
            debugLog("Input rejected — cast in progress (currentAnimGroup=" ..
                tostring(Cast.currentAnimGroup) .. ")")
        else
            self:sendEvent('OSSC_CastingState', { isCasting = false })
        end
        return
    end
    -- ── No quick-cast from Spell stance ──
    -- The engine's Spell stance is its own cast, and OSSC's blended quick-cast
    -- animation on top of it made the two gestures fight for the same arms.
    -- Nothing starts here: no animation, no cost, no launch. The player leaves
    -- Spell stance (or OSSC's own quickkey window puts the stance back down)
    -- and the next quick-cast works as usual. A quickkey press is judged by the
    -- stance the player stood in BEFORE the native quickkey ran, because the
    -- engine raises Spell stance itself as part of that press.
    local castStance = pressStance or types.Actor.getStance(self)
    -- Allow Quick-Cast In Spell Stance (off by default): with it on, a cast
    -- that starts from the engine's Spell stance takes the stance over instead
    -- of being refused (see Stance.releaseSpellStanceForCast).
    local castInSpellStance = allowCastInSpellStance()
    if castInSpellStance and castRulesModule.blocksForSpellStance(castStance) then
        Stance.releaseSpellStanceForCast()
        debugLog("Cast allowed — Spell stance quick-cast enabled")
    end
    if not castRulesModule.quickcastStanceAllowed(castStance, castInSpellStance) then
        debugLog("Cast blocked — Spell stance: leave spell stance to quick-cast")
        self:sendEvent('OSSC_CastingState', { isCasting = false })
        return
    end
    -- Vanilla does not allow a cast while player magic is disabled or while
    -- the player is in werewolf form.
    if not types.Player.getControlSwitch(self, types.Player.CONTROL_SWITCH.Magic)
        or types.NPC.isWerewolf(self) then
        debugLog("Cast blocked — magic disabled or werewolf")
        self:sendEvent('OSSC_CastingState', { isCasting = false })
        return
    end
    if isParalyzedOrSilenced(self) then
        debugLog("Cast blocked — paralyzed or silenced")
        self:sendEvent('OSSC_CastingState', { isCasting = false })
        return
    end

    if Cfg.general and Cfg.general:get('BlockDuringAttack') then
        if self.controls and self.controls.use and self.controls.use ~= 0 then
            debugLog("Cast blocked — actor is actively attacking/raising weapon (Spellstrike compat)")
            self:sendEvent('OSSC_CastingState', { isCasting = false })
            return
        end
    end

    if Cfg.general and Cfg.general:get('BlockDuringCombatAnims') then
        for _, groupName in ipairs(Anim.COMBAT_ANIM_GROUPS) do
            -- Any playing combat animation blocks quick-casting. A bow/crossbow
            -- shot blocks for its WHOLE duration — draw/aim and the
            -- follow-through after the projectile is away — so a quick 1-tap
            -- can no longer cast mid-shot the way it could when the
            -- follow-through was exempted (it used to leave a gap that held
            -- attacks covered but 1-taps did not).
            --
            -- A magic quick-key is the exception, and only for the sheathe the
            -- engine itself just started. That play is weapontwohand / bow /
            -- crossbow — the same groups this setting guards — so with the
            -- setting on (the default) a 2H quick-key never cast at all, while
            -- a 1H one did (weapononehand is not in the list). A group that
            -- was already playing before the press is a real attack and still
            -- blocks, and a held attack charge still blocks below.
            if anim.isPlaying(self, groupName) then
                local causedByQuickkey = exemptWeaponTransition
                    and not isAttackUseHeld()
                    and not (transitionBaseline and transitionBaseline[groupName])
                if not causedByQuickkey then
                    debugLog("Cast blocked — combat animation playing: " .. groupName)
                    self:sendEvent('OSSC_CastingState', { isCasting = false })
                    return
                end
                debugLog("Cast allowed through quickkey weapon transition: " .. groupName)
            end
        end
        -- Held charge parks on a text key, so isPlaying() misses it.
        local heldGroup = isAttackUseHeld() and getExcludedWeaponGroup() or nil
        if heldGroup then
            debugLog("Cast blocked — holding attack charge with excluded weapon: " .. heldGroup)
            self:sendEvent('OSSC_CastingState', { isCasting = false })
            return
        end
    end

    -- NGarde parry block; no-op when NGarde is absent.
    if Cfg.general and Cfg.general:get('BlockDuringNGardeParry') then
        local parrying = false
        if I.NGardePlayer then
            if type(I.NGardePlayer.isParrying) == 'function' and I.NGardePlayer.isParrying() then
                parrying = true
            end
            if not parrying and type(I.NGardePlayer.startedParry) == 'function' and I.NGardePlayer.startedParry() then
                parrying = true
            end
        end
        if parrying then
            debugLog("Cast blocked — NGarde parry is active")
            self:sendEvent('OSSC_CastingState', { isCasting = false })
            return
        end
    end

    local function abortCast(msg)
        self:sendEvent('OSSC_CastingState', { isCasting = false })
        fullCleanup(msg or "aborted")
    end

    for _, groupName in ipairs(Anim.INCAPACITATED_GROUPS) do
        if anim.isPlaying(self, groupName) then return abortCast("incapacitated") end
    end

    -- ── Resolve spell / enchanted item ────────────────────────────────────
    local activeSpell = nil
    local selectedItem = opts and opts.item
    local activeSpellResult = opts and opts.spell

    if opts and opts.strictOnlySpell and not activeSpellResult and not selectedItem then
        return abortCast("strict hotkey — no bound spell provided")
    end

    -- 1. If an explicit item was passed in opts
    if selectedItem and selectedItem:isValid() and not activeSpellResult then
        activeSpell = resolveEnchantedItemSpell(selectedItem)
    end

    -- 2. If nothing resolved yet, check active selected spell OR active selected enchanted item from actor
    if not activeSpell and not activeSpellResult then
        activeSpellResult = types.Actor.getSelectedSpell(self)
        if not activeSpellResult and core.magic.getSelectedSpell then
            activeSpellResult = core.magic.getSelectedSpell()
        end
        if not activeSpellResult and types.Player.getSelectedSpell then
            activeSpellResult = types.Player.getSelectedSpell(self)
        end

        -- If no spell selected, check if an enchanted item or scroll is selected!
        if not activeSpellResult then
            local enchItem = types.Actor.getSelectedEnchantedItem(self)
            if not enchItem and types.Player.getSelectedEnchantedItem then
                enchItem = types.Player.getSelectedEnchantedItem(self)
            end
            if enchItem and enchItem:isValid() then
                activeSpell = resolveEnchantedItemSpell(enchItem)
            end
        end
    end

    -- 3. If activeSpellResult was passed (e.g. from hotkey or string or userdata object)
    if not activeSpell and activeSpellResult and activeSpellResult ~= "" then
        if type(activeSpellResult) == "table" then
            activeSpell = activeSpellResult
        elseif type(activeSpellResult) == "userdata" then
            local isObject = activeSpellResult.recordId ~= nil
            if isObject then
                activeSpell = resolveEnchantedItemSpell(activeSpellResult)
            else
                activeSpell = {
                    id      = activeSpellResult.id,
                    effects = activeSpellResult.effects,
                    cost    = I.MagExp_Player and I.MagExp_Player.Helpers and I.MagExp_Player.Helpers.getModifiedSpellCost(self, activeSpellResult.id, false)
                              or activeSpellResult.cost or 0,
                    type    = activeSpellResult.type
                }
            end
        else
            -- String ID passed: check spell records first, then enchantment records
            local sRec = spellRecs[activeSpellResult]
            if sRec then
                -- ── Copy effects/cost/type so school+range animation lookup works ──
                activeSpell = {
                    id      = activeSpellResult,
                    effects = sRec.effects,
                    cost    = sRec.cost,
                    type    = sRec.type,
                }
            else
                local eRec = enchRecs[activeSpellResult]
                if eRec then
                    activeSpell = {
                        id          = activeSpellResult,
                        enchantment = eRec,
                        effects     = eRec.effects or {},
                        cost        = eRec.cost or 1,
                        type        = eRec.type
                    }
                else
                    activeSpell = { id = activeSpellResult }
                end
            end
        end
    end

    if not (activeSpell and activeSpell.id) then return abortCast("nothing selected") end
    local spellId  = activeSpell.id
    local spellRec = spellRecs[spellId]
    if not spellRec and activeSpell.enchantment then spellRec = activeSpell.enchantment end
    if not spellRec then
        spellRec = enchRecs[spellId]
        if spellRec then activeSpell.enchantment = spellRec end
    end
    if not spellRec then return abortCast("no spell record") end

    -- ── Mod cast veto ──────────────────────────────────────────────────────
    -- Another mod's own rule about what may be cast (Sane Magic's skill caps,
    -- a school restriction, a charge check…). Asked here, before anything is
    -- played or paid, and it covers spells, scrolls and enchanted items
    -- alike — the vanilla `Use` path a mod like that gates on never runs for a
    -- quick-cast, which is exactly why scrolls used to leak through. Only an
    -- explicit `false` refuses; the reason is logged and the handler's message
    -- (if any) is shown. See ossc_cast_rules.lua for the payload.
    if castRulesModule.hasCastVeto() then
        local payload = castRulesModule.castPayload(activeSpell, {
            source = opts and opts.castSource or 'hotkey',
            caster = self,
            charge = activeSpell.item and getEnchantmentCost(activeSpell) or nil,
        })
        local vetoAllowed, vetoReason, vetoMessage =
            castRulesModule.checkCastVeto(payload)
        if not vetoAllowed then
            return castRulesModule.reportVetoedCast(self, payload, vetoReason,
                vetoMessage, {
                    log         = debugLog,
                    showMessage = ui.showMessage,
                    fizzle      = Cfg.general
                        and Cfg.general:get('CastVetoFeedback') ~= 'Silent',
                })
        end
    end

    -- Swimming target-range casts fizzle at release (pending-launch executor), not here.

    if spellRec.type == SPELL_TYPE.Power then
        if not (Cfg.general and Cfg.general:get('AllowPowerCasting')) then
            ui.showMessage("You need bigger focus to cast powers. Use spell stance.")
            return abortCast("power blocked")
        end
        local readyTime = OSSC_PowerCooldowns[spellId]
        local actorSpellList = types.Actor.spells(self)
        local engineCanUsePower = not (actorSpellList
            and type(actorSpellList.canUsePower) == 'function')
            or actorSpellList:canUsePower(spellId)
        if (readyTime and core.getGameTime() < readyTime) or not engineCanUsePower then
            ui.showMessage(GMST.sPowerAlreadyUsed)
            return abortCast("power on cooldown")
        end
    end

    Cast.currentSpell = activeSpell
    PMM.isCurrentCastMark      = false
    PMM.isCurrentCastRecall    = false
    PMM.isWaitingForPMMInput   = false
    PMM.pmmSelectedDestination = nil
    PMM.pmmVanillaRecall       = false
    PMM.pmmCancelled           = false
    PMM.pmmUiClosedAt          = nil
    PMM.pmmUiOpenedAt          = nil
    PMM.pmmDeferredRecall      = false
    if isPMMCompatEnabled() and isPMMInstalled() then
        PMM.isCurrentCastMark, PMM.isCurrentCastRecall = checkMarkRecall(Cast.currentSpell)
        if PMM.isCurrentCastRecall and #PMM.pmmLocations > 1 then
            -- After-cast window: open the mark window on the 'stop' key.
            PMM.pmmDeferredRecall = true
            debugLog('[OSSC PMM] Recall cast — multi mark window will open after the cast')
        end
    end
    print("[OSSC] Casting: "..tostring(spellId))
    core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = self })

    -- ── Choose animation group ─────────────────────────────────────────────
    local range = RANGE.Target
    if activeSpell.effects and activeSpell.effects[1] then
        range = activeSpell.effects[1].range or RANGE.Target
    end
    local schoolStr = "destruction"
    if activeSpell.effects and activeSpell.effects[1] then
        local mgef = effectRecs[activeSpell.effects[1].id]
        if mgef and mgef.school then
            schoolStr = (type(mgef.school)=="string") and mgef.school:lower()
                or SCHOOL_STRS[mgef.school] or "destruction"
        end
    end
    if activeSpell.item then
        schoolStr = getDominantSkillSchool(activeSpell) or "destruction"
    end

    local camMode     = camera.getMode()
    local perspSuffix = (camMode == camera.MODE.FirstPerson) and '1st' or '3rd'
    local rangeStr = 'Target'
    if range == RANGE.Self  then rangeStr = 'Self'
    elseif range == RANGE.Touch then rangeStr = 'Touch' end
    local schoolKey     = schoolStr:sub(1,1):upper() .. schoolStr:sub(2)
    local animLookupKey = 'Anim_' .. schoolKey .. '_' .. rangeStr .. '_' .. perspSuffix
    local animGroup     = Cfg.anim and Cfg.anim:get(animLookupKey) or 'quickcast'
    debugLog("AnimGroup resolved: key=" .. animLookupKey .. " → " .. animGroup)

    -- ── CHANGED — grimoire cast override ──────────────────────────────────
    if grimoireConditionMet() then
        animGroup = 'eqcastr'
        debugLog("Grimoire equipped, not in spell stance — overriding animGroup with 'eqcastr'")
    end
    -- ── END CHANGED ────────────────────────────────────────────────────────

    local groupSpeedKey = {
        ['quickcast'] = 'AnimSpeed_Quickcast',
        ['quickbuff'] = 'AnimSpeed_Quickbuff',
        ['qcconj']    = 'AnimSpeed_Qcconj',
        ['qctouch']   = 'AnimSpeed_Qctouch',
        ['qcalt']     = 'AnimSpeed_Qcalt',
        ['qcalts']    = 'AnimSpeed_Qcalts',
        ['qcill']     = 'AnimSpeed_Qcill',
        ['qcsnap']    = 'AnimSpeed_Qcsnap',
        ['qcdrain']   = 'AnimSpeed_Qcdrain',
        ['qcskrow']   = 'AnimSpeed_Qcskrow',
        ['eqcastr']   = 'AnimSpeed_Quickcast',
    }
    local speedKey   = groupSpeedKey[animGroup] or 'AnimSpeed_Quickcast'
    local baseSpeed  = Cfg.animSpeed and Cfg.animSpeed:get(speedKey) or 1.00
    local finalSpeed = baseSpeed * (Cfg.animSpeed and Cfg.animSpeed:get('AnimSpeedScale') or 1.0) * getSpeedyMagickSpeedMult() * getNSPAlacritySpeedMult() * getShieldCastingPenaltyMult(schoolStr, activeSpell.item ~= nil)
    if finalSpeed <= 0 then finalSpeed = 1.0 end
    Cast.currentFinalSpeed = finalSpeed

    local safetyUnlockDelay = Cfg.animSpeed and Cfg.animSpeed:get('SafetyUnlockTimer') or 1.0
    if safetyUnlockDelay <= 0 then safetyUnlockDelay = 1.0 end
    local scaledSafetyUnlockDelay = (safetyUnlockDelay + 1.0) / finalSpeed

    local now = core.getSimulationTime()
    Cast.isCasting        = true
    Cast.hasFiredThisCast = false
    Cast.hasQueuedLaunch  = false
    Cast.startKeyCastId   = nil
    Cast.costPaidCastId   = nil
    -- Do NOT reset pendingLaunches: a previous paid cast's launch may still be queued.
    Cast.currentCastId = Cast.currentCastId + 1
    Cast.castStartTime = now
    Cast.isBound2HWeaponCast = hasBound2HWeaponEffect(activeSpell)
    suppressShieldDuringCast()
    -- Publish before any callback runs, so no frame lets a held 2H attack start.
    Cast.currentAnimGroup = animGroup
    enableCombatBlock()
    reconcileWeaponAttackLock()
    -- Lock NGarde so a later parry cannot overlay this cast.
    setNgardeParryControl(true)
    self:sendEvent('OSSC_CastingState', { isCasting = Cast.isCasting })
    self:sendEvent('MagExp_SetPendingCastSpellId', { spellId = spellId })

    -- Re-arming safety unlock: keep re-arming while the PMM UI holds the cast.
    local safetyUnlockCastId = Cast.currentCastId
    local safetyUnlockTick
    safetyUnlockTick = function()
        if not Cast.isCasting then return end
        if Cast.currentCastId ~= safetyUnlockCastId then return end
        if PMM.isWaitingForPMMInput then
            debugLog("Safety unlock timer delayed — PMM UI is open")
            async:newUnsavableSimulationTimer(0.5, safetyUnlockTick)
            return
        end
        if PMM.pmmUiClosedAt and core.getSimulationTime() - PMM.pmmUiClosedAt < scaledSafetyUnlockDelay then
            async:newUnsavableSimulationTimer(0.5, safetyUnlockTick)
            return
        end
        if PMM.pmmDeferredRecall then
            -- No release/stop key fired (e.g. qcsnap): open the window as last resort.
            debugLog("Safety unlock timer fired — opening PMM multi mark window (no cast text key)")
            openPMMRecallWindow()
            if not PMM.isWaitingForPMMInput then
                -- Window failed: cancel; the vanilla mark must not go through.
                PMM.pmmSelectedDestination = nil
                PMM.pmmVanillaRecall = false
                fullCleanup('PMM window unavailable — recall cancelled')
            else
                async:newUnsavableSimulationTimer(0.5, safetyUnlockTick)
            end
            return
        end
        local isIncapacitated = false
        for _, incapGroup in ipairs({'knockdown','knockout','swimknockdown','swimknockout'}) do
            if anim.isPlaying(self, incapGroup) then
                isIncapacitated = true
                debugLog("Safety unlock blocked — incapacitated in " .. incapGroup)
                break
            end
        end
        if not isIncapacitated then
            debugLog("Safety unlock timer fired ("..scaledSafetyUnlockDelay.."s) — forcing full cleanup")
            fullCleanup("safety unlock timer")
        end
    end
    async:newUnsavableSimulationTimer(scaledSafetyUnlockDelay, safetyUnlockTick)

    Cast.currentAnimGroup = animGroup
    -- playBlended seeds unlisted groups at PRIORITY.Default: list every masked bone.
    -- LowerBody must stay below Movement or locomotion freezes during the cast.
    local blendOpts = buildCastBlendOptions(finalSpeed, animGroup)
    if I.AnimationController and I.AnimationController.playBlendedAnimation then
        I.AnimationController.playBlendedAnimation(animGroup, blendOpts)
        anim.setSpeed(self, animGroup, finalSpeed)
    end

    local fallbackCastId = Cast.currentCastId
    async:newUnsavableSimulationTimer(0.01, function()
        if not Cast.isCasting or Cast.currentCastId ~= fallbackCastId then return end
        if not anim.isPlaying(self, animGroup) then
            local fallback
            if grimoireConditionMet() then
                fallback = 'eqcastr'
            else
                fallback = (range == RANGE.Self) and 'quickbuff' or 'quickcast'
            end
            debugLog("Fallback: " .. animGroup .. " → " .. fallback)
            Cast.currentAnimGroup = fallback
            if I.AnimationController and I.AnimationController.playBlendedAnimation then
                I.AnimationController.playBlendedAnimation(
                    fallback, buildCastBlendOptions(finalSpeed, fallback))
            end
        end
    end)
end



-- ── Crosshair look target (rendering ray, cached in onFrame) ──
-- castRenderingRay throws outside frame/input events; onUpdate gets the cache,
-- with a physics castRay fallback (misses many doors/containers).
local cachedLookRay = { hit = false, hitPos = nil, hitNormal = nil, hitObject = nil }
local cachedLookStart = nil
local cachedLookEnd   = nil

-- Rendered-view forward from camera yaw/pitch (roll does not move it).
local function cameraForwardFromAngles()
    local pitch    = -(camera.getPitch() + camera.getExtraPitch())
    local yaw      =   camera.getYaw()  + camera.getExtraYaw()
    local cosPitch = math.cos(pitch)
    return util.vector3(
        cosPitch * math.sin(yaw),
        cosPitch * math.cos(yaw),
        math.sin(pitch))
end

-- ── The crosshair ray (origin, far end) ──
-- viewportToWorldVector is skewed in first person (view matrix uses this frame's head,
-- getPosition() the last): direction from orientation, origin corrected by that offset.
local function getCameraAimRay()
    local camPos  = camera.getPosition()
    local forward = cameraForwardFromAngles()
    if camera.viewportToWorldVector then
        local v = camera.viewportToWorldVector(util.vector2(0.5, 0.5))
        if v and v.length then
            local len = v:length()
            if len >= 0.9 and len <= 1.1 then
                local drift = v - forward
                if drift:length() <= 32 then
                    camPos = camPos + drift
                end
            end
        end
    end
    return camPos, camPos + forward * 10000
end

local function refreshLookRay()
    local camPos, rayEnd = getCameraAimRay()
    if not camPos then
        -- Camera unavailable this frame; keep the previous cache intact.
        return
    end
    cachedLookStart = camPos
    cachedLookEnd   = rayEnd

    -- Legal: refreshLookRay() is called only from onFrame.
    local res = nearby.castRenderingRay(camPos, rayEnd, { ignore = self })
    if not res then
        -- Not in a frame context: keep the cache; onUpdate falls back.
        return
    end
    cachedLookRay = {
        hit       = res.hit and true or false,
        hitPos    = res.hitPos,
        hitNormal = res.hitNormal,
        hitObject = res.hitObject,
    }
end

-- Cached rendering ray, else physics castRay (the only ray legal in onUpdate).
local function getLookTargetRay(cameraPos, endPos)
    if cachedLookRay and cachedLookRay.hit and cachedLookRay.hitPos then
        return {
            hit       = true,
            hitPos    = cachedLookRay.hitPos,
            hitNormal = cachedLookRay.hitNormal,
            hitObject = cachedLookRay.hitObject,
        }
    end
    -- Same-context physics fallback. Aim along the crosshair line handed in
    -- (the one the spell is about to be launched along) so the fallback and
    -- the launch describe the same shot; the cached line is only used when
    -- nothing has been passed yet (first frame after a load).
    local from = cameraPos or cachedLookStart
    local to   = endPos   or cachedLookEnd
    if not (from and to) then return { hit = false } end
    return nearby.castRay(from, to, { ignore = self })
end

-- OpenMW combat.cpp getHitContact fallback for touch spells:
-- When the crosshair ray did not hit a valid living actor, the engine looks for
-- the nearest living actor within reach (fCombatDistance — NOT multiplied by
-- fHandToHandReach) and inside the combat tolerance angles (fCombatAngleXY / 90
-- and fCombatAngleZ / 90) with line of sight. That tolerance is what makes a
-- touch spell land on a skeleton you only roughly aimed at, so it must follow
-- the engine's numbers exactly — see scripts/ossc/ossc_cast_rules.lua.
--
-- The player is the only caster that can look up, so the vertical angle is the
-- look pitch; the horizontal direction is the camera yaw. The eye point stays
-- the player's own (vanilla eye level), never the camera: third person puts the
-- camera metres behind the body and the engine measures from the actor.
local function getHitContactActor()
    local pitch = -(camera.getPitch() + camera.getExtraPitch())
    local yaw   =   camera.getYaw()   + camera.getExtraYaw()
    return require('scripts.ossc.ossc_cast_rules').findTouchContact(self, {
        dirXY    = util.vector3(math.sin(yaw), math.cos(yaw), 0),
        pitchSin = math.sin(pitch),
    })
end

-- Forward declaration: processPendingLaunches is defined after onUpdate (split
-- out to stay under LuaJIT's 60-upvalue cap). Without this, the call at the
-- end of onUpdate resolves to a nil global and fails every frame.
local processPendingLaunches

-- ── Moving-target lead: crosshair sampling ─────────────────────────────────
-- Every simulation tick, feed the actor currently under the crosshair to the
-- lead tracker, so an eligible target-range quick-cast released later has
-- ≥0.25 s of movement history to estimate velocity from (the engine's AI does
-- the same for its combat target via AiCombatStorage::mLastTargetPos).
--
-- Deliberately NOT gated on the stance: a cast can start from Weapon stance or
-- relaxed hands (never from Spell stance, which sits out — see
-- ossc_cast_rules.quickcastStanceAllowed) and the lead must be there for both.
-- Runs from its own function to keep onUpdate's upvalue budget intact (LuaJIT
-- caps functions at 60).
local function updateLeadTracking()
    local hitObj = cachedLookRay.hit and cachedLookRay.hitObject or nil
    if not hitObj or hitObj == self then return end
    local hitType = hitObj.type
    if hitType ~= types.NPC and hitType ~= types.Creature then return end
    if types.Actor.isDead(hitObj) then return end
    targetLead.track(hitObj, core.getSimulationTime())
end

-- ── onUpdate ──────────────────────────────────────────────────────────────
local function onUpdate(dt)
    reconcileShieldWeapon()
    -- Keep the mid-cast combat/attack locks in sync with the cast state, the
    -- equipped weapon and the settings.
    reconcileCombatBlock()
    reconcileWeaponAttackLock()

    -- Track the crosshair actor for the moving-target lead (cheap: one linear
    -- scan over ≤8 tracked actors per tick).
    updateLeadTracking()

    -- ── Stance-suppression mirror (late-frame raisers) ─────────────────────
    -- A quickkey press can raise the stance AFTER onFrame has run — an async
    -- timer firing in the update phase (e.g. QuickSelect's 0.1s stance
    -- timer), or the engine's own delayed quickkey application (GUI phase,
    -- after mechanics) — which would otherwise stay up for rendering and
    -- through the next frame's mechanics. Mirror the revert here so the
    -- press's late raise is put back down in the same update instead of
    -- flashing (or lodging) on screen, and record it as the press's magic
    -- signal first (see below). The revert only runs inside the quickkey
    -- window (see Stance.quickkeyWindowActive): the blockade is scoped to
    -- quickkey-raised stances, and a stance the player opened by hand
    -- (spellStanceAllowed) is never touched, whatever the setting.
    if Cfg.general and Cfg.general:get('SuppressSpellStance') == true
        and not Stance.spellStanceAllowed
        and not allowCastInSpellStance() then
        local updateStance = types.Actor.getStance(self)
        if updateStance == STANCE.Spell then
            -- A late raise can be the ONLY signal a magic quickkey press ever
            -- delivers. When the press does not change the selection — the
            -- tile's spell is already the selected one, e.g. right after a
            -- load with a spell equipped, when the recast slot marker is not
            -- set yet — the raised Spell stance is what distinguishes a
            -- Magic/MagicItem press from a plain Item press. The engine (and
            -- hotbar mods such as QuickSelect, with their ~0.1s stance timer)
            -- raise it in the update/GUI phase AFTER onFrame, so the capture
            -- in onFrame never sees it, and reverting it here without
            -- recording it would make the press resolve as a no-cast item
            -- hotkey. A raise observed while a press is pending and not
            -- started in Spell stance IS that press's raise (a plain Item
            -- quickkey never enters Spell stance) — record it as the magic
            -- signal before putting the stance back down.
            if QuickkeyPress.slot ~= nil
                and QuickkeyPress.timer > 0
                and not QuickkeyPress.startedInSpellStance
                and not QuickkeyPress.sawSpellStance then
                QuickkeyPress.sawSpellStance = true
                debugLog("[OSSC Hotkey] Quickkey Spell stance raise observed "
                    .. "in update phase — magic hotkey confirmed")
            end
            -- Revert only inside the quickkey window (pending press or in-flight quickkey cast); manual stances stay up.
            if Stance.quickkeyWindowActive() then
                debugLog("[OSSC Stance] Late Spell stance raise reverted (update mirror)")
                types.Actor.setStance(self, Stance.quickkeyRevertTarget())
                Stance.suppressWeaponTransitionSounds()
            end
        elseif updateStance == STANCE.Weapon or updateStance == STANCE.Nothing then
            Stance.lastNonSpellStance = updateStance
        end
    end

    -- Keep the window until a stable non-Spell state; consuming the pending slot is not enough.
    -- A manual stance key always wins.
    if Stance.nativeQuickkeySuppression then
        local suppressionSettingOn = Cfg.general
            and Cfg.general:get('SuppressSpellStance') == true
        local liveStance = types.Actor.getStance(self)
        if not suppressionSettingOn or Stance.spellStanceAllowed then
            clearQuickkeyStanceSuppression()
        elseif not Cast.isCasting
            and QuickkeyPress.slot == nil
            and liveStance ~= STANCE.Spell
            and core.getSimulationTime() >= Stance.nativeQuickkeySuppressionUntil then
            clearQuickkeyStanceSuppression()
        end
    end

    -- The sheathe started in mechanics, before the stance mirror could put the
    -- raise back. Stop it once, before 'unequip detach' hides the mesh. Runs
    -- for a Weapon stance too: the revert may already have landed while the
    -- sheathe animation is still playing.
    Stance.cancelFreshWeaponTransition()

    -- While the suppression window is active the engine may still start the
    -- equip/unequip sounds on a later mechanics update. Keep silencing them
    -- per-frame until the window closes.
    if Stance.nativeQuickkeySuppression and not Stance.spellStanceAllowed then
        Stance.suppressWeaponTransitionSounds()
    end

    -- An attack may be queued by the engine before the animation-controller
    -- callback gets a chance to cancel it. Repeat the cancel while the cast
    -- owns the hands; this closes the same one-frame queueing race as the
    -- control switch and also catches attacks started by another mod.
    if Stance.collapsedDrawGroup and not anim.isPlaying(self, Stance.collapsedDrawGroup) then
        Stance.collapsedDrawGroup = nil
    end
    if shouldBlockHeavyAttack() then
        local castRulesNow = require('scripts.ossc.ossc_cast_rules')
        for _, groupName in ipairs(Anim.HEAVY_ATTACK_GROUPS) do
            -- The collapsed quick-key draw is not an attack. Cancelling it
            -- before the engine finishes the equip state drops the mesh again.
            -- The same rule covers any other draw in flight (a bound weapon
            -- auto-equipped mid-cast, a mod-issued draw): the weapon mesh is
            -- attached by the draw's own 'equip attach' key.
            if groupName ~= Stance.collapsedDrawGroup
                and not castRulesNow.isDrawPlaying(Stance.drawTracker, groupName)
                and anim.isPlaying(self, groupName) then
                debugLog("Cancelled " .. groupName .. " attack during quickcast (update)")
                anim.cancel(self, groupName)
            end
        end
    end

    -- Suppress shield blocking during quickcast when that setting is enabled.
    if shouldBlockShield() then
        if anim.isPlaying(self, 'shield') then
            debugLog("Cancelled shield raise during quickcast (update)")
            anim.cancel(self, 'shield')
        end
    end

    -- Cancel an unreleased quickcast immediately on incapacitation/stagger/knockdown.
    if Cast.isCasting and not Cast.hasFiredThisCast and isQuickcastInterrupted() then
        debugLog("Quickcast cancelled — incapacitated mid-cast")
        fullCleanup("incapacitated mid-cast")
        return
    end

    local triggerChoice = Cfg.keys and Cfg.keys:get('QuickCastTrigger') or 'none'
    if triggerChoice ~= 'none' and triggerChoice ~= 'Disabled' then
        local threshold = (Cfg.keys and Cfg.keys:get('QuickCastTriggerThreshold')) or 0.60
        local axisId = nil
        local choiceLower = triggerChoice:lower()
        if choiceLower:find('l2') then
            axisId = input.CONTROLLER_AXIS.TriggerLeft
        elseif choiceLower:find('r2') then
            axisId = input.CONTROLLER_AXIS.TriggerRight
        end
        if axisId then
            local currentValue = input.getAxisValue(axisId) or 0.0
            local wasPressed = Cast.prevTriggerValue >= threshold
            local isPressed  = currentValue     >= threshold
            if isPressed and not wasPressed then
                debugLog("Trigger rising edge: " .. tostring(triggerChoice) ..
                    " value=" .. tostring(currentValue))
                triggerQuickCast()
            end
            Cast.prevTriggerValue = currentValue
        end
    else
        Cast.prevTriggerValue = 0.0
    end

    do
        local condMet = grimoireConditionMet()
        if condMet and not Stance.isGrimoireIdlePlaying and not Cast.isCasting then
            startGrimoireIdle()
        elseif not condMet and Stance.isGrimoireIdlePlaying then
            stopGrimoireIdle()
        end
    end

    if Cast.isCasting and PMM.pmmCancelled then
        debugLog("[OSSC] PMM Recall was cancelled by user")
        fullCleanup("PMM recall cancelled")
        return
    end

    if Cast.isCasting and PMM.isWaitingForPMMInput then
        local uiMode = (ui and ui.activeMode)
        if not uiMode and I.UI and I.UI.getMode then uiMode = I.UI.getMode() end
        -- setMode('Interface') is not reflected by getMode() synchronously; wait before treating nil as cancel.
        if uiMode ~= 'Interface' and PMM.pmmUiOpenedAt
            and core.getSimulationTime() - PMM.pmmUiOpenedAt < 0.25 then
            -- Window opens after 'release'; let the cast animation finish.
            Cast.castStartTime = core.getSimulationTime()
            return
        end
        if uiMode == 'Interface' then
            -- Don't freeze the cast animation: the actor would stay stuck in the cast pose.
            for _, onFrameFunction in pairs(onFrameFunctions or {}) do
                onFrameFunction(dt)
            end
            Cast.castStartTime = core.getSimulationTime()
            return
        else
            -- Closed without a pick: remove the window and cancel (no vanilla Recall under PMM compat).
            PMM.isWaitingForPMMInput = false
            PMM.pmmUiClosedAt = core.getSimulationTime()
            PMM.pmmUiOpenedAt = nil
            destroyPMMWindow()
            PMM.pmmSelectedDestination = nil
            PMM.pmmVanillaRecall = false
            debugLog("[OSSC] PMM interface closed — cancelling recall (no vanilla fallback)")
            fullCleanup('PMM recall cancelled — window closed')
        end
    elseif Cast.isCasting and Cast.currentAnimGroup then
        anim.setSpeed(self, Cast.currentAnimGroup, Cast.currentFinalSpeed)
    end

    -- NOTE: manual stance-key (R / F) edge detection lives in onFrame, in the
    -- same handler and ahead of the stance-suppression check, so the
    -- suppression always sees the allowance the key press just set. (It used
    -- to live here in onUpdate and read the post-toggle stance, which
    -- inverted enter/exit intent — see the comment in onFrame.)

    processPendingLaunches()
end

-- ── Pending launches ────────────────────────────────────────────────────
-- ── Moving-target lead: launch-site helper ─────────────────────────────────
-- Returns the lead-adjusted launch direction for a target-range quick-cast at
-- a living actor, or nil when this cast's private 50/50 decision declines lead
-- or there is no fresh velocity history / usable intercept. Split into its
-- own function so processPendingLaunches only gains one upvalue (LuaJIT's
-- 60-upvalue cap); all engine cloning lives in ossc_target_lead.lua.
--
-- Stance-free by construction: this runs inside the single launch funnel
-- every OSSC quick-cast goes through (hotkey button, quickkeys 1-9,
-- quick-select slots, enchanted items/scrolls, safety-timer launches), which
-- never branches on the stance — Weapon, Spell and relaxed stances all lead
-- identically.
local function leadLaunchDirection(spell, startPos, aimPoint, hitObject)
    local now = core.getSimulationTime()
    if not targetLead.shouldLead(self.id, now) then return nil end
    return targetLead.launchDirection{
        startPos      = startPos,
        aimPoint      = aimPoint,
        target        = hitObject,
        effects       = spell.effects,
        effectRecords = effectRecs,
        now           = now,
        gmstBaseSpeed = GMST.fTargetSpellMaxSpeed,
    }
end

-- Split out of onUpdate: LuaJIT caps every function at 60 upvalues and
-- onUpdate had grown past the cap. Same code, same order, own upvalue
-- budget.
processPendingLaunches = function()
    if #Cast.pendingLaunches == 0 then return end
    local currentTime = core.getSimulationTime()
    for i = #Cast.pendingLaunches, 1, -1 do
        local pl = Cast.pendingLaunches[i]
        if currentTime >= pl.timeToFire then
            table.remove(Cast.pendingLaunches, i)
            local spell = pl.spell
            if spell then
                -- ── Stagger / knockdown interruption ──
                -- Cancel before any cost is paid instead of launching.
                if isStaggeredOrKnocked() then
                    debugLog("Launch cancelled — staggered or knocked mid-cast")
                    -- Only the current cast's launch may tear down state; a stale launch is dropped.
                    if pl.castId == Cast.currentCastId then
                        fullCleanup("staggered/knocked mid-cast")
                    end
                    break
                end

                -- `== false`, not `not`: a missing isPaid is not "out of magicka".
                if pl.isPaid == false then
                    if pl.castId == Cast.currentCastId then
                        launchCleanup(spell.item and "not enough item charge"
                            or "not enough magicka")
                    end
                    break
                end

                local chance, castSchool = getCastChance(spell, self)
                if debug.isGodMode() then chance = 100 end
                chance = math.max(0, math.min(100, chance))
                local okCast = debug.isGodMode() or chance >= 100
                if not okCast then okCast = math.random(0,99) < chance end
                local isItem = spell.item ~= nil
                debugLog("Casting "..tostring(spell.id).." chance="..chance.." ok="..tostring(okCast))
                if okCast then
                    local isPMMHandling = isPMMCompatEnabled() and isPMMInstalled()
                    local isMark, isRecall = false, false
                    if isPMMHandling then
                        isMark, isRecall = checkMarkRecall(spell)
                    end

                    local selectedLocation = PMM.pmmSelectedDestination
                        and PMM.pmmLocations[PMM.pmmSelectedDestination] or nil
                    local pmmHandledRecall = isRecall
                        and not PMM.pmmVanillaRecall
                        and selectedLocation ~= nil

                    local resourcesPaid = true
                    if resourcesPaid then
                        if isPMMHandling and isMark then
                            handlePMMMark()
                        end

                        if pmmHandledRecall then
                            local snd = effectRecs.recall and effectRecs.recall.hitSound or 'mysticism hit'
                            if snd == '' then snd = 'mysticism hit' end
                            ambient.playSound(snd, { volume = 0.9 })
                            -- PMM's own event plus OSSC's identical fallback (ossc_global.lua); the second is a no-op.
                            core.sendGlobalEvent('PMM_loadLoc', { self, selectedLocation })
                            core.sendGlobalEvent('OSSC_PMMTeleport', { self, selectedLocation })
                            debugLog(string.format(
                                '[OSSC PMM] Teleporting to selected mark %s (%s)',
                                tostring(selectedLocation.name),
                                tostring(selectedLocation.cell or
                                    (selectedLocation.gridX .. '/' .. selectedLocation.gridY))))
                            local recallMode = SkillModes.normalize(
                                Cfg.general and Cfg.general:get('SkillProgressionMode'))
                            if recallMode ~= 'none' and I.SkillProgression
                                and I.SkillProgression.skillUsed then
                                I.SkillProgression.skillUsed('mysticism', {
                                    skillGain = 3,
                                    useType = I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success,
                                })
                            end
                            self:sendEvent('OSSC_OnSpellCast', { spellId = spell.id })
                        else
                            -- Same view forward the crosshair ray uses.
                            local cameraDir = cameraForwardFromAngles()
                            local flatForward = util.vector3(cameraDir.x, cameraDir.y, 0):normalize()
                            local leftDir     = util.vector3(-flatForward.y, flatForward.x, 0)
                            local startPos
                            if hasEternalGrimoire() then
                                -- ── Grimoire spawn offsets (right-hand cast) ──
                                -- Edit in scripts/ossc/ossc_launch_offsets.lua.
                                local grimOff = launchOffsets.getGrimoire(camera.getMode() == camera.MODE.FirstPerson)
                                if camera.getMode() == camera.MODE.FirstPerson then
                                    startPos = camera.getPosition()
                                        + flatForward * grimOff.forward
                                        + util.vector3(0, 0, grimOff.up)
                                        + leftDir * grimOff.left
                                else
                                    startPos = self.position
                                        + flatForward * grimOff.forward
                                        + util.vector3(0, 0, grimOff.up)
                                        + leftDir * grimOff.left
                                end
                            else
                                -- ── Normal spawn offsets (left-hand cast) ──
                                -- Per-animation; edit in scripts/ossc/ossc_launch_offsets.lua.
                                local castAnim = pl.animGroup or Cast.currentAnimGroup
                                local off = launchOffsets.get(castAnim, camera.getMode() == camera.MODE.FirstPerson)
                                if camera.getMode() == camera.MODE.FirstPerson then
                                    startPos = camera.getPosition()
                                        + flatForward * off.forward
                                        + util.vector3(0, 0, off.up)
                                        + leftDir * off.left
                                else
                                    startPos = self.position
                                        + flatForward * off.forward
                                        + util.vector3(0, 0, off.up)
                                        + leftDir * off.left
                                end
                            end

                            -- Read the crosshair ray now, not the onFrame cache: the camera has moved since.
                            local cameraPos, endPos = getCameraAimRay()
                            -- castRenderingRay throws in onUpdate: use the onFrame-cached ray, physics castRay as fallback.
                            local ray = getLookTargetRay(cameraPos, endPos)
                            debugLog(string.format("Raycast: hit=%s hitObject=%s", tostring(ray.hit), tostring(ray.hitObject and ray.hitObject.recordId or "nil")))
                            local range = RANGE.Target
                            local spellRec = spellRecs[spell.id] or spell.enchantment
                            local hasTouchEffects = false
                            local hasTargetEffects = false
                            if spellRec and spellRec.effects then
                                for _, eff in ipairs(spellRec.effects) do
                                    if eff.range == RANGE.Touch then
                                        hasTouchEffects = true
                                    elseif eff.range == RANGE.Target then
                                        hasTargetEffects = true
                                    end
                                end
                                if spellRec.effects[1] then
                                    range = spellRec.effects[1].range
                                end
                                if range == RANGE.Self then
                                    if hasTouchEffects then
                                        range = RANGE.Touch
                                    elseif hasTargetEffects then
                                        range = RANGE.Target
                                    end
                                end
                            end
                            local hitObject = nil
                            if range == RANGE.Touch and (not ray.hit or not ray.hitObject) then
                                local contactActor = getHitContactActor()
                                if contactActor then
                                    hitObject = contactActor
                                else
                                    local rightDir = leftDir * -1
                                    local upDir    = cameraDir:cross(rightDir):normalize()
                                    local offsets = {
                                        leftDir*4, leftDir*-4, upDir*4, upDir*-4,
                                        leftDir*8, leftDir*-8, upDir*8, upDir*-8,
                                        leftDir*10+upDir*10, leftDir*10-upDir*10,
                                        leftDir*-10+upDir*10, leftDir*-10-upDir*10
                                    }
                                    for _, offset in ipairs(offsets) do
                                        local altEnd = endPos+offset
                                        -- onUpdate: physics ray only.
                                        local altRay = nearby.castRay(cameraPos, altEnd, { ignore = self })
                                        if altRay.hit and altRay.hitObject then
                                            local t = altRay.hitObject.type
                                            if (t==types.NPC or t==types.Creature) and
                                               not types.Actor.isDead(altRay.hitObject) then
                                                ray = altRay; break
                                            elseif t ~= types.NPC and t ~= types.Creature then
                                                ray = altRay; break
                                            end
                                        end
                                    end
                                end
                            end
                            if not hitObject and (range ~= RANGE.Self or hasTouchEffects or hasTargetEffects) then
                                local candidateHit = ray.hit and ray.hitObject or nil
                                if candidateHit and candidateHit ~= self then
                                    local hitType = candidateHit.type
                                    if hitType then
                                        if hitType == types.NPC or hitType == types.Creature then
                                            if not types.Actor.isDead(candidateHit) then
                                                hitObject = candidateHit
                                            end
                                        else
                                            hitObject = candidateHit
                                        end
                                    end
                                end
                            end
                            -- Touch fallback: getHitContact for a living target when the ray hit an object or dead actor.
                            if range == RANGE.Touch and (not hitObject or (hitObject.type ~= types.NPC and hitObject.type ~= types.Creature)) then
                                local contactActor = getHitContactActor()
                                if contactActor then
                                    hitObject = contactActor
                                end
                            end
                            local aimPoint       = ray.hit and ray.hitPos or endPos
                            local distFromPlayer = (aimPoint - self.position):length()
                            -- ── Parallax convergence ──
                            -- Converge on the first physics obstacle the projectile can hit; the rendering hit is only for target selection.
                            local convergePoint = aimPoint
                            do
                                local from = cameraPos
                                local aimDir = (endPos - cameraPos):normalize()
                                for _ = 1, 4 do
                                    local physRay = nearby.castRay(from, endPos, { ignore = self })
                                    if not (physRay.hit and physRay.hitPos) then break end
                                    -- Projectiles pass through dead actors; don't converge on them.
                                    local o = physRay.hitObject
                                    local t = o and o.type
                                    local isActor = t == types.NPC or t == types.Creature
                                    local isDeadActor = isActor and types.Actor.isDead(o)
                                    if not isDeadActor then
                                        -- Vanilla parity: an actor is not a
                                        -- surface to graze. When the crosshair
                                        -- ray reaches a living actor, converge
                                        -- on the CENTRE of its bounding box, so
                                        -- a low crosshair (their legs, the
                                        -- ground at their feet) still sends the
                                        -- bolt through the middle of the body —
                                        -- where the engine's own cast aims and
                                        -- where the hit effect belongs.
                                        convergePoint = (isActor
                                            and require('scripts.ossc.ossc_cast_rules').actorAimPoint(o))
                                            or physRay.hitPos
                                        break
                                    end
                                    from = physRay.hitPos + aimDir * 2
                                end
                            end
                            local skewedDir      = (convergePoint - startPos):normalize()
                            -- ── Moving-target lead (engine AimDirToMovingTarget clone) ──
                            -- When the crosshair is on a living actor and the
                            -- spell flies a bolt (Target-range effects), aim at
                            -- the predicted intercept point instead of where
                            -- the target stands now. The displacement is added
                            -- to the already-converged aim point, so a
                            -- stationary target (zero lead displacement) keeps
                            -- the exact vanilla-crosshair trajectory, and the
                            -- parallax convergence stays intact for moving
                            -- ones. Applies to every quick-cast launch queued
                            -- below regardless of the stance the cast started
                            -- from — Weapon, Spell or relaxed.
                            local launchDir = skewedDir
                            if hasTargetEffects and hitObject and hitObject ~= self then
                                local hitType = hitObject.type
                                if (hitType == types.NPC or hitType == types.Creature)
                                    and not types.Actor.isDead(hitObject) then
                                    local led = leadLaunchDirection(spell, startPos, aimPoint, hitObject)
                                    if led then
                                        launchDir = led
                                        debugLog("Moving-target lead applied: " .. tostring(hitObject.recordId))
                                    end
                                end
                            end
                            if range == RANGE.Touch and hitObject then
                                -- Vanilla getFocusObject: an actor under the
                                -- crosshair is a legal touch target inside
                                -- iMaxActivateDist of the eye (telekinesis does
                                -- not extend it for actors), and the touch
                                -- reach/cone only applies to the getHitContact
                                -- fallback above.
                                --
                                -- Measure to the TARGET, not to the crosshair
                                -- ray end. When the ray missed — aiming over a
                                -- shoulder, at a cliff racer against the sky, at
                                -- a target whose mesh the physics ray slid past
                                -- — aimPoint is the far end of the 10000-unit
                                -- aim line, and that threw away exactly the
                                -- getHitContact target the engine keeps.
                                if not require('scripts.ossc.ossc_cast_rules').isCrosshairTouchTarget(
                                    self, hitObject, cameraPos,
                                    { camDist = camera.getThirdPersonDistance() }) then
                                    hitObject = nil
                                end
                            end
                            local spawnOffset = 80
                            local distFromStart = (aimPoint - startPos):length()
                            if (hitObject or ray.hit) and distFromPlayer < 200 then spawnOffset = 10 end
                            if ray.hit and spawnOffset >= distFromStart then
                                spawnOffset = math.max(5, distFromStart - 10)
                            end
                            local kineticSpells = { kinetic_bolt = true, kinetic_expl = true }
                            -- Friendlier Fire: block harmful casts at followers/summons here; SFP's ActiveSpells:add() bypasses FF.
                            local friendlyFireBlocked = false
                            if hitObject and types.Actor.objectIsInstance(hitObject) then
                                friendlyFireBlocked = friendlyFire.isFriendlyFireBlocked(self, hitObject, spell.effects)
                            end
                            if friendlyFireBlocked then
                                debugLog("Cast vetoed — friendly fire: " .. tostring(spell.id) .. " -> " .. tostring(hitObject and hitObject.recordId or "nil"))
                            end
                            -- ── Swimming fizzle (vanilla parity) ──
                            -- Target-range cast while swimming fizzles: magicka stays spent, no XP/cooldown. Wading doesn't count.
                            local swimmingFizzle = false
                            if Cfg.general and Cfg.general:get('BlockTargetSpellsWhileSwimming')
                                and hasTargetRangeEffect(spell) and isSwimmingActor(self) then
                                swimmingFizzle = true
                                debugLog("Launch fizzled — swimming: target-range spells always fail (vanilla parity), magicka stays consumed")
                                core.sound.playSound3d("Spell Failure", self, { volume = 1.0 })
                            end

                            local sentCastRequest = false
                            if swimmingFizzle then
                                -- Guaranteed fizzle; paid magicka is not refunded.
                            elseif not friendlyFireBlocked and not kineticSpells[spell.id] then
                                -- 'skill_based': 50% at skill 0 to none at 100+ (Enchant for items); else flat %.
                                local effectMode = Cfg.general and Cfg.general:get('QuickCastEffectPenalty')
                                local effectScale
                                if effectPenaltyExempt(spell) then
                                    -- Powers always full strength; scrolls too while excluded.
                                    effectScale = 1.0
                                elseif Penalty.isSkillBased(effectMode) then
                                    local effectSchool = spell.item and 'enchant'
                                        or getDominantSkillSchool(spell) or 'destruction'
                                    effectScale = Penalty.skillScale(
                                        getMagicSkillValue(self, effectSchool, spell.item ~= nil))
                                else
                                    effectScale = getPenaltyScale(effectMode)
                                end
                                -- Spell cost was paid at animation start, so isFree = true; enchanted items stay
                                -- isFree = false (charge only writable from global, SFP's guard deducts).
                                local isEnchantment = spell.item ~= nil
                                debugLog(string.format("Sending CastRequest: spell=%s range=%d hitObject=%s attacker=%s",
                                    tostring(spell.id), range,
                                    tostring(hitObject and hitObject.recordId or "nil"),
                                    tostring(self and self.recordId or "nil")))
                                
                                local showAll = true
                                if Cfg.magExp then
                                    local val = Cfg.magExp:get('ShowAllCastVfx')
                                    if val ~= nil then showAll = val end
                                end

                                -- ── Impact area and pass-through ──
                                -- `spell` is OSSC's own cast table (id, effects,
                                -- cost, type) and carries no `area` field, so
                                -- the old `area = spell.area` sent nothing at
                                -- all and Spell Framework Plus silently derived
                                -- the area from the record. Resolve it here,
                                -- exactly as SFP would (the largest area among
                                -- the bolt's own Target effects), so the launch
                                -- says what it means.
                                local castRules = require('scripts.ossc.ossc_cast_rules')
                                local boltArea = castRules.impactArea(spellRec or spell)
                                -- A living actor under the crosshair is the one
                                -- the bolt is meant for: it must be able to
                                -- show Spell Framework Plus' per-effect hit VFX
                                -- (SFP sends an AddVfx event to the TARGET's
                                -- local script, and only a global script may
                                -- attach that handler — SFP itself only attaches
                                -- it to the caster, which is why an actor's
                                -- quick-cast at the Player looked right while
                                -- the player's quick-cast at an actor showed
                                -- nothing on impact).
                                local castTarget = nil
                                if hitObject
                                    and (hitObject.type == types.NPC
                                         or hitObject.type == types.Creature)
                                    and not types.Actor.isDead(hitObject) then
                                    castTarget = hitObject
                                    core.sendGlobalEvent('OSSC_EnsureHitVfx', { actor = hitObject })
                                end
                                -- "Projectiles Pass Through Bystanders" (the NPC
                                -- settings page, default on) applies to the
                                -- player's own quick-casts as well: the bolt
                                -- flies THROUGH actors that are not its target
                                -- and those actors are not affected. The
                                -- mechanism is the named mark (see
                                -- castRules.requestBystanderPassThrough): SF+
                                -- skips every actor that is not the actor the
                                -- bolt was aimed at, so bystanders are simply
                                -- not there for it. SF+'s
                                -- `piercing` modifier is NOT used: it keeps the
                                -- bolt flying by applying the spell to everybody
                                -- it crosses (`MagExp_OnProjectilePierce` ->
                                -- applySpellToActor), and nothing bounds it to
                                -- stop at the intended target, so a bolt could be
                                -- pierced straight through the enemy it was
                                -- aimed at. A real area spell keeps the plain
                                -- collision so its blast still detonates where it
                                -- lands.
                                local userData = { OSSC = true }
                                local passThrough = not Cfg.npc
                                    or Cfg.npc:get('NPCProjectilesPassThroughBystanders') ~= false
                                if passThrough and boltArea <= 0 and range == RANGE.Target then
                                    userData = castRules.requestBystanderPassThrough(
                                        userData, self, castTarget)
                                end
                                -- Who draws the impact. A cast that EXPLODES
                                -- anywhere is the engine's blast and stays SF+'s:
                                -- `CastSpell::explodeSpell` spawns each exploding
                                -- effect's own area static at the impact point, and
                                -- SF+ mirrors that in `detonateSpellAtPos`. Taking
                                -- such a cast over would suppress that spawn and
                                -- replace it with a HIT static — a blast showing
                                -- the wrong effect. Only a cast with no area
                                -- anywhere gets OSSC's own hit statics.
                                if range ~= RANGE.Self
                                    and not castRules.explodes(spell) then
                                    userData = impactVfx.requestFor(userData, spell)
                                end

                                -- attacker must always be self, Self range included: SFP rejects non-userdata attackers.
                                core.sendGlobalEvent('MagExp_CastRequest', {
                                    attacker     = self,
                                    caster       = self,
                                    spellId      = spell.id,
                                    startPos     = startPos,
                                    direction    = launchDir,
                                    area         = boltArea,
                                    isFree       = not isEnchantment,
                                    item         = spell.item,
                                    itemRecordId = spell.item and spell.item.recordId or nil,
                                    hitObject    = hitObject,
                                    -- Impact point. On a living actor it is the
                                    -- centre of its bounding box (the same
                                    -- point the bolt is aimed at); otherwise
                                    -- the crosshair impact point, which SFP
                                    -- also uses to shorten the point-blank
                                    -- spawn offset.
                                    hitPos       = ((hitObject
                                        and (hitObject.type == types.NPC
                                             or hitObject.type == types.Creature)
                                        and not types.Actor.isDead(hitObject))
                                        and castRules.actorAimPoint(hitObject))
                                        or (ray.hit and ray.hitPos) or nil,
                                    spawnOffset  = spawnOffset,
                                    isGodMode    = debug.isGodMode(),
                                    effectScale  = effectScale,
                                    showAllCastVfx = showAll,
                                    userData     = userData,
                                })
                                sentCastRequest = true
                                self:sendEvent('OSSC_OnSpellCast', { spellId = spell.id })
                            end

                            -- ── Skill Progression Backend ─────────────────────────────────────
                            local spMode = SkillModes.normalize(
                                Cfg.general and Cfg.general:get('SkillProgressionMode'))
                            debugLog("[OSSC] SkillProgressionMode = " .. spMode)

                            -- ──────────────────────────────────────────────────────────────────
                            -- MODE: ossc — vanilla skill-use points and requirements.
                            -- No external mod events are fired.
                            -- ──────────────────────────────────────────────────────────────────
                            local function awardSkillXP_OSSC(skillId)
                                awardSkillProgress(skillId)
                            end

                            -- ──────────────────────────────────────────────────────────────────
                            -- MODES: ncg, skillevo, ncg+se, ncg+se (auto), mbsp
                            -- Calls I.SkillProgression.skillUsed with NO custom skillGain.
                            -- The external mod owns the XP formula entirely:
                            --   ncg           → addSkillLevelUpHandler fires when engine levels the skill.
                            --   skillevo      → addSkillUsedHandler chain (SE) intercepts the call.
                            --   ncg+se        → Both handlers run on the same call.
                            --   ncg+se (auto) → Same as ncg+se. SE auto-detects its own MBSP setting
                            --                   via MagExp 'auto' formula mode — no manual toggle needed.
                            --   mbsp          → MBSP's addSkillUsedHandler computes cost-scaled XP.
                            -- ──────────────────────────────────────────────────────────────────
                            -- skillId 'enchant' is exactly a CastWhenUsed
                            -- ("Cast When Used") item use - see
                            -- itemIncreasesEnchantSkill - so the use type
                            -- keys off skillId alone. The external handler
                            -- resolves its gain from the loaded skill record.
                            local function awardSkillXP_External(skillId)
                                local isEnchant = (skillId == 'enchant')
                                if not (I.SkillProgression and I.SkillProgression.skillUsed) then
                                    debugLog("[OSSC] skillUsed unavailable, falling back to OSSC direct for " .. skillId)
                                    awardSkillXP_OSSC(skillId)
                                    return
                                end
                                local useType = isEnchant
                                    and (I.SkillProgression.SKILL_USE_TYPES.Enchant_UseMagicItem or 1)
                                    or  I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success

                                local options = { useType = useType }
                                -- Delay by 200ms so the animation 'release' text key has time to fire first.
                                async:newUnsavableSimulationTimer(0.2, function()
                                    -- The external handler owns Enchant as well as
                                    -- spell schools; adding it here awards twice.
                                    I.SkillProgression.skillUsed(skillId, options)
                                end)
                            end

                            -- ──────────────────────────────────────────────────────────────────
                            -- MODE: sus ── Skill Uses Scaled
                            -- SUS reads its internal pc.spell pointer to compute cost-scaled gain.
                            -- We must patch that pointer to the current OSSC spell BEFORE calling
                            -- skillUsed, then restore it immediately afterwards.
                            -- ──────────────────────────────────────────────────────────────────
                            local function awardSkillXP_SUS(skillId)
                                local isEnchant = (skillId == 'enchant')
                                if not (I.SkillProgression and I.SkillProgression.skillUsed) then
                                    debugLog("[OSSC] SUS: skillUsed unavailable, falling back to OSSC direct for " .. skillId)
                                    awardSkillXP_OSSC(skillId)
                                    return
                                end
                                local useType = isEnchant
                                    and (I.SkillProgression.SKILL_USE_TYPES.Enchant_UseMagicItem or 1)
                                    or  I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success

                                local options = { useType = useType }
                                local spellForSus = spellRecs[spell.id]
                                if not spellForSus and spell.effects and type(spell.cost) == "number" then
                                    spellForSus = spell
                                end

                                local dtSus, prevSpell = nil, nil
                                for _, path in ipairs({
                                    'scripts.Skill_Uses_Scaled.data',
                                    'scripts.skill_uses_scaled.data',
                                }) do
                                    local ok, m = pcall(require, path)
                                    if ok and m and m.pc then dtSus = m; break end
                                end
                                if dtSus and spellForSus then
                                    prevSpell = dtSus.pc.spell
                                    dtSus.pc.spell = spellForSus
                                    debugLog("[OSSC] SUS: patched spell pointer to " .. tostring(spell.id))
                                else
                                    debugLog("[OSSC] SUS: data module not found; SUS will use its own fallback.")
                                end

                                -- Same 200ms delay as awardSkillXP_External: allow 'release' key to fire first.
                                local capturedDtSus   = dtSus
                                local capturedPrevSpell = prevSpell
                                async:newUnsavableSimulationTimer(0.2, function()
                                    I.SkillProgression.skillUsed(skillId, options)
                                    if capturedDtSus then capturedDtSus.pc.spell = capturedPrevSpell end
                                end)
                            end

                            -- ── Top-level dispatcher ──
                            local function awardSkillXP_Incantation()
                                local isIncInstalled = types.NPC.stats.skills['incantation_skill'] ~= nil
                                    and types.NPC.stats.skills['incantation_skill'](self) ~= nil
                                if not isIncInstalled then
                                    isIncInstalled = (I.SkillFramework and I.SkillFramework.getSkillStat and I.SkillFramework.getSkillStat('incantation_skill') ~= nil)
                                end
                                
                                local isCustomSpell = false
                                if spell and spell.id then
                                    isCustomSpell = spell.id:find("^player$") or spell.id:find("^Generated")
                                end
                                
                                if isIncInstalled and isCustomSpell then
                                    local xpIncGain = math.max(1.0, (spell.cost or 0) / 20)
                                    if I.SkillFramework and I.SkillFramework.skillUsed then
                                        I.SkillFramework.skillUsed('incantation_skill', { useType = 1, skillGain = xpIncGain })
                                    end
                                    
                                    local inca = 15
                                    if I.SkillFramework and I.SkillFramework.getSkillStat then
                                        local stat = I.SkillFramework.getSkillStat('incantation_skill')
                                        if stat then inca = stat.base or 15 end
                                    elseif types.NPC.stats.skills['incantation_skill'] then
                                        inca = types.NPC.stats.skills['incantation_skill'](self).base or 15
                                    end
                                    
                                    local refundPercent = 0
                                    if inca >= 50 then refundPercent = refundPercent + 0.05 end
                                    if inca >= 75 then refundPercent = refundPercent + 0.10 end
                                    if inca >= 100 then refundPercent = refundPercent + 0.15 end
                                    
                                    if refundPercent > 0 then
                                        local magicka = types.Actor.stats.dynamic.magicka(self)
                                        local refundAmount = (spell.cost or 0) * refundPercent
                                        magicka.current = math.min(magicka.base, magicka.current + refundAmount)
                                    end
                                end
                            end

                            local function awardSkillXP(skillId)
                                debugLog("[OSSC] awardSkillXP: id=" .. skillId
                                    .. " mode=" .. spMode)
                                    
                                -- 'none' leaves spellcasting progression entirely
                                -- to another mod, so nothing is awarded here -
                                -- the Incantation award included.  That mod still
                                -- needs to hear that a cast happened, or it has
                                -- nothing to call I.OSSC.awardSkillProgress for.
                                -- skillId alone identifies the use: 'enchant'
                                -- is exactly a CastWhenUsed item use, anything
                                -- else names the spell school skill.
                                if SkillModes.isDisabled(spMode) then
                                    core.sendGlobalEvent('OSSC_SkillProgressSkipped', {
                                        actor     = self,
                                        skillId   = skillId,
                                        spellId   = spell and spell.id,
                                        cost      = (spell and spell.cost) or 0,
                                    })
                                    return
                                end

                                awardSkillXP_Incantation()

                                if spMode == 'ossc' then
                                    awardSkillXP_OSSC(skillId)
                                elseif SkillModes.isExternal(spMode) then
                                    awardSkillXP_External(skillId)
                                elseif spMode == 'sus' then
                                    awardSkillXP_SUS(skillId)
                                else
                                    debugLog("[OSSC] Unknown mode '" .. tostring(spMode) .. "', using OSSC direct.")
                                    awardSkillXP_OSSC(skillId)
                                end
                            end

                            -- ── Apply to the successful cast ──────────────────────────────────
                            local castSucceeded = sentCastRequest
                            if castSucceeded then
                                local function resolveMagicSchool()
                                    local sr = spellRecs[spell.id]
                                    local school = nil
                                    if sr and sr.school then
                                        school = (type(sr.school) == "string") and sr.school:lower()
                                            or SCHOOL_STRS[sr.school]
                                    end
                                    return school or getDominantSkillSchool(spell)
                                end

                                -- Vanilla raises a skill only for skill
                                -- increasing casts: Spellcast_Success for a
                                -- plain spell without "Always Succeeds"
                                -- (spellIncreasesSkill), Enchant - "Cast When
                                -- Used" - for a CastOnUse item
                                -- (itemIncreasesEnchantSkill).  Abilities,
                                -- Powers, always-succeed spells and scrolls
                                -- raise nothing, so they are fully silent
                                -- here: no award, no announcement, no refund.
                                if isItem then
                                    if itemIncreasesEnchantSkill(spell) then
                                        awardSkillXP('enchant')
                                    end
                                elseif spellIncreasesSkill(spell) then
                                    local school = resolveMagicSchool()
                                    if school and MAGIC_SKILLS[school] then
                                        awardSkillXP(school)
                                        -- MBSP Magicka Refund (1:1 clone): a
                                        -- successful magic-school spell cast
                                        -- returns part of the magicka cost.
                                        applyMagickaRefund(spell)
                                    end
                                end

                                local pwrRec = spellRecs[spell.id]
                                if pwrRec and pwrRec.type == SPELL_TYPE.Power then
                                    OSSC_PowerCooldowns[spell.id] = core.getGameTime() + 24 * 3600
                                    debugLog("Power cooldown set for " .. tostring(spell.id))
                                end
                            end
                        end -- normal cast path (not a PMM destination)
                    else
                        -- resources not paid or failed to cast
                    end
                else
                    ui.showMessage("You failed casting the spell.")
                end
            end
            if pl.castId == Cast.currentCastId then
                launchCleanup("launch resolved")
            end
            -- Previous cast's late launch: touch nothing, or the current cast loses its state.
            break
        end
    end
end

-- ── onTextKey ─────────────────────────────────────────────────────────────
local function onTextKey(groupname, key)
    if not Cast.isCasting then return end
    if groupname ~= Cast.currentAnimGroup then return end
    local lowerKey = tostring(key):lower()
    debugLog("TextKey ["..groupname.."] '"..lowerKey.."'")
    if lowerKey == 'start' or lowerKey == 'equip start' then
        -- ── One cast start per cast (vanilla audio) ──
        -- Latch on cast id + hasFiredThisCast; hasQueuedLaunch clears at release, so a replayed 'start' would replay the sound.
        if Cast.hasFiredThisCast then return end
        if Cast.startKeyCastId == Cast.currentCastId then return end
        if Cast.hasQueuedLaunch then return end
        Cast.startKeyCastId  = Cast.currentCastId
        Cast.hasQueuedLaunch = true

        -- Payment latched separately per cast id so a duplicate start can't double-debit.
        if Cast.costPaidCastId ~= Cast.currentCastId then
            local paid, costMessage = handleCastCosts(Cast.currentSpell)
            Cast.currentIsPaid      = paid
            Cast.currentCostMessage = costMessage
            Cast.costPaidCastId     = Cast.currentCastId
        end
        -- Only OSSC's own refusal sets a message; frameworks show their own toast.
        if not Cast.currentIsPaid and Cast.currentCostMessage then
            ui.showMessage(Cast.currentCostMessage)
        end

        local spell = Cast.currentSpell
        if spell and spell.effects and spell.effects[1] then
            local mgef = effectRecs[spell.effects[1].id]
            if mgef then
                local sStr = "destruction"
                local school = mgef.school
                if type(school) == "string" then
                    sStr = school:lower()
                elseif school and SCHOOL_STRS[school] then
                    sStr = SCHOOL_STRS[school]
                end
                local sndId = (mgef.castSound and mgef.castSound ~= "") and mgef.castSound or (sStr .. " cast")
                local castGlowOn = Cfg.keys and Cfg.keys:get('EnableCastGlow')
                if castGlowOn then Cast.isGlowActive = true; add_hand_glow_vfx() end
                core.sound.playSound3d(sndId, self, { volume = 1.0 })
            end
            add_spell_vfx()
        end
        if Cast.currentAnimGroup == 'qcsnap' then
            local snapVol = Cfg.anim and Cfg.anim:get('SnapSoundVolume') or 0.45
            snapVol = math.max(0.0, math.min(1.0, snapVol))
            debugLog("Playing snap sound on start+0.6s offset: volume=" .. snapVol)
            ambient.playSoundFile("sound/ossc/qcsnap.mp3",
                { timeOffset=0.6, volume=snapVol, loop=false })
        end

        -- PMM after-cast: window opens on 'release' ('stop' / safety fallback), not here.

        local safetySpell  = Cast.currentSpell
        local safetyCastId = Cast.currentCastId
        -- Snapshot this cast's payment verdict; reading it at timer time leaks another cast's value.
        local safetyPaid   = Cast.currentIsPaid
        local safetyTimerDuration = 0.96 / Cast.currentFinalSpeed
        -- Re-arm while the PMM UI is open, or the cast is stranded.
        local safetyLaunchTick
        safetyLaunchTick = function()
            if not Cast.isCasting then return end
            if Cast.currentCastId ~= safetyCastId then return end
            if Cast.hasFiredThisCast then return end
            if PMM.isWaitingForPMMInput then
                debugLog("Safety launch timer delayed — PMM UI is open")
                async:newUnsavableSimulationTimer(0.5, safetyLaunchTick)
                return
            end
            if PMM.pmmDeferredRecall then
                -- After-cast PMM: the launch is queued when the window resolves.
                return
            end
            debugLog("Safety launch timer fired for group '" .. groupname .. "' (no 'release' key) duration="..safetyTimerDuration)
            if isStaggeredOrKnocked() then
                debugLog("Safety launch cancelled — staggered or knocked mid-cast")
                fullCleanup("staggered/knocked mid-cast (safety timer)")
                return
            end
            Cast.hasFiredThisCast = true
            if safetySpell then
                table.insert(Cast.pendingLaunches, {
                    spell      = safetySpell,
                    castId     = safetyCastId,
                    animGroup  = Cast.currentAnimGroup,
                    isPaid     = safetyPaid,
                    timeToFire = core.getSimulationTime()
                })
            end
        end
        async:newUnsavableSimulationTimer(safetyTimerDuration, safetyLaunchTick)
    elseif lowerKey == 'release' then
        if PMM.isWaitingForPMMInput then
            debugLog("'release' delayed — PMM UI is open")
            return
        end
        if Cast.hasFiredThisCast then return end
        if PMM.pmmDeferredRecall then
            -- Open the PMM window at 'release' (some groups, e.g. qcsnap, lack 'stop'); launch held until a pick.
            debugLog("'release' — opening PMM multi mark window after the cast")
            openPMMRecallWindow()
            if not PMM.isWaitingForPMMInput then
                -- Open failed: cancel, no vanilla Recall fallback. Don't test pmmDeferredRecall here (true while a window is open).
                PMM.pmmSelectedDestination = nil
                PMM.pmmVanillaRecall = false
                fullCleanup('PMM window unavailable — recall cancelled')
                return
            end
            -- Window is open: keep holding the cast lock until it resolves.
            return
        end
        Cast.hasFiredThisCast = true
        debugLog("'release' — queuing launch castId="..Cast.currentCastId)
        if isStaggeredOrKnocked() then
            -- Staggered/knocked at release: cancel like vanilla.
            debugLog("'release' cancelled — staggered or knocked mid-cast")
            fullCleanup("staggered/knocked mid-cast (release key)")
            return
        end
        if Cast.currentSpell then
            table.insert(Cast.pendingLaunches, {
                spell      = Cast.currentSpell,
                castId     = Cast.currentCastId,
                animGroup  = Cast.currentAnimGroup,
                isPaid     = Cast.currentIsPaid,
                timeToFire = core.getSimulationTime()
            })
        end
    elseif lowerKey == 'stop' then
        debugLog("'stop' key — unlocking castId="..Cast.currentCastId)
        if PMM.pmmDeferredRecall and not PMM.isWaitingForPMMInput then
            -- Fallback for groups with 'stop' but no 'release'.
            debugLog('[OSSC] Cast complete — opening PMM Recall UI window')
            openPMMRecallWindow()
        end
        if PMM.pmmDeferredRecall and PMM.isWaitingForPMMInput then
            -- Hold the cast lock until the window resolves.
            debugLog('[OSSC] PMM window open — holding cast lock until it resolves')
            return
        end
        if PMM.pmmDeferredRecall then
            -- Open failed: cancel the recall (no vanilla mark under PMM compat).
            PMM.pmmSelectedDestination = nil
            PMM.pmmVanillaRecall = false
            fullCleanup('PMM window unavailable — recall cancelled')
            return
        end
        animUnlock("stop key ["..groupname.."]")
    end
end

-- ── Incapacitation text key handler ───────────────────────────────────────
local function onIncapacitationTextKey(groupname, key)
    local lowerKey   = tostring(key):lower()
    local lowerGroup = tostring(groupname):lower()
    debugLog("IncapTextKey ["..groupname.."] '"..lowerKey.."'")
    if lowerKey == 'stop' then
        if lowerGroup == 'knockdown'     or lowerGroup == 'knockout' or
           lowerGroup == 'swimknockdown' or lowerGroup == 'swimknockout' then
            debugLog("Incapacitation stop — unlocking from " .. groupname)
            animUnlock("incap stop [" .. groupname .. "]")
        end
    end
end

-- ── NEW — egidle2 text key handler ─────────────────────────────────────────
local function onegidle2TextKey(groupname, key)
    local lowerKey = tostring(key):lower()
    debugLog("egidle2 TextKey ["..groupname.."] '"..lowerKey.."'")
    if lowerKey == 'loop stop' then
        Stance.isGrimoireIdlePlaying = false
        if grimoireConditionMet() then
            startGrimoireIdle()
        else
            debugLog("egidle2 loop stop — conditions no longer met, not restarting")
        end
    end
end

-- ── Action handler ────────────────────────────────────────────────────────
input.registerActionHandler('OSSC_QuickCast', async:callback(function(pressed)
    if not pressed then return end
    triggerQuickCast()
end))

-- ── QuickKey 1-9 Hotkey handler ──────────────────────────────────────────
-- (The pending-press state lives in the QuickkeyPress table at the top of the
-- file, shared with the onUpdate stance-suppression mirror. The quickkeyPrevious
-- recordId locals sit right below that table; see the note above both.)
-- Which slot index last cast an ordinary SPELL from a hotkey (enchanted-item
-- casts track their own slot in lastMagicItemHotkeySlot). Only THIS slot is
-- permitted to re-cast the unchanged selected spell: when a Magic hotkey is
-- pressed again while the same spell is already selected AND no fresh Spell
-- stance raise / selection change occurred (e.g. SuppressSpellStance is off
-- and the native Spell stance is still up from the first press), the press
-- would otherwise be indistinguishable from a plain non-magic item hotkey and
-- OSSC silently drops it. Any other slot pressing with no change = non-spell
-- hotkey = skip.
local lastSpellHotkeySlot     = nil

-- ── Paged hotbar (QuickSelect Ultimate) integration ───────────────────────
-- Paged hotbar mods reuse the physical 1-9 keys: plain N activates the slot
-- on the currently visible row, while <modifier>+N (Shift/Ctrl/Alt) only
-- switches the visible row, and rows hold 10 slots each — so the same
-- physical key means a completely different slot on another row. OpenMW
-- input bindings have no modifier concept, so the engine reports QuickKeyN
-- for a row switch too and OSSC sees an ordinary hotkey press.
--
-- That broke the "re-cast the item of the slot that was pressed last" rule
-- below: press the Cast-When-Used weapon on slot 1, then press Shift+1 to
-- swap the hotbar row and OSSC re-cast the weapon (nothing had changed, so
-- the press looked exactly like a re-cast). These fields let OSSC tell the
-- two apart:
--   QuickkeyPress.pendingPageSwitch — the press carried the row-switch modifier
--   QuickkeyPress.pendingEquipment  — equipment snapshot taken at press time, so
--                               a slot that equips something is never a re-cast
--   QuickkeyPress.hotbarSlotOverride(+Time) — the real (row*10+n) slot a hotbar
--                               mod says this press activated; nil = nothing at all
--   Cast.hotbarMagicActivation — { slot, time } when a hotbar mod reports the
--                               press activated a SPELL / ENCHANTED-ITEM tile,
--                               even one whose magic was already selected (a
--                               reselect changes nothing observable — no new
--                               selection id, no stance raise, no equipment
--                               change — so without this signal the press is
--                               indistinguishable from an empty slot and a
--                               fresh load, with no recast markers set yet,
--                               wrongly refuses to cast it)
--   QuickkeyPress.vetoUntil    — a hotbar mod consumed the press for something
--                               that is not a cast (works regardless of which
--                               mod's input handler the engine runs first)
QuickkeyPress.pendingPageSwitch       = false
QuickkeyPress.pendingEquipment        = nil
QuickkeyPress.pendingPressTime        = 0
QuickkeyPress.hotbarSlotOverride      = nil
QuickkeyPress.hotbarSlotOverrideTime  = 0
QuickkeyPress.vetoUntil               = 0
QuickkeyPress.vetoWindow              = 0.15
QuickkeyPress.hotbarSlotMatchWindow   = 0.5
Cast.hotbarMagicActivation            = nil

-- Wall clock for hotkey timing
local function realTimeNow()
    return core.getRealTime()
end

-- ── Row-switch modifier detection ──
-- Mirrors QuickSelect Ultimate's rule, else any modifier counts. Only gates the no-change re-cast.
local function hotbarRowSwitchPressed(slotIndex)
    local heldShift = (input.isShiftPressed and input.isShiftPressed() == true) or false
    local heldCtrl  = (input.isCtrlPressed  and input.isCtrlPressed()  == true) or false
    local heldAlt   = (input.isAltPressed   and input.isAltPressed()   == true) or false

    local kb = Cfg.qsKeyboard
    if not kb then return heldShift or heldCtrl or heldAlt end

    local mode = kb:get('barSelectionMode') or 'Shift Modifier'
    local maxBars = tonumber(kb:get('hotbarCount'))
    if not maxBars and Cfg.qs then
        maxBars = tonumber(Cfg.qs:get('hotbarCount'))
    end
    maxBars = maxBars or 3

    -- Only keys 1..hotbarCount switch rows.
    if slotIndex < 1 or slotIndex > maxBars then return false end
    if mode == 'Ctrl Modifier'  then return heldCtrl  end
    if mode == 'Alt Modifier'   then return heldAlt   end
    if mode == 'Shift Modifier' then return heldShift end
    return false
end

-- ── Equipment snapshot ──
-- A slot that equips something is never a re-cast.
local function snapshotEquipmentIds()
    local equipment = types.Actor.equipment(self)
    if not equipment then return nil end
    local snapshot = {}
    for slot, item in pairs(equipment) do
        if item and item:isValid() then
            local id = item.recordId or item.id
            if type(id) == 'string' then
                snapshot[tostring(slot)] = id:lower()
            end
        end
    end
    return snapshot
end

local function equipmentChangedSince(snapshot)
    if not snapshot then return false end   -- nothing to compare → don't block
    local current = snapshotEquipmentIds()
    if not current then return false end
    for slot, id in pairs(snapshot) do
        if current[slot] ~= id then
            return true
        end
    end
    for slot, id in pairs(current) do
        if snapshot[slot] ~= id then
            return true
        end
    end
    return false
end

-- ── Previous-frame baseline for quickkey change detection ──
-- The native quickkey runs before Lua input callbacks; capture the pre-press baseline at every onFrame exit.
local function updatePrevFrameStore()
    Stance.prevFrameSpell = nil
    Stance.prevFrameItem  = nil
    local spell = types.Actor.getSelectedSpell(self)
    if spell and spell.id then
        Stance.prevFrameSpell = spell.id
    end
    local item = types.Actor.getSelectedEnchantedItem(self)
    if item and item:isValid() then
        local rec = getItemRecord(item)
        if rec and rec.id then
            Stance.prevFrameItem = rec.id:lower()
        end
    end
    Stance.prevFrameStance    = types.Actor.getStance(self)
    Stance.prevFrameEquipment = snapshotEquipmentIds()
    local equipment = types.Actor.equipment(self)
    Stance.prevFrameWeapon = equipment and equipment[SLOT.CarriedRight] or nil
    -- Attacks in flight before the press (the press's own sheathe is not included).
    local playing = {}
    local function notePlaying(group)
        if anim.isPlaying(self, group) then playing[group] = true end
    end
    for _, g in ipairs(Anim.COMBAT_ANIM_GROUPS) do notePlaying(g) end
    for _, g in ipairs(Anim.LIGHT_ATTACK_GROUPS) do notePlaying(g) end
    Stance.prevCombatAnims = playing
end

local function handleQuickkeyPress(slotIndex)
    -- Arm when EITHER CastOnQuickkeys or SuppressSpellStance is on: the
    -- stance blockade owns quickkey-raised stances even when casting itself
    -- is disabled. The resolve path below only casts when CastOnQuickkeys
    -- is on; with casting off the press still resolves so the blockade can
    -- put the raised stance back down (the setting stands alone).
    if not Cfg.general
        or (Cfg.general:get('CastOnQuickkeys') ~= true
            and Cfg.general:get('SuppressSpellStance') ~= true) then
        return
    end

    -- Prevent onInputAction + registerTriggerHandler from snapshotting the
    -- same press twice on engine versions that expose both APIs.
    if QuickkeyPress.slot == slotIndex and QuickkeyPress.timer > 0 then
        debugLog("[OSSC Hotkey] Duplicate QuickKey callback ignored: slot="
            .. tostring(slotIndex))
        return
    end

    -- A paged hotbar mod already told us it consumed this very key press for
    -- something that is not a cast (row switch, navigation, empty slot).
    if realTimeNow() < QuickkeyPress.vetoUntil then
        debugLog("[OSSC Hotkey] QuickKey slot " .. tostring(slotIndex)
            .. " ignored — consumed by a hotbar mod.")
        return
    end

    -- A quickkey can arrive again immediately after a previous quickcast has
    -- resolved. Do not let that spam start another cast animation. The native
    -- quickkey has ALREADY been applied by the time this handler runs, so a
    -- press during cooldown still gets a tiny pending entry below: that entry
    -- lets the stance-suppression mirror see and undo the native Spell stance
    -- instead of simply returning and leaving the weapon sheathed.
    local onCooldown = QuickkeyPress.cooldownActive or Cast.isCasting

    -- NOTE: the native quickkey has ALREADY been applied by the time this
    -- handler runs (the engine runs the native quickKey() before the queued
    -- Lua input callbacks), so live reads here describe the POST-press state.
    -- The "previous" state for change detection therefore comes from the
    -- end-of-previous-frame baseline (see updatePrevFrameStore), never from
    -- live reads. A hotkey pressed while NOT in manual stance spends the
    -- manual allowance even though the native stance is already Spell — and a
    -- press from inside a genuine manual stance (previous frame was Spell)
    -- keeps it, so manual stance still suppresses hotkey casts.
    if Stance.prevFrameStance ~= STANCE.Spell then
        Stance.spellStanceAllowed = false
    end

    if Stance.spellStanceAllowed then
        debugLog("[OSSC Hotkey] QuickKey slot " .. tostring(slotIndex)
            .. " ignored — manual spell stance active.")
        return
    end

    -- The pre-press baseline captured at the end of the previous onFrame.
    -- (The equipment table is replaced — never mutated — by every store
    -- refresh, so sharing the reference with the pending press is safe.)
    QuickkeyPress.prevSpellRecordId = Stance.prevFrameSpell
    QuickkeyPress.prevItemRecordId  = Stance.prevFrameItem

    QuickkeyPress.slot                  = slotIndex
    QuickkeyPress.timer                 = onCooldown and 0.05 or 0.25
    QuickkeyPress.startedInSpellStance  = (Stance.prevFrameStance == STANCE.Spell)
    QuickkeyPress.prePressStance        = Stance.prevFrameStance
    QuickkeyPress.sawSpellStance        = false
    QuickkeyPress.blockedByCooldown    = onCooldown
    -- Clear a stale restore target only when no cast is in flight; animUnlock needs it.
    if not Cast.isCasting then
        Stance.postCastRestore          = nil
    end
    QuickkeyPress.pendingPressTime            = realTimeNow()
    QuickkeyPress.pendingEquipment            = Stance.prevFrameEquipment
    QuickkeyPress.pendingPageSwitch           = hotbarRowSwitchPressed(slotIndex)
    Stance.noteCombatAnimsAtPress()
    -- A repeat press (spam) starts a new sheathe. Allow the one-shot cancel
    -- to run again for groups that were not already an attack.
    Stance.transitionCancelDone = false

    -- On the normal native path the engine has already raised Spell stance by
    -- the time this callback runs. Arm immediately when that signal exists so
    -- any weapon draw/re-equip animation in the same input turn is covered;
    -- the pending/onUpdate path still handles engines that defer it.
    if Cfg.general and Cfg.general:get('SuppressSpellStance') == true
        and not Stance.spellStanceAllowed
        and types.Actor.getStance(self) == STANCE.Spell then
        activateQuickkeyStanceSuppression()
    end

    debugLog("[OSSC Hotkey] QuickKey PRESS accepted: slot="
        .. tostring(slotIndex)
        .. " prevSpell=" .. tostring(QuickkeyPress.prevSpellRecordId)
        .. " prevMagicItem=" .. tostring(QuickkeyPress.prevItemRecordId)
        .. " startedInSpellStance="
        .. tostring(QuickkeyPress.startedInSpellStance)
        .. " rowSwitchModifier=" .. tostring(QuickkeyPress.pendingPageSwitch)
        .. " cooldownBlocked=" .. tostring(onCooldown))
end

-- (spellStanceAllowed / prevSpellKeyDown / prevWeaponKeyDown declared at top of file)

if input.onInputAction then
    input.onInputAction(function(action)
        if input.ACTION and input.ACTION.QuickKey1
            and action >= input.ACTION.QuickKey1
            and action <= input.ACTION.QuickKey9 then
            local slotIndex = action - input.ACTION.QuickKey1 + 1
            handleQuickkeyPress(slotIndex)
        end
    end)

elseif input.registerTriggerHandler then
    for i = 1, 9 do
        input.registerTriggerHandler(
            'QuickKey' .. i,
            async:callback(function()
                handleQuickkeyPress(i)
            end)
        )
    end
end

-- ── Text key handlers ─────────────────────────────────────────────────────
if I.AnimationController then
    local groups = {
        'quickcast','quickbuff','qcconj','qctouch',
        'qcalt','qcalts','qcill','qcsnap','qcdrain','qcskrow',
        'eqcastr',   
    }
    for _, g in ipairs(groups) do
        I.AnimationController.addTextKeyHandler(g, onTextKey)
    end

    local incapGroups = { 'knockdown','knockout','swimknockdown','swimknockout' }
    for _, g in ipairs(incapGroups) do
        I.AnimationController.addTextKeyHandler(g, onIncapacitationTextKey)
    end

    -- Mid-cast heavy attack cancel (2H/bow/crossbow); 1H/H2H/thrown must never be cancelled.
    if I.AnimationController.addPlayBlendedAnimationHandler then
        I.AnimationController.addPlayBlendedAnimationHandler(function(groupname, options)
            if type(groupname) ~= 'string' then return end
            -- ── Native spell-stance VFX suppression (pre-play veto) ──
            -- Veto native 'spell'/'spellcast' equip outside OSSC casts and in the quickkey window.
            -- Only with SuppressSpellStance on; off must match vanilla.
            if Cfg.general and Cfg.general:get('SuppressSpellStance') == true
                and (groupname == 'spell' or groupname == 'spellcast')
                and (not Cast.isCasting
                     or (Stance.quickkeyWindowActive()
                         and not Stance.spellStanceAllowed)) then
                local sk = type(options) == 'table'
                           and (options.stopkey or options.stopKey or '') or ''
                if type(sk) == 'string' and sk:find('equip', 1, true) then
                    debugLog("[OSSC Stance] Vetoed native " .. groupname
                        .. " equip animation (not casting or quickkey window)")
                    options.skip = true
                    return
                end
            end
            -- ── A ready / unready must not take the casting hand ──────────
            -- The engine plays a weapon ready / unready as one All-bones
            -- blended play of the weapon's group (`equip start` →
            -- `equip stop`, `unequip start` → `unequip detach`). Its mask
            -- includes LeftArm, so toggling readiness while a quick-cast is in
            -- flight froze the gesture mid-cast — the reported "unequipping /
            -- equipping the weapon cancels my quickcast". The cast is never
            -- cancelled by a stance change: the transition simply plays
            -- WITHOUT the casting arm, and it keeps its own attach keys, so
            -- the weapon still comes out / gets sheathed normally.
            if Cast.isCasting and type(options) == 'table'
                and (isWeaponReadyGroup(groupname) or groupname == 'shield') then
                local startKey = tostring(options.startKey or options.startkey or ''):lower()
                local stopKey  = tostring(options.stopKey  or options.stopkey  or ''):lower()
                local transition = startKey:find('equip', 1, true)
                    or stopKey:find('equip', 1, true)
                if transition then
                    local mask = options.blendMask
                    if type(mask) == 'table' then
                        if mask[anim.BONE_GROUP.LeftArm] ~= nil then
                            mask[anim.BONE_GROUP.LeftArm] = PRIO.Default
                        end
                    elseif type(mask) == 'number'
                        and mask % (2 * BMASK.LeftArm) >= BMASK.LeftArm then
                        options.blendMask = mask - BMASK.LeftArm
                    end
                    debugLog("[OSSC Stance] Ready/unready keeps the quick-cast's "
                        .. "casting hand: " .. groupname)
                end
            end

            -- ── Native weapon draw / sheathe requests in the window ──
            -- Collapse the draw onto its attach key, never skip it (the weapon would stay gone). Drop the sheathe.
            if Stance.nativeQuickkeySuppression
                and Cfg.general and Cfg.general:get('SuppressSpellStance') == true
                and (isWeaponReadyGroup(groupname) or groupname == 'shield')
                and type(options) == 'table' then
                -- Engine passes startKey/stopKey; Lua callers may use lowercase.
                local startKey = tostring(options.startKey or options.startkey or ''):lower()
                local stopKey  = tostring(options.stopKey or options.stopkey or ''):lower()
                if startKey == 'equip start' or stopKey == 'equip stop' then
                    Stance.collapseEquipPlay(groupname, options)
                    return
                end
                if startKey:find('unequip', 1, true) or stopKey:find('unequip', 1, true) then
                    options.skip = true
                    debugLog("[OSSC Stance] Vetoed native weapon sheathe animation: " .. groupname)
                    return
                end
            end

            -- Hard allow-list: never touch light attack groups, even if a
            -- future change broadens shouldBlockHeavyAttack.
            for _, g in ipairs(Anim.LIGHT_ATTACK_GROUPS) do
                if groupname == g then return end
            end
            -- Heavy attack cancel: 2H/bow/crossbow attacks blocked mid-cast.
            if shouldBlockHeavyAttack() then
                for _, g in ipairs(Anim.HEAVY_ATTACK_GROUPS) do
                    if groupname == g then
                        -- Only cancel actual attacks, NOT weapon equip/draw/holster animations.
                        -- Equip/draw animations use stopkey "equip stop"; attack animations use "stop".
                        -- Without this guard, a bound-weapon spell that auto-equips the weapon
                        -- mid-cast has its draw animation cancelled, leaving the mesh invisible.
                        -- The engine passes the key as stopKey (camelCase) — reading only the
                        -- lowercase spelling never matched an engine play, so this guard never
                        -- fired and real draws were cancelled. Same rule as ossc_npc.lua
                        -- isEquipPlay.
                        local castRulesNow = require('scripts.ossc.ossc_cast_rules')
                        if castRulesNow.isEquipPlay(options) then
                            -- Remember it: the per-frame cancel below must not
                            -- touch it either, or the mesh is dropped anyway
                            -- one frame later.
                            castRulesNow.noteDraw(Stance.drawTracker, g)
                            debugLog("Allowed " .. g .. " equip/draw animation during quickcast (not an attack)")
                            return
                        end
                        castRulesNow.clearDraw(Stance.drawTracker, g)
                        debugLog("Cancelled " .. g .. " attack during quickcast")
                        anim.cancel(self, g)
                        return
                    end
                end
            end
            -- Shield raise cancel: suppressed when BlockShieldDuringQuickcast is on.
            if shouldBlockShield() and groupname == 'shield' then
                debugLog("Cancelled shield raise during quickcast")
                anim.cancel(self, 'shield')
            end
        end)
    end

    -- ── Hit / Death animation abort ──
    local function onHitDeathTextKey(groupname, key)
        if not Cast.isCasting then return end
        local lowerKey = tostring(key):lower()
        if lowerKey ~= 'start' then return end
        debugLog("Hit/death animation '" .. groupname .. "' started — aborting quickcast")
        local castGroup = Cast.currentAnimGroup  -- capture before fullCleanup clears it
        fullCleanup("hit/death interrupt [" .. groupname .. "]")
        if castGroup then
            anim.cancel(self, castGroup)
            debugLog("Cancelled cast animation group: " .. castGroup)
        end
    end

    -- ── Weapon draw (equip) tracking ──
    -- 'equip start' / 'equip attach' on a weapon group mean the engine is
    -- drawing it (it attaches the mesh on the attach key), 'equip stop' /
    -- 'unequip detach' end the transition. Record it so no OSSC cancel path
    -- can take the weapon out of the player's hands while it is invisible.
    local function trackWeaponDraw(groupname, key)
        local k = tostring(key):lower()
        if not k:find('equip', 1, true) then return end
        local castRulesNow = require('scripts.ossc.ossc_cast_rules')
        if k:find('start', 1, true) or k:find('attach', 1, true) then
            castRulesNow.noteDraw(Stance.drawTracker, groupname)
        elseif k:find('stop', 1, true) or k:find('detach', 1, true) then
            castRulesNow.clearDraw(Stance.drawTracker, groupname)
        end
    end
    for _, g in ipairs(Anim.HEAVY_ATTACK_GROUPS) do
        I.AnimationController.addTextKeyHandler(g, trackWeaponDraw)
    end

    local hitDeathGroups = {
        'hit1','hit2','hit3','hit4','hit5',
        'death1','death2','death3','death4','death5',
        'swimhit','swimdeath1',
    }
    for _, g in ipairs(hitDeathGroups) do
        I.AnimationController.addTextKeyHandler(g, onHitDeathTextKey)
    end

    I.AnimationController.addTextKeyHandler('egidle2', onegidle2TextKey)

    -- ── Native Spell Stance VFX Suppression ──
    -- Cancel native 'spell'/'spellcast' equip at 'equip start' (hand VFX). Only with SuppressSpellStance on.
    local function suppressStanceVfx(groupname, key)
        -- The quick-key window below also covers the engine's re-raise.
        if not (Cfg.general and Cfg.general:get('SuppressSpellStance') == true) then return end
        if Cast.isCasting
            and (Stance.spellStanceAllowed or not Stance.quickkeyWindowActive()) then
            return
        end
        if tostring(key):lower() == 'equip start' then
            anim.cancel(self, groupname)
            debugLog("[OSSC Stance] Suppressed native " .. groupname .. " VFX on equip start")
        end
    end
    I.AnimationController.addTextKeyHandler('spell', suppressStanceVfx)
    I.AnimationController.addTextKeyHandler('spellcast', suppressStanceVfx)
else
    debugLog("AnimationController interface not available.")
end

debugLog("--- OSSC PLAYER SCRIPT INITIALIZED ---")

local function onSave()
    reconcileShieldWeapon()
    local hiddenShield = Cast.suppressedShield
    restoreShieldAfterCast()
    return {
        hiddenShield = hiddenShield,
        powerCooldowns = OSSC_PowerCooldowns,
        pmmLocations = PMM.pmmLocations,
        -- Save-game key names, read back in onLoad; they are not field paths.
        weaponAttackLockActive = Cast.weaponAttackLockActive,
        combatBlockActive      = Cast.combatBlockActive,
    }
end

local function onLoad(data)
    restoreShieldAfterCast()
    local hiddenShield = data and data.hiddenShield
    if hiddenShield and hiddenShield:isValid() then
        local eq = types.Actor.getEquipment(self)
        if not eq[SLOT.CarriedLeft] then
            eq[SLOT.CarriedLeft] = hiddenShield
            types.Actor.setEquipment(self, eq)
        end
    end
    -- External NGarde control is transient engine state and must never survive
    -- loading a save made during a quickcast.
    setNgardeParryControl(false)
    -- Moving-target lead samples are transient too: drop anything tracked
    -- before the save so a cast in the first second after a load can never
    -- estimate a velocity from pre-save positions.
    targetLead.reset()
    if data and data.powerCooldowns then OSSC_PowerCooldowns = data.powerCooldowns end
    if data and type(data.pmmLocations) == 'table' then PMM.pmmLocations = data.pmmLocations end
    -- The Fighting control switch / combat-control override are engine state
    -- that can survive a save load inside the same session: if the save was
    -- made while one of OSSC's mid-cast locks was engaged, release it
    -- explicitly so attacking is never stuck disabled after the load.
    if Cast.weaponAttackLockActive or (data and data.weaponAttackLockActive) then
        Cast.weaponAttackLockActive = false
        setWeaponAttackLock(false)
    end
    if Cast.combatBlockActive or (data and data.combatBlockActive) then
        Cast.combatBlockActive = false
        setCombatBlock(false)
    end
    -- Refresh cached settings on load
    Cfg.general    = storage.playerSection('SettingsOSSC_General')
    Cfg.keys       = storage.playerSection('SettingsOSSC_Keys')
    Cfg.anim       = storage.playerSection('SettingsOSSC_Animations')
    Cfg.animSpeed  = storage.playerSection('SettingsOSSC_AnimSpeeds')
    Cfg.pmm        = storage.playerSection('SettingsPureMultiMark')
    Cfg.magExp     = storage.playerSection('SettingsMagExp_General')
    Cfg.qsKeyboard = storage.playerSection('SettingsQuickSelectKeyboard')
    Cfg.qs         = storage.playerSection('SettingsQuickSelect')
    Cfg.debugMode  = Cfg.general and Cfg.general:get('DebugMode') or false

    -- Initialise the change-detection baseline to the CURRENT selection /
    -- stance / equipment rather than nothing. This makes change detection
    -- accurate on the very first hotkey press: an equip-only slot leaves the
    -- spell unchanged while the equipment-change guard catches it.
    updatePrevFrameStore()
    QuickkeyPress.prevSpellRecordId = Stance.prevFrameSpell
    QuickkeyPress.prevItemRecordId  = Stance.prevFrameItem
    lastSpellHotkeySlot = nil
    -- Native stance/equipment transitions are transient and must not survive
    -- a save load. Start the next quick-key from a fresh suppression window.
    clearQuickkeyStanceSuppression()
    -- No slot has cast an enchanted item in this session yet; require an
    -- actual magic activation (change / spell stance) before the first cast.
    QuickkeyPress.lastMagicItemSlot = nil
    debugLog("onLoad — QuickKey tracking initialised from current selection: spell="
        ..tostring(QuickkeyPress.prevSpellRecordId).." item="..tostring(QuickkeyPress.prevItemRecordId))
end

--- item and spell in these opts are ids, because we can't serialize full game objects to pass to events
local function OSSC_QuickCast_Handler(opts)
    if not opts then
        triggerQuickCast()
        return
    end

    -- Resolve an item record id through the player's actual inventory. A
    -- stale or foreign id must not fall through to triggerQuickCast as if it
    -- were an item object.
    if type(opts.item) == 'userdata'
        or (type(opts.item) == 'table' and type(opts.item.isValid) == 'function') then
        if not opts.item:isValid() then return end
    elseif opts.item then
        local id = opts.item
        if type(id) ~= 'string' then return end
        local inventory = types.Actor.inventory(self)
        local items = inventory and inventory:getAll() or {}
        local found
        for _, item in ipairs(items) do
            if item.id == id and item:isValid() then
                found = item
                break
            end
        end
        if not found then
            debugLog("OSSC_QuickCast: item " .. tostring(id) .. " not in inventory")
            return
        end
        opts.item = found
        --get spell by id
    elseif opts.spell then
        local spell = spellRecs[opts.spell]
        if spell then
            opts.spell = spell
        end
    end

    triggerQuickCast(opts)
end

local function onFrame(dt)
    reconcileShieldWeapon()
    -- castRenderingRay is only legal here (onFrame); must run before the early return.
    refreshLookRay()

    local isQuickkeysOn  = (Cfg.general and Cfg.general:get('CastOnQuickkeys') == true)
    local isStanceBlockOn = (Cfg.general and Cfg.general:get('SuppressSpellStance') == true)
    if not (isQuickkeysOn or isStanceBlockOn) then
        -- Keep the baseline fresh while disabled.
        updatePrevFrameStore()
        return
    end

    local currentStance = types.Actor.getStance(self)

    -- ── Manual stance keys (R / spell, F / weapon) ──
    -- The native toggle runs before Lua: take intent from Stance.prevStance, never currentStance.
    -- Only maintain spellStanceAllowed; raise explicitly only if ENTER produced no toggle.
    do
        local spellKeyDown  = false
        local weaponKeyDown = false
        if input.isActionPressed and input.ACTION then
            local actEnum = input.ACTION.ToggleSpell or input.ACTION.Spell or input.ACTION.SpellReady
            if actEnum and input.isActionPressed(actEnum) then
                spellKeyDown = true
            end
            local wa = input.ACTION.ToggleWeapon or input.ACTION.Weapon or input.ACTION.WeaponReady
            if wa and input.isActionPressed(wa) then
                weaponKeyDown = true
            end
        end

        -- Ignore edges while a menu is open, but keep tracking key state.
        local uiMode = ui and ui.activeMode
        if not uiMode and I.UI and I.UI.getMode then uiMode = I.UI.getMode() end
        if uiMode == nil then
            -- Spell key edge: was Spell → EXIT, else ENTER.
            if spellKeyDown and not Stance.prevSpellKeyDown then
                if Stance.prevStance == STANCE.Spell then
                    Stance.spellStanceAllowed = false
                    debugLog("[OSSC Stance] User pressed Spell stance key to exit spell stance")
                    -- No setStance: the engine already left; setting it would double-toggle.
                else
                    -- ENTER always allowed; the blockade only owns quickkey-raised stances.
                    Stance.spellStanceAllowed = true
                    debugLog("[OSSC Stance] User pressed Spell stance key to enter spell stance")
                    if currentStance ~= STANCE.Spell then
                        types.Actor.setStance(self, STANCE.Spell)
                    end
                end
            end

            -- Weapon key edge: drop the spell allowance (engine switches the stance).
            if weaponKeyDown and not Stance.prevWeaponKeyDown then
                Stance.spellStanceAllowed = false
                debugLog("[OSSC Stance] Weapon key pressed — clearing spellStanceAllowed")
            end
        end

        -- Clear the allowance whenever the LIVE stance is non-Spell, even in menus and whatever the key state.
        local liveStance = types.Actor.getStance(self)
        if liveStance ~= STANCE.Spell then
            Stance.spellStanceAllowed = false
        end

        Stance.prevSpellKeyDown  = spellKeyDown
        Stance.prevWeaponKeyDown = weaponKeyDown
        -- prevStance must reflect the ENTER branch (only stance writer here).
        Stance.prevStance = liveStance
    end

    -- ── QuickKey pending cast ────────────────────────────────────────────────
    if QuickkeyPress.slot ~= nil then
        -- Magic/MagicItem quickkeys enter Spell stance, Item ones don't; capture before suppression reverts.
        if not QuickkeyPress.startedInSpellStance
            and currentStance == STANCE.Spell then
            QuickkeyPress.sawSpellStance = true
            debugLog("[OSSC Hotkey] Quickkey activated Spell stance — magic hotkey confirmed")
        end

        QuickkeyPress.timer = QuickkeyPress.timer - dt

        if QuickkeyPress.timer <= 0 then
            local slotIndex       = QuickkeyPress.slot
            local sawSpellStance  = QuickkeyPress.sawSpellStance
            -- Restore the exact stance that existed before the native quickkey
            -- ran. The engine applies Magic/MagicItem quickkeys first, which
            -- can sheath a drawn weapon before OSSC sees the press. Using
            -- lastNonSpellStance here is racy: the late Spell raise can cross
            -- onFrame/onUpdate and leave that cache stale or already changed.
            -- The previous-frame baseline is authoritative for this press.
            local prePressStance  = QuickkeyPress.prePressStance
            local wasRowSwitch    = QuickkeyPress.pendingPageSwitch
            local blockedByCooldown = QuickkeyPress.blockedByCooldown
            local equipmentAtPress = QuickkeyPress.pendingEquipment
            local pressTime       = QuickkeyPress.pendingPressTime

            QuickkeyPress.slot                  = nil
            QuickkeyPress.timer                 = 0
            QuickkeyPress.startedInSpellStance  = false
            QuickkeyPress.prePressStance        = nil
            QuickkeyPress.sawSpellStance        = false
            QuickkeyPress.blockedByCooldown    = false
            QuickkeyPress.pendingPageSwitch           = false
            QuickkeyPress.pendingEquipment            = nil
            QuickkeyPress.pendingPressTime            = 0

            local function revertQuickkeySpellStance()
                -- A cast started from the stance keeps it (opt-in setting); the
                -- cast owns the posture until it ends.
                if allowCastInSpellStance() and Cast.isCasting then return end
                if not Stance.spellStanceAllowed and isStanceBlockOn then
                    local stance = types.Actor.getStance(self)
                    if stance == STANCE.Spell then
                        debugLog("[OSSC Stance] Reverting automatic QuickKey spell stance")
                        -- A spam press during its own cast uses the cast's pre-press stance (see quickkeyRevertTarget).
                        local targetStance = Stance.quickkeyRevertTarget()
                        types.Actor.setStance(
                            self,
                            targetStance
                        )
                        Stance.suppressWeaponTransitionSounds()
                        restoreQuickkeyWeaponIfEmpty()
                        -- Returns early below; refresh prevStance now.
                        Stance.prevStance = targetStance
                    end
                end
            end

            -- Resolve what OpenMW selected after processing the key.
            local selectedSpell = types.Actor.getSelectedSpell(self)
            local selectedEnchantedItem = types.Actor.getSelectedEnchantedItem(self)

            local currentSpellRecordId = nil
            local validSpell = false

            if selectedSpell and selectedSpell.id then
                currentSpellRecordId = selectedSpell.id
                validSpell = spellRecs[currentSpellRecordId] ~= nil
            end

            local currentItemRecordId = nil
            local selectedItemSpell   = nil
            local validMagicItem      = false

            if selectedEnchantedItem
                and selectedEnchantedItem:isValid() then
                local rec = getItemRecord(selectedEnchantedItem)

                if rec and rec.id then
                    currentItemRecordId = rec.id:lower()
                end

                selectedItemSpell =
                    resolveEnchantedItemSpell(selectedEnchantedItem)
                validMagicItem = selectedItemSpell ~= nil
            end

            -- Directional: magic became selected; clearing it doesn't authorize a cast.
            local spellBecameSelected =
                validSpell
                and currentSpellRecordId
                    ~= QuickkeyPress.prevSpellRecordId

            local magicItemBecameSelected =
                validMagicItem
                and currentItemRecordId
                    ~= QuickkeyPress.prevItemRecordId

            -- Eligibility is based on actual magic-hotkey activity:
            --
            --   enchanted Item hotkey (magic item equipped):
            --       validMagicItem is true (the item resolves to a CastOnUse/
            --       CastOnce enchantment). For enchanted items the "spell id" is
            --       the enchantment id, while OpenMW may still report the
            --       previously equipped normal spell as selected, and a recast
            --       changes neither id — so change-based detection alone would
            --       wrongly reject a recast.
            --
            --       BUT OpenMW leaves the selected enchanted item SET after a
            --       cast: a normal (non-magic) Item quickkey never clears it and
            --       does not raise Spell stance either (unlike Magic / MagicItem
            --       quickkeys, which call setDrawState(Spell); see the engine's
            --       QuickKeysMenu::activateQuickKey). Treating the mere presence
            --       of a valid magic item as activation would therefore make ANY
            --       subsequent item hotkey (equipment, potion, hand-to-hand,
            --       unassigned, ...) recast the previous enchantment. A recast is
            --       intended solely from the SAME hotkey that activated the item
            --       — just like ordinary spells only recast from their own
            --       hotkey — so gate the persistent-item (no-change) case on the
            --       slot that last cast an enchanted item.
            --
            --   Magic spell hotkey:
            --       raises Spell stance and/or changes the selected spell id
            --       (the engine also clears the selected enchanted item).
            --
            --   Magic spell hotkey pressed again with NOTHING changing:
            --       a repeat press can carry no signal at all — when the
            --       player is already standing in the native Spell stance the
            --       engine re-applying the quickkey re-selects the same spell
            --       and does not raise the stance again (SuppressSpellStance
            --       off), and when OSSC's suppression is on the second press
            --       may land after the first raise was already reverted but
            --       the engine delivers no fresh raise of its own. The press
            --       then looks exactly like a plain non-magic hotkey. A recast
            --       is intended from the SAME hotkey that cast the spell — the
            --       same rule the enchanted-item path uses — so the
            --       no-change case is gated on the slot that last cast an
            --       ordinary spell (spellRecast below).
            --
            --   MagicItem hotkey that changed items:
            --       magicItemBecameSelected is true → cast regardless of slot.
            --
            --   normal (non-magic) Item/equip / HandToHand / unassigned hotkey:
            --       spell stance was not raised, no magic id changed, and the
            --       slot is neither the last spell slot nor the last magic-item
            --       slot → no cast.
            --
            -- A paged hotbar mod (QuickSelect Ultimate) maps the physical 1-9
            -- keys onto rows of 10 slots, so the physical key alone says nothing
            -- about WHICH slot was pressed: the same key is a different slot on
            -- another row, and <modifier>+N switches the row without touching
            -- anything at all. Prefer the slot the hotbar mod reports (nil = the
            -- press activated nothing), and never let the no-change re-cast fire
            -- for a row switch or for a press that equipped something else.
            local effectiveSlot = slotIndex
            if QuickkeyPress.hotbarSlotOverrideTime > 0
                and math.abs(QuickkeyPress.hotbarSlotOverrideTime - pressTime)
                    < QuickkeyPress.hotbarSlotMatchWindow then
                effectiveSlot = QuickkeyPress.hotbarSlotOverride
            end
            local equipmentChanged = equipmentChangedSince(equipmentAtPress)

            local magicItemRecast =
                validMagicItem
                and not magicItemBecameSelected
                and effectiveSlot ~= nil
                and effectiveSlot == QuickkeyPress.lastMagicItemSlot
                and not wasRowSwitch
                and not equipmentChanged

            local spellRecast =
                validSpell
                and not spellBecameSelected
                and not validMagicItem
                and effectiveSlot ~= nil
                and effectiveSlot == lastSpellHotkeySlot
                and not wasRowSwitch
                and not equipmentChanged

            -- A hotbar mod's explicit "this press activated a magic tile"
            -- signal (see notifyMagicTileActivation). This is the ONLY signal
            -- a reselect carries: pressing the tile of the already-selected
            -- spell/item changes nothing observable (same selection, no fresh
            -- stance raise, no equipment change), so change/spell-stance/
            -- recast-marker detection all come back empty — and on a fresh
            -- load the recast markers are not set yet either. Without this
            -- the first press of the equipped spell's own hotkey is wrongly
            -- refused as a plain item hotkey until another spell is selected
            -- and switched back. The slot must match the press (same window
            -- as the slot override — both are sent for the same key press),
            -- and the cast branches below still require the magic to be
            -- actually selected, so a stale signal can never cast thin air.
            local sawMagicTile =
                Cast.hotbarMagicActivation ~= nil
                and Cast.hotbarMagicActivation.slot == effectiveSlot
                and math.abs(Cast.hotbarMagicActivation.time - pressTime)
                    < QuickkeyPress.hotbarSlotMatchWindow

            if blockedByCooldown then
                debugLog("[OSSC Hotkey] QuickKey slot " .. tostring(slotIndex)
                    .. " ignored — quickcast cooldown active.")
                revertQuickkeySpellStance()
                updatePrevFrameStore()
                return
            end

            local magicHotkeyActivated =
                magicItemRecast
                or magicItemBecameSelected
                or spellRecast
                or sawSpellStance
                or spellBecameSelected
                or sawMagicTile

            debugLog(string.format(
                "[OSSC Hotkey] Intent: slot=%s magic=%s itemRecast=%s "
                    .. "spellRecast=%s stanceRaised=%s magicTile=%s "
                    .. "spellSelected=%s magicItemSelected=%s lastItemSlot=%s "
                    .. "lastSpellSlot=%s rowSwitch=%s equipChanged=%s "
                    .. "effectiveSlot=%s "
                    .. "(spell=%s prevSpell=%s item=%s prevItem=%s)",
                tostring(slotIndex),
                tostring(magicHotkeyActivated),
                tostring(magicItemRecast),
                tostring(spellRecast),
                tostring(sawSpellStance),
                tostring(sawMagicTile),
                tostring(spellBecameSelected),
                tostring(magicItemBecameSelected),
                tostring(QuickkeyPress.lastMagicItemSlot),
                tostring(lastSpellHotkeySlot),
                tostring(wasRowSwitch),
                tostring(equipmentChanged),
                tostring(effectiveSlot),
                tostring(currentSpellRecordId),
                tostring(QuickkeyPress.prevSpellRecordId),
                tostring(currentItemRecordId),
                tostring(QuickkeyPress.prevItemRecordId)
            ))

            -- Arm stance suppression before either the no-cast return or the
            -- OSSC cast path.  The native quick-key has already run, so this
            -- is also the point at which we can safely capture the fact that
            -- this was a magic press rather than a plain weapon/item hotkey.
            if magicHotkeyActivated and isStanceBlockOn then
                activateQuickkeyStanceSuppression()
            end

            if not magicHotkeyActivated or not isQuickkeysOn then
                if not isQuickkeysOn then
                    debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                        .. " — magic hotkey confirmed, but CastOnQuickkeys "
                        .. "is off; no cast.")
                else
                    debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                        .. (wasRowSwitch
                            and " — hotbar row switch; no cast."
                            or equipmentChanged
                            and " — equipment changed (plain item hotkey); no cast."
                            or " — normal Item/equip hotkey; no cast."))
                end

                revertQuickkeySpellStance()
                updatePrevFrameStore()
                return
            end

            -- Real (row*10+n) slot with a paged hotbar.
            local activatedSlot = effectiveSlot or slotIndex

            -- Enchanted items take precedence over the selected spell.
            if validMagicItem then
                local enchantmentType = selectedItemSpell.type
                local enchantmentTypes = ENCHTYPE

                -- Only manually castable enchantments (not CastOnStrike / ConstantEffect).
                local manuallyCastable =
                    enchantmentType == enchantmentTypes.CastOnUse
                    or enchantmentType == enchantmentTypes.CastOnce

                if not manuallyCastable then
                    debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                        .. " — selected magic item is not CastOnUse/CastOnce "
                        .. "(type=" .. tostring(enchantmentType)
                        .. "); no cast.")

                    -- This slot cannot recast anything (CastOnStrike / Constant
                    -- Effect are equip/proc enchantments) — forget it so its
                    -- persistence cannot authorize a later recast. Its spell
                    -- marker too: pressing a slot that used to hold a spell but
                    -- now activates a non-castable enchantment must not re-cast
                    -- that old spell on a later press.
                    if QuickkeyPress.lastMagicItemSlot == activatedSlot then
                        QuickkeyPress.lastMagicItemSlot = nil
                    end
                    if lastSpellHotkeySlot == activatedSlot then
                        lastSpellHotkeySlot = nil
                    end

                    revertQuickkeySpellStance()
                    updatePrevFrameStore()
                    return
                end

                debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                    .. " — MagicItem hotkey confirmed; casting item "
                    .. tostring(currentItemRecordId))

                -- Record the slot that cast this enchanted item. Only a repeat
                -- press of THIS slot is allowed to recast it; any other item
                -- hotkey pressing must fall through as a normal equip hotkey.
                -- The spell marker is deliberately NOT cleared: OpenMW keeps
                -- reporting the previously equipped normal spell as selected
                -- while the item is selected, so pressing that spell's own slot
                -- again (which re-selects the spell) can still re-cast it via
                -- lastSpellHotkeySlot.
                QuickkeyPress.lastMagicItemSlot = activatedSlot

                local castIdBefore = Cast.currentCastId
                Stance.beginQuickkeyCastAttempt()
                triggerQuickCast({
                    item           = selectedEnchantedItem,
                    ignoreUIMode   = true,
                    strictOnlyItem = true,
                    castSource     = 'quickkey',
                })
                if Cast.currentCastId ~= castIdBefore then
                    QuickkeyPress.cooldownActive = true
                    -- Real cast: animUnlock restores the pre-press stance.
                    Stance.postCastRestore = prePressStance
                end

            elseif validSpell then
                debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                    .. " — Magic spell hotkey confirmed; casting "
                    .. tostring(currentSpellRecordId))

                -- A normal spell is now the selected magic (the engine also
                -- clears the selected enchanted item), so no slot holds an
                -- enchantment to recast.
                QuickkeyPress.lastMagicItemSlot = nil

                -- Record the slot that cast this spell. Only a repeat press of
                -- THIS slot — with the same spell still selected and no other
                -- magic signal — is allowed to re-cast it (see spellRecast).
                lastSpellHotkeySlot = activatedSlot

                local castIdBefore = Cast.currentCastId
                Stance.beginQuickkeyCastAttempt()
                triggerQuickCast({
                    spell           = currentSpellRecordId,
                    ignoreUIMode    = true,
                    strictOnlySpell = true,
                    castSource      = 'quickkey',
                })
                if Cast.currentCastId ~= castIdBefore then
                    QuickkeyPress.cooldownActive = true
                    -- Real cast: animUnlock restores the pre-press stance.
                    Stance.postCastRestore = prePressStance
                end

            else
                debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                    .. " — magic activation detected, but no valid magic selected.")

                -- Slot's magic is gone: forget its markers.
                if lastSpellHotkeySlot == activatedSlot then
                    lastSpellHotkeySlot = nil
                end
                if QuickkeyPress.lastMagicItemSlot == activatedSlot then
                    QuickkeyPress.lastMagicItemSlot = nil
                end
            end

            revertQuickkeySpellStance()
            updatePrevFrameStore()
            return
        end
    end

    -- No general Spell-stance suppression here: the blockade is quickkey-only.

    -- Silence equip sounds while the window is active.
    if Stance.nativeQuickkeySuppression and not Stance.spellStanceAllowed then
        Stance.suppressWeaponTransitionSounds()
    end

    -- Keep track of last non-spell stance
    if currentStance == STANCE.Weapon or currentStance == STANCE.Nothing then
        Stance.lastNonSpellStance = currentStance
    end
    updatePrevFrameStore()
end

-- ── I.OSSC: on-demand cast + spell filter ─────────────────────────────────
-- The player half of the API described in ossc_global.lua.  A mod can either
-- call these through I.OSSC (the player script's interface) or through
-- I.OSSC_Casters (the global one, which also serves NPCs and creatures).
--
--   I.OSSC.castSpellAtTarget({ spellId = 'x', target = actorOrPosition })
--
-- A cast ordered this way costs magicka and pays the player's quick-cast
-- effect penalty exactly like a hotkey quick cast, but it does not play the
-- cast animation: it is a *cast request*, for mods that drive their own cast
-- sequence (an animation, a dialogue, a scripted event) and only want OSSC to
-- launch the spell.  `isFree` follows the same meaning as in OSSC's own launch
-- path: nil (default) = OSSC pays the cost here and tells Spell Framework Plus
-- the launch is prepaid, true = the caller already paid, false = leave the
-- charge to Spell Framework Plus' launch-time resource guard.
local EXTERNAL_CAST_AIM_OFFSET = util.vector3(0, 0, 60)

local ignoredSpellMirror = {}
local ignoredSpellMirrorAsked = false

-- The mirror is only a fallback: normally I.OSSC_Casters answers directly.  It
-- still gets filled (the global script pushes the list to the player whenever
-- it changes), and asks for the current list the first time it is consulted.
local function askForIgnoredSpells()
    if ignoredSpellMirrorAsked then return end
    ignoredSpellMirrorAsked = true
    core.sendGlobalEvent('OSSC_RequestIgnoredSpells', { actor = self })
end

local function isSpellIgnored(spellId)
    if I.OSSC_Casters and type(I.OSSC_Casters.isSpellIgnored) == 'function' then
        return I.OSSC_Casters.isSpellIgnored(spellId)
    end
    if type(spellId) ~= 'string' or spellId == '' then return false end
    askForIgnoredSpells()
    return ignoredSpellMirror[spellId:lower()] == true
end

local function setSpellIgnored(spellId, ignored)
    if type(spellId) ~= 'string' or spellId == '' then
        return false, 'spellId must be a record id string'
    end
    local wanted = ignored ~= false
    ignoredSpellMirror[spellId:lower()] = wanted or nil
    if I.OSSC_Casters and type(I.OSSC_Casters.setSpellIgnored) == 'function' then
        return I.OSSC_Casters.setSpellIgnored(spellId, wanted)
    end
    -- No global counterpart (older OSSC, or the global script failed to load):
    -- keep the veto local so at least the player's own picking honours it.
    core.sendGlobalEvent('OSSC_SetSpellIgnored', { spellId = spellId, ignored = wanted })
    return false, 'the OSSC global script is not installed'
end

local function resolveCastTarget(target)
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
    local record = spellRecs[spellId]
    if not record then
        return false, 'unknown spell record: ' .. tostring(spellId)
    end
    if self and self.isValid and not self:isValid() then
        return false, 'the player object is not valid'
    end
    if types.Actor.isDead(self) then return false, 'the player is dead' end
    if Cast.isCasting then return false, 'a cast is already in progress' end

    local targetObj, targetPos = resolveCastTarget(args.target)
    if args.target ~= nil and targetObj == nil and targetPos == nil then
        return false, 'target must be an actor, an object or a util.vector3'
    end

    -- Same shape as the quick-cast model for shared helpers.
    local firstEffect = record.effects and record.effects[1]
    local spell = {
        id      = spellId,
        type    = record.type,
        cost    = record.cost or 0,
        effects = record.effects,
        -- The blast radius a launch reports is the largest area among the
        -- record's TARGET-range effects (`ossc_cast_rules.impactArea`), the
        -- same rule the quick-cast path uses. `firstEffect.area` was wrong for
        -- every spell whose first effect is not the exploding one -- the usual
        -- layout, e.g. a Self rider in front of a Target blast -- and those
        -- casts were handed to Spell Framework Plus with `area = 0`, i.e. no
        -- explosion at all.
        area    = require('scripts.ossc.ossc_cast_rules').impactArea(record),
        range   = firstEffect and firstEffect.range or RANGE.Self,
    }

    -- Mod cast veto: an external request is still a cast this player makes, so
    -- a mod's own rule applies to it too (and it must, or a mod could be talked
    -- past its own restriction by routing the cast through castSpellAtTarget).
    if castRulesModule.hasCastVeto() then
        local payload = castRulesModule.castPayload(spell, {
            source = 'external', caster = self,
        })
        local vetoAllowed, vetoReason, vetoMessage =
            castRulesModule.checkCastVeto(payload)
        if not vetoAllowed then
            return castRulesModule.reportVetoedCast(self, payload, vetoReason,
                vetoMessage, {
                    log         = debugLog,
                    showMessage = ui.showMessage,
                    fizzle      = Cfg.general
                        and Cfg.general:get('CastVetoFeedback') ~= 'Silent',
                })
        end
    end

    local startPos = self.position
    local direction = self.rotation * util.vector3(0, 1, 0)
    local hitObject, hitPos = nil, nil
    if spell.range == RANGE.Self then
        targetObj, targetPos = self, self.position
        hitObject, hitPos = self, self.position
    elseif targetPos then
        -- Vanilla parity (CastSpell::launchMagicBolt): the aim point on an
        -- actor is the centre of its bounding box, never a fixed height above
        -- its feet — that is what makes the bolt (and the hit effect spawned
        -- at the impact) land on the actor instead of at them.
        local aim = require('scripts.ossc.ossc_cast_rules').actorAimPoint(targetObj, EXTERNAL_CAST_AIM_OFFSET.z)
            or (targetPos + EXTERNAL_CAST_AIM_OFFSET)
        direction = (aim - startPos):normalize()
        hitPos = aim
        if spell.range == RANGE.Touch then hitObject = targetObj end
    end

    local wePay = args.isFree == nil
    local payloadIsFree = args.isFree ~= false
    local cost = spell.cost or 0
    if wePay and cost > 0 then
        local magicka = types.Actor.stats.dynamic.magicka(self)
        if magicka.current < cost then return false, 'not enough magicka' end
        magicka.current = math.max(0, magicka.current - cost)
    end

    local effectScale = tonumber(args.effectScale)
    if not effectScale then
        local effectMode = Cfg.general and Cfg.general:get('QuickCastEffectPenalty')
        if effectPenaltyExempt(spell) then
            effectScale = 1.0
        elseif Penalty.isSkillBased(effectMode) then
            effectScale = Penalty.skillScale(
                getMagicSkillValue(self, getDominantSkillSchool(spell) or 'destruction', false))
        else
            effectScale = getPenaltyScale(effectMode)
        end
    end

    local showAll = true
    if Cfg.magExp then
        local val = Cfg.magExp:get('ShowAllCastVfx')
        if val ~= nil then showAll = val end
    end
    if args.showAllCastVfx ~= nil then showAll = args.showAllCastVfx end

    local userData = { OSSC = true, External = true }
    if type(args.userData) == 'table' then
        for key, value in pairs(args.userData) do userData[key] = value end
    end

    debugLog(string.format(
        "External CastRequest: spell=%s target=%s effectScale=%.2f prepaid=%s",
        spellId, hitObject and tostring(hitObject.recordId) or 'position',
        effectScale, tostring(payloadIsFree)))
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
        isGodMode      = debug.isGodMode(),
        effectScale    = effectScale,
        showAllCastVfx = showAll,
        userData       = userData,
    })
    return true
end

local OSSC_EventHandlers = {}

--- Stop the cast in flight, on another mod's request (Sane Magic's
--- `dropSpell`, a dialogue that must interrupt a cast, …). Everything the cast
--- started is torn down and NOTHING is launched: a cast whose release has not
--- happened yet never fires, and a release already queued for this cast is
--- dropped. Magicka already paid at the animation start stays paid, exactly as
--- vanilla handles an interrupted cast.
--- Returns true when a cast was actually stopped.
local function cancelCurrentCast(reason)
    if not Cast.isCasting and #Cast.pendingLaunches == 0 then
        debugLog('Cancel request ignored — nothing is being cast')
        return false
    end
    local label = 'cancelled by a mod: ' .. tostring(reason or 'no reason given')
    debugLog('Cast ' .. label)
    fullCleanup(label)
    return true
end

return {
    engineHandlers = { onUpdate=onUpdate, onFrame=onFrame, onSave=onSave, onLoad=onLoad },
    interfaceName = 'OSSC',
    interface = {
        triggerQuickCast = triggerQuickCast,
        isCasting = function() return Cast.isCasting end,
        -- v2: awardSkillProgress takes vanilla skill-use points, not level fractions.
        -- v3: addCastVeto / removeCastVeto / cancelCurrentCast.
        version = 3,

        --- Cast a spell right now, without the quick-cast animation (see the
        --- block above).  Returns true when the request was handed to Spell
        --- Framework Plus, or false plus a reason when it was refused.
        castSpellAtTarget = castSpellAtTarget,

        --- Settings read-out for player-context mods: the distance (game
        --- units) at or below which an NPC/creature's quick-cast probability
        --- is at its maximum — the "100% chance distance" of the NPC settings
        --- (`NPCQuickCastMinDistance`, default 500).  Same read-out as
        --- I.OSSC_Casters.getQuickCastFullChanceDistance(), taken straight
        --- from the authoritative player-settings storage, so a menu change
        --- is visible immediately.
        getQuickCastFullChanceDistance = function()
            -- Same clamp the actor scripts apply: the menu allows a Full Chance
            -- Distance larger than the Maximum Cast Distance, and the roll then
            -- uses the Maximum as the end of the full-chance band. The raw
            -- setting would make this read-out disagree with the casters.
            local minDist = tonumber(Cfg.npc and Cfg.npc:get('NPCQuickCastMinDistance')) or 500
            local maxDist = tonumber(Cfg.npc and Cfg.npc:get('NPCQuickCastMaxDistance')) or 700
            if minDist > maxDist then minDist = maxDist end
            return minDist
        end,

        --- Every NPC/creature quick-cast setting (the SettingsOSSC_NPC
        --- group) as a live snapshot table — the same read-out as
        --- I.OSSC_Casters.getNPCSettings(), taken straight from the
        --- authoritative player-settings storage.  Unset keys answer with
        --- their registered defaults; the result is a fresh copy, safe to
        --- keep or mutate.  See the README's modder-API section for the key
        --- list.
        getNPCSettings = function()
            return casterUtils.readNPCSettings(Cfg.npc)
        end,

        --- Spell filter (the authoritative copy lives in the global script, so
        --- every caster sees the same vetoes).
        ignoreSpell      = function(spellId) return setSpellIgnored(spellId, true) end,
        unignoreSpell    = function(spellId) return setSpellIgnored(spellId, false) end,
        setSpellIgnored  = setSpellIgnored,
        isSpellIgnored   = isSpellIgnored,

        --- Award skill experience to the player, whatever the Skill
        --- Progression Mode setting says.  See awardSkillProgress above; this
        --- is the hook a mod uses after setting the mode to 'none'.
        awardSkillProgress = awardSkillProgress,
        addCastHandler = function(handler)
            table.insert(OSSC_EventHandlers, handler)
        end,

        --- ── Cast veto: the way to REFUSE an OSSC cast ─────────────────────
        --- `addCastHandler` above runs after the cast has been handed to Spell
        --- Framework Plus, so it can only report. A veto runs before anything
        --- is played or paid and can refuse: spells, scrolls and enchanted
        --- items, from hotkeys, quickkeys, hotbar tiles and
        --- `castSpellAtTarget`. Registering/deregistering is global across the
        --- player script and the NPC/creature casters, so one call covers
        --- every caster (an NPC's own veto can look at `cast.caster`).
        ---
        ---     local token = I.OSSC.addCastVeto(function(cast)
        ---         if not I.SaneMagic.checkEffects(cast.effects, cast.isScroll,
        ---                                        cast.cost) then
        ---             return false, 'skill too low', 'Your skill is too low.'
        ---         end
        ---         return true
        ---     end)
        ---     I.OSSC.removeCastVeto(token)
        ---
        --- Returns a token, or nil plus a reason when it is not a function.
        addCastVeto    = castRulesModule.addCastVeto,
        removeCastVeto = castRulesModule.removeCastVeto,
        hasCastVeto    = castRulesModule.hasCastVeto,

        --- Stop the cast in flight (nothing is launched). True when there was
        --- one. Sane Magic's `OSSC_CancelCast` global event is also honoured.
        cancelCurrentCast = cancelCurrentCast,

        -- ── Paged hotbar mod integration (QuickSelect Ultimate & co.) ──────
        -- Hotbar mods that reuse the QuickKey1-9 input actions can tell OSSC
        -- what a press really did. Without this, a press that only switches
        -- the visible hotbar row (or activates an empty slot) looks exactly
        -- like "cast the magic of the slot pressed last" and OSSC re-casts
        -- the previously used enchanted item.
        --
        -- cancelPendingQuickkey(slot?)
        --   The press was NOT a cast request — drop the pending cast. The
        --   veto is also remembered for a short window so it works no matter
        --   which mod's input handler the engine runs first.
        cancelPendingQuickkey = function(slot)
            QuickkeyPress.vetoUntil = realTimeNow() + QuickkeyPress.vetoWindow
            if slot ~= nil and QuickkeyPress.slot ~= nil
                and QuickkeyPress.slot ~= slot then
                return
            end
            if QuickkeyPress.slot == nil then return end
            debugLog("[OSSC Hotkey] Pending QuickKey "
                .. tostring(QuickkeyPress.slot)
                .. " cancelled by a hotbar mod (press was not a cast request)")
            QuickkeyPress.slot                  = nil
            QuickkeyPress.timer                 = 0
            QuickkeyPress.startedInSpellStance  = false
            QuickkeyPress.prePressStance        = nil
            QuickkeyPress.sawSpellStance        = false
            QuickkeyPress.blockedByCooldown    = false
            QuickkeyPress.pendingPageSwitch           = false
            QuickkeyPress.pendingEquipment            = nil
            QuickkeyPress.pendingPressTime            = 0
        end,

        -- notifyQuickkeyActivation(slot)
        --   The press activated hotbar `slot` (the real slot number of a
        --   paged hotbar, e.g. row 2 key 3 = 13), or `nil` when it activated
        --   nothing at all. OSSC uses it to decide whether this press is a
        --   repeat of the slot that cast the current magic item.
        notifyQuickkeyActivation = function(slot)
            QuickkeyPress.hotbarSlotOverride     = slot
            QuickkeyPress.hotbarSlotOverrideTime = realTimeNow()
            debugLog("[OSSC Hotkey] Hotbar mod reported activated slot="
                .. tostring(slot))
        end,

        -- notifyMagicTileActivation(slot)
        --   The press activated hotbar `slot` and that slot holds a SPELL or
        --   an ENCHANTED ITEM — even when its magic was already selected, in
        --   which case the press changes nothing observable at all (same
        --   selection id, no fresh Spell-stance raise, no equipment change).
        --   Without this signal such a reselect is indistinguishable from an
        --   empty-slot press, so the very first hotkey press after a load —
        --   the equipped spell's own hotkey, with no recast markers set yet —
        --   would be refused as a plain item hotkey. The activation is only
        --   honoured for the press it was sent with (same time window as
        --   notifyQuickkeyActivation) and the magic must still be selected
        --   when the press resolves, so only genuine magic-tile presses cast.
        notifyMagicTileActivation = function(slot)
            Cast.hotbarMagicActivation = { slot = slot, time = realTimeNow() }
            debugLog("[OSSC Hotkey] Hotbar mod reported magic-tile activation slot="
                .. tostring(slot))
        end,
    },
    eventHandlers  = {
        OSSC_ExternalCastRequest = function(data)
            local accepted, reason = castSpellAtTarget(data)
            if not accepted then
                debugLog('External cast request refused: ' .. tostring(reason))
            end
        end,
        OSSC_OnSpellCast = function(data)
            for _, handler in ipairs(OSSC_EventHandlers) do
                handler(data)
            end
        end,

        -- Spell filter mirror pushed by the global script.
        OSSC_SetIgnoredSpells = function(data)
            if type(data) ~= 'table' then return end
            ignoredSpellMirror = {}
            for _, spellId in ipairs(data.ids or {}) do
                if type(spellId) == 'string' and spellId ~= '' then
                    ignoredSpellMirror[spellId:lower()] = true
                end
            end
            ignoredSpellMirrorAsked = true
        end,
        OSSC_QuickCast = OSSC_QuickCast_Handler,

        --- Global-event form of `cancelCurrentCast`, for another mod's global
        --- script: `core.sendGlobalEvent('OSSC_CancelCast', { reason = '…' })`.
        OSSC_CancelCast = function(data)
            cancelCurrentCast(type(data) == 'table' and data.reason or nil)
        end,

        -- While the PMM recall window waits for input, leaving Interface mode
        -- without picking a mark (Esc / another menu taking over) must not
        -- leak the window. Destroy the window and cancel the recall — with
        -- Pure Multi Mark Compatibility enabled the vanilla mark must not
        -- go through.
        UiModeChanged = function(data)
            if not PMM.isWaitingForPMMInput then return end
            -- Ignore transient/duplicate notifications while the requested
            -- Interface mode is still being entered. If the current mode really
            -- is not Interface after that, selectedMark(0) falls back to vanilla recall.
            local currentMode = nil
            if I.UI and I.UI.getMode then currentMode = I.UI.getMode() end
            if currentMode == 'Interface' then return end
            if PMM.pmmUiOpenedAt and core.getSimulationTime() - PMM.pmmUiOpenedAt < 0.25 then
                return
            end
            destroyPMMWindow()
            selectedMark(0)
        end,

        -- omw.music sends this on combat-target changes; forward to the global attachment manager.
        OMWMusicCombatTargetsChanged = function(data)
            if data and data.actor then
                core.sendGlobalEvent('OSSC_CombatTargetsChanged', data)
            end
        end,

        AddVfx      = function(data) anim.addVfx(self, data.model, data.options) end,
        RemoveVfx   = function(vId)  anim.removeVfx(self, vId) end,
        PlaySound3d = function(data) core.sound.playSound3d(data.sound, self) end,
        MagExp_Local_MagicHit = function(data)
            debugLog(string.format("Received MagicHit: %s", tostring(data)))
        end
    }
}