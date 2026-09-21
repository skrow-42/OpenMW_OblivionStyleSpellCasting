---@omw-context player
-- ── PureMultiMark UI compatibility: global exports ─────────────────────────
-- OSSC reuses Pure Multi Mark's recall window and rename dialog modules
-- (scripts/puremultimark/PMM_markWindow.lua, PMM_renameDialog.lua) via
-- `require`. Those modules were written to run inside PMM's own player
-- script, where the engine modules below are plain *globals*. `require`
-- executes a module in THIS script's global environment, so the modules the
-- PMM UI needs must be re-exported here. This block must stay ABOVE the
-- `local` declarations below: once a local of the same name exists, a bare
-- assignment writes to the local instead of the global environment, and the
-- PMM modules fail with "attempt to index global 'core' (a nil value)".
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
    magExp     = storage.playerSection('SettingsMagExp_General'),
    qsKeyboard = storage.playerSection('SettingsQuickSelectKeyboard'),
    qs         = storage.playerSection('SettingsQuickSelect'),
    debugMode  = false,
}
Cfg.debugMode = Cfg.general and Cfg.general:get('DebugMode') or false

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
    iMaxActivateDist      = core.getGMST('iMaxActivateDist') or 192,
    fCombatDistance       = core.getGMST('fCombatDistance') or 128,
    fHandToHandReach      = core.getGMST('fHandToHandReach') or 1.0,
    fCombatAngleXY        = core.getGMST('fCombatAngleXY') or 60.0,
    fCombatAngleZ         = core.getGMST('fCombatAngleZ') or 60.0,
    sSkillUp              = core.getGMST('sSkillUp') or "Your %s skill has increased to %d.",
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

-- ── Stagger / knockdown interruption rules ─────────────────────────────────
-- Vanilla cancels a cast when the caster is staggered; OSSC must do the same.
--   * KNOCK_GROUPS   — every animation group with 'knock' in its name. While
--                      any of these is playing, casting is forbidden.
--   * STAGGER_GROUPS — hit-reaction groups (stun-lock). While any of these is
--                      playing, casting is forbidden, and an already-started
--                      OSSC cast is cancelled instead of launching.
-- The lists below are also checked again at launch time (the 'release' moment)
-- so a stagger that lands mid-animation cancels the spell with no cost.
local KNOCK_GROUPS = {
    "knockdown", "knockout", "swimknockdown", "swimknockout", "hit1", "hit2", "hit3", "hit4", "hit5",
    "swimhit1", "swimhit2", "swimhit3",
}

local STAGGER_GROUPS = {
        "hit1", "hit2", "hit3", "hit4", "hit5",
    "swimhit1", "swimhit2", "swimhit3",
}

local INCAPACITATED_GROUPS = {
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
local COMBAT_ANIM_GROUPS = {
    "shield", "weapontwohand", "weapontwowide", "bowandarrow", "crossbow",
}

-- Weapon record types that belong to the animation groups above. While an
-- attack charge is being held, the weapon animation parks on a text key
-- ("min attack" / "max attack") and anim.isPlaying() returns false, so the
-- group check alone would let a quick-cast through the hold. When the attack
-- button is held with one of these weapons equipped, quick-casting is
-- therefore blocked as well.
local EXCLUDED_WEAPON_TYPE_TO_GROUP = {
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
local HEAVY_ATTACK_GROUPS = {
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
local LIGHT_ATTACK_GROUPS = {
    "weapononehand", "weapononehand1", "handtohand", "throwweapon",
}

-- Excluded combat group of the currently equipped weapon, if any (nil when
-- the actor has no weapon — or an unexcluded one — in the weapon slot).
local function getExcludedWeaponGroup()
    local equipment = types.Actor.equipment(self)
    local weapon = equipment and equipment[SLOT.CarriedRight]
    if not weapon or not weapon:isValid() or weapon.type ~= types.Weapon then return nil end
    local rec = types.Weapon.record(weapon)
    if rec and rec.type ~= nil then
        return EXCLUDED_WEAPON_TYPE_TO_GROUP[rec.type]
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
    for _, groupName in ipairs(LIGHT_ATTACK_GROUPS) do
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

-- Per-bone-group priorities + blend mask for an OSSC cast. When a light
-- attack owns the weapon arm the cast is restricted to LeftArm (+ legs at
-- WeaponLowerBody) so the swing keeps RightArm/Torso; otherwise the full
-- upper-body mask is used so 2H grip idles cannot pin the casting arm.
local function buildCastBlendOptions(finalSpeed)
    local priority = {
        [BONE.LeftArm]   = PRIO.Hit,
        [BONE.LowerBody] = PRIO.WeaponLowerBody,
    }
    local blendMask = BMASK.LeftArm + BMASK.LowerBody
    if not shouldPreserveLightAttackBones() then
        -- Full upper-body claim: beats Weapon-stance idles (idle1h /
        -- idletwohand / … at Default/Movement) so a two-hander's grip cannot
        -- pin the casting arm, but stays below PRIORITY.Weapon so a real
        -- weapon attack that starts mid-cast still wins the bones.
        priority[BONE.RightArm] = PRIO.Hit
        priority[BONE.Torso]    = PRIO.Hit
        blendMask = blendMask + BMASK.RightArm + BMASK.Torso
    end
    return {
        priority  = priority,
        startKey  = 'start',
        stopKey   = 'stop',
        blendMask = blendMask,
        speed     = finalSpeed,
    }
end

-- True while the actor is staggered (hit reactions) or knocked down/out.
-- Used to cancel an in-flight OSSC cast at launch time.
local function isStaggeredOrKnocked()
    for _, groupName in ipairs(KNOCK_GROUPS) do
        if anim.isPlaying(self, groupName) then return true end
    end
    for _, groupName in ipairs(STAGGER_GROUPS) do
        if anim.isPlaying(self, groupName) then return true end
    end
    return false
end

local function debugLog(msg)
    if Cfg.debugMode then
        print("[OSSC] " .. tostring(msg))
    end
end

-- ── State ─────────────────────────────────────────────────────────────────
-- NOTE: shared script state intentionally lives inside tables (Cast / PMM /
-- Stance) instead of plain file-scope locals. OpenMW's Lua (LuaJIT) allows a
-- function at most 60 upvalues, and the big handlers (onUpdate,
-- triggerQuickCast) close over nearly all of this state — every new local
-- here costs one upvalue in each of those functions. Please add new shared
-- state as a field of one of these tables rather than as a new `local`.
local Cast = {
    isCasting           = false,
    hasFiredThisCast    = false,
    pendingLaunches     = {},
    currentSpell        = nil,
    hasQueuedLaunch     = false,
    -- Resources for the cast in flight: set once by handleCastCosts() when the
    -- cast starts and copied into every queued launch ('release' key, safety
    -- launch timer, deferred PMM recall). A launch must never re-read it from
    -- Cast: by the time a queued launch resolves, Cast already belongs to
    -- whatever happened next.
    currentIsPaid       = false,
    -- Toast text for a refused cast (nil when the casting framework already
    -- told the player itself).
    currentCostMessage  = nil,
    -- The payment transaction is latched independently of the animation/audio
    -- latch. Rapid re-entry must never debit the same active cast twice.
    costPaidCastId      = nil,
    -- Cast id whose 'start' text key was already handled (cast sound + cast
    -- VFX + safety launch timer). Latches those to exactly one per quickcast.
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
-- QuickKey press tracking lives at the TOP of the file on purpose: the
-- onUpdate stance-suppression mirror (defined further down, before the hotkey
-- handler section) attributes late Spell-stance raises to a pending quickkey
-- press, so the mirror and the handlers below must share one state table — no
-- shadowed duplicates between the two sections. The pending-press fields live
-- in the ONE table below for the same 60-upvalue reason as the Cast / PMM /
-- Stance tables: every file-scope local a function references costs it an
-- upvalue, and the big onUpdate handler is nearly at LuaJIT's limit — a
-- single shared table keeps the mirror at one upvalue instead of four.
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
local quickkeyPreviousSpellRecordId        = nil   -- recordId (stable across loads)
local quickkeyPreviousItemRecordId         = nil   -- recordId (stable across loads)
local lastMagicItemHotkeySlot = nil
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
-- After-cast window: when set, this recall cast plays its FULL cast animation
-- and the PMM multi mark window opens only after the casting happens — on the
-- animation's 'release' text key (the moment the spell is launched), with a
-- fallback to the 'stop' key and to the safety unlock timer for animation
-- groups that omit those keys (e.g. qcsnap only carries 'start'/'release')
-- — instead of at cast start. The recall launch is held back at the
-- 'release' text key and queued only when the player picks a mark; leaving
-- the window any other way cancels the recall (the vanilla mark must not go
-- through while this option is enabled).
-- (pmmDeferredRecall now lives in the PMM table above.)
local resolvePMMRecall        -- assigned below, once animUnlock is defined
-- Simulation time at which the PMM recall UI stopped waiting for input.
-- Safety timers use this to give the resumed cast animation its normal
-- grace window instead of force-cleaning up the moment the UI closes.
-- (pmmUiClosedAt now lives in the PMM table above.)
-- Simulation time at which OSSC requested the PMM recall UI. I.UI.setMode is
-- processed by the engine on a later UI update, so this gives that transition
-- a short grace period before onUpdate treats a still-nil mode as closed.
-- (pmmUiOpenedAt now lives in the PMM table above.)

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
local weaponAttackLockActive = false
local combatBlockActive      = false

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

-- True when the BlockWeaponDuringQuickcast setting is on, a quickcast is
-- currently playing on the hands, and an excluded (2H / bow / crossbow)
-- weapon is equipped — the condition under which heavy-weapon attacks must be
-- prevented. This rule has higher priority than AllowAttackingWhileCasting:
-- that setting may keep one-handed / hand-to-hand attacks usable mid-cast, but
-- the heavy excluded weapon classes must still be blocked while quick-casting.
-- Shared by the control-switch lock, the coarse combat-block fallback, and the
-- animation-cancel handler.
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

local suppressedBlockSkill = nil  -- unused, kept as placeholder so onSave/onLoad calls are harmless

local suppressedShield    = nil   -- shield item unequipped during cast
local SHIELD_GHOST_VFX_ID = 'OSSC_ShieldGhost'

-- Equipment is authoritative: bound spells, inventory equips and other mods
-- all reach this check. Never keep a cast's cosmetic shield over a 2H weapon.
-- Forget the saved shield too, so cleanup cannot overwrite the new loadout.
local function reconcileShieldWeapon()
    if getExcludedWeaponGroup() == nil then return false end
    anim.removeVfx(self, SHIELD_GHOST_VFX_ID)
    suppressedShield = nil
    return true
end

-- Unequip the shield to prevent blocking, but attach its mesh to the left-hand
-- bone via addVfx so it stays visually in place during the quickcast window.
local function suppressShieldDuringCast()
    if reconcileShieldWeapon() then return end
    if not (Cfg.general and Cfg.general:get('BlockShieldDuringQuickcast')) then return end
    if suppressedShield then return end
    local eq = types.Actor.getEquipment(self)
    local item = eq[SLOT.CarriedLeft]
    if not (item and item.type == types.Armor
        and types.Armor.record(item).type == types.Armor.TYPE.Shield) then
        -- No shield equipped at cast time: this cast must not show any shield
        -- VFX. Remove a ghost left over from an earlier cast instead of
        -- letting it reappear during this one.
        anim.removeVfx(self, SHIELD_GHOST_VFX_ID)
        return
    end
    local armorRec = types.Armor.record(item)
    -- Attach the shield mesh as a looping VFX on the left-hand bone so the
    -- player still sees it while the equipment slot is vacant.
    if armorRec.model and armorRec.model ~= '' then
        anim.addVfx(self, armorRec.model, {
            loop            = true,
            vfxId           = SHIELD_GHOST_VFX_ID,
            boneName        = 'Bip01 L Hand',
            useAmbientLight = false,
        })
        debugLog('Shield ghost VFX added: ' .. armorRec.model)
    end
    suppressedShield = item
    eq[SLOT.CarriedLeft] = nil
    types.Actor.setEquipment(self, eq)
    debugLog('Shield unequipped for blocking suppression: ' .. tostring(item.recordId))
end

-- Remove the ghost VFX and re-equip the shield after the cast ends.
local function restoreShieldAfterCast()
    reconcileShieldWeapon()
    anim.removeVfx(self, SHIELD_GHOST_VFX_ID)
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

-- True when the BlockShieldDuringQuickcast setting is on and a quickcast is in
-- progress. When true, any "shield" (block) animation the player starts will be
-- cancelled by both the addPlayBlendedAnimationHandler and the onUpdate loop.
local function shouldBlockShield()
    if not (Cfg.general and Cfg.general:get('BlockShieldDuringQuickcast')) then return false end
    return isHandFreeDuringCast()
end

local function setWeaponAttackLock(locked)
    if not canUseFightingControlSwitch() then return end
    input.setControlSwitch(input.CONTROL_SWITCH.Fighting, not locked)
    weaponAttackLockActive = locked
    debugLog("Weapon attack lock " .. (locked and "engaged" or "released"))
end

local function setCombatBlock(locked)
    if not I.Controls or not I.Controls.overrideCombatControls then return end
    I.Controls.overrideCombatControls(locked)
    combatBlockActive = locked
    debugLog("Combat block " .. (locked and "engaged" or "released"))
end

local function shouldHoldCombatBlock()
    if not Cast.isCasting then return false end
    if not (Cfg.general and Cfg.general:get('AllowAttackingWhileCasting')) then
        return true
    end
    -- BlockWeaponDuringQuickcast has priority over AllowAttackingWhileCasting.
    -- Bound 2H weapon spells are exempted so the weapon mesh initializes cleanly.
    if not Cast.isBound2HWeaponCast
        and Cfg.general:get('BlockWeaponDuringQuickcast') == true
        and getExcludedWeaponGroup() ~= nil then
        return true
    end
    return false
end

local function reconcileWeaponAttackLock()
    local wantLock = shouldBlockHeavyAttack()
    if wantLock ~= weaponAttackLockActive then
        setWeaponAttackLock(wantLock)
    end
end

local function reconcileCombatBlock()
    local wantLock = shouldHoldCombatBlock()
    if wantLock ~= combatBlockActive then
        setCombatBlock(wantLock)
    end
end

-- NGarde exclusion must cover both input orderings: the start gate below
-- rejects cast-after-parry, while this external controller state rejects
-- parry-after-cast for the exact lifetime of the quickcast. No frame polling is
-- needed; cast start/cleanup are the state transitions.
local function setNgardeParryControl(active)
    -- The setting check is deliberately truthy (not `== true`) to match the
    -- cast-start gate in triggerQuickCast: any truthy stored value must engage
    -- the lock, otherwise casts get refused while parrying but a guard can
    -- still be raised over a cast already in progress.
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
        -- A wholly absent interface just means NGarde is not installed (stay
        -- silent, as before). But an interface WITHOUT externalParryControl
        -- means an outdated NGarde that cannot honor the lock the setting
        -- promises — warn once so the user knows to update it.
        if active and ngarde ~= nil and not Cast.ngardeMissingWarned then
            Cast.ngardeMissingWarned = true
            print('[OSSC] WARNING: Block Quick Cast During NGarde Parry is on, but this NGarde version has no externalParryControl — guards can still rise mid-cast. Update NGarde.')
        end
    end
end

local function isPMMInstalled()
    return Cfg.pmm ~= nil
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
            -- Player picked a multi mark destination. The cast animation has
            -- already released (after-cast window), so resolve the held
            -- recall right away: queue the launch + release the cast lock.
            PMM.pmmSelectedDestination = id
            PMM.pmmVanillaRecall = false
            resolvePMMRecall('PMM mark selected')
        else
            -- "Latest" / no mark picked: with Pure Multi Mark Compatibility
            -- enabled the vanilla mark must NOT go through — cancel the
            -- recall instead of falling back to a standard Recall.
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

-- Destroy the PMM recall window if it is currently alive. The function is
-- defined by PMM_markWindow when it loads, so guard against a missing/stale
-- global (e.g. when the window failed to load).
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

    -- PMM_markWindow reads these globals from the player-script environment.
    -- (The engine-module globals — core/util/ui/async/input/v2 — are exported
    -- at the very top of this file, before the local declarations.)
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
        -- PMM_markWindow calls renameDialog.isOpen()/close() unconditionally,
        -- so provide inert stubs instead of leaving the global nil. Renaming
        -- simply becomes unavailable.
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
        -- pmmVanillaRecall stays false: the caller (the release/stop
        -- handler) cancels the recall — the vanilla mark must not go through.
        if I.UI and I.UI.setMode then I.UI.setMode() end
    end
end

-- ── Stance suppression for CastOnQuickkeys / SuppressSpellStance settings ──
-- (One table for the same 60-upvalue reason as the Cast table above.)
local Stance = {
    lastNonSpellStance = nil,   -- initialised just below
    spellStanceAllowed = false, -- persistent toggle: user pressed R, wants spell stance open
    prevStance         = nil,   -- stance on the previous frame (pre-toggle intent, see onFrame)
    prevSpellKeyDown   = false,
    prevWeaponKeyDown  = false,
    isGrimoireIdlePlaying = false, -- grimoire idle animation state (see below)
    -- ── Previous-frame baseline for quickkey change detection ─────────────
    -- The engine applies a quickkey's selection + Spell stance BEFORE any Lua
    -- input handler runs (ActionManager::executeAction runs the native
    -- quickKey() first; queued Lua input callbacks only see the result). A
    -- snapshot taken inside handleQuickkeyPress therefore describes the
    -- POST-press state and change detection against it can never fire. These
    -- fields hold the selection / stance / equipment as of the END of the
    -- previous onFrame — the true pre-press state. Refreshed at every onFrame
    -- exit (see updatePrevFrameStore) and in onLoad.
    prevFrameSpell     = nil,
    prevFrameItem      = nil,
    prevFrameStance    = nil,
    prevFrameEquipment = nil,
    -- ── Stance to put back once a quickkey cast finishes ──────────────────
    -- Set when a quickkey press resolves into an actual cast, cleared by
    -- animUnlock. Both revert paths in the quickkey handler are scoped to a
    -- *pending* press and QuickkeyPress.slot is cleared the moment the press
    -- resolves, so a cast that does fire would otherwise leave the engine's
    -- Spell stance up for good. See restoreStanceAfterCast.
    --
    -- While the cast is in flight the target is also what the onUpdate mirror
    -- reverts late raises to (Stance.quickkeyRevertTarget), and it is why a
    -- spam press must NOT clear it (handleQuickkeyPress): the cast is still
    -- running and animUnlock is the only place that puts the stance back.
    postCastRestore    = nil,
}
Stance.lastNonSpellStance = types.Actor.getStance(self)
if Stance.lastNonSpellStance == STANCE.Spell then
    Stance.lastNonSpellStance = STANCE.Nothing
end
Stance.prevStance = types.Actor.getStance(self)
-- (spellStanceAllowed / prevStance / prevSpellKeyDown / prevWeaponKeyDown /
--  isGrimoireIdlePlaying now live in the Stance table above.)

-- ── NEW — grimoire idle state ──────────────────────────────────────────────
local OSSC_PowerCooldowns = {}

local function isSpeedyMagickInstalled()
    -- Decided by the load order. The previous version probed
    -- storage.playerSection('SettingsyksuiSpeedyMagick') and friends, which
    -- CREATES those sections on read, so it reported SpeedyMagick as installed
    -- on every machine and always applied its speed scaling; it then pcall'd
    -- `require` over six candidate module paths, which the content-file check
    -- makes unnecessary.
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

-- ── Ralts Nifty Spell Pack (NSP) — Alacrity compatibility ────────────────
-- Alacrity (magic effect 'nsp_alacrity') scales the caster's spellcast speed
-- proportional to its magnitude, up to 4x at 100 magnitude. NSP drives this by
-- calling anim.setSpeed(self, 'spellcast', ...) on the vanilla group, which has
-- no effect on OSSC's own quickcast animation groups. To stay compatible, we
-- read the exact same active-effect magnitude NSP uses and apply the identical
-- multiplier to OSSC's cast animation speed.
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

-- ── Shield Casting Penalty ────────────────────────────────────────────────
-- Optional slowdown for quick-casting while a shield is equipped. Uses the
-- Carry-Capacity Ratio formula:
--   capacity = (Strength + Proficiency) / 2
--   penalty  = W * 45 / (capacity + 45)
--   mult     = 1 - (penalty / 100) * v
-- where W = shield weight capped at 45, Proficiency = the currently-cast spell
-- school's skill (Enchant skill for enchanted items), and v = the strength the
-- 'ShieldCastingPenalty' setting picks (Off / 10%..100% / Skill based — see
-- Penalty.shield in scripts/ossc/ossc_penalty.lua; 'skill_based' derives v
-- from Proficiency: 0 → 1.0, 100+ → 0). Result is clamped so a cast can never
-- be slowed below 0.55x.
local function getShieldCastingPenaltyMult(schoolStr, isItem)
    if not Cfg.general then return 1.0 end
    local mode = Cfg.general:get('ShieldCastingPenalty')
    local skillBased = Penalty.isSkillBased(mode)
    -- A flat strength of 0 (off, or a value nothing recognises) needs no
    -- shield lookup; the skill-based strength is only known after it.
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

--- Current (effective) value of the magic skill a cast is judged by:
--- the casted spell's school skill, or the Enchant skill for enchanted items.
--- Accepts the school as a name string or, on engine builds where the
--- effect record exposes it as an index, as the 0-5 school number.
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
    for _, groupName in ipairs(INCAPACITATED_GROUPS) do
        if anim.isPlaying(self, groupName) then return true end
    end
    return false
end

local function levelUpSkill(skillId, newBaseValue)
    local skill = types.NPC.stats.skills[skillId](self)
    skill.base = newBaseValue
    local skillData = MAGIC_SKILLS[skillId]
    local displayName = skillData and skillData.name or skillId
    local skillNameGMST = core.getGMST('sSkill' .. displayName) or displayName
    local skillUpMsg = GMST.sSkillUp
    ui.showMessage(string.format(skillUpMsg, skillNameGMST, newBaseValue))
    core.sound.playSound3d("skillraise", self)
    local levelStats = types.Player.stats.level(self)
    if levelStats then
        levelStats.progress = (levelStats.progress or 0) + 1
        if skillData then
            local attr = skillData.attribute
            levelStats.skillIncreasesForAttribute[attr] =
                (levelStats.skillIncreasesForAttribute[attr] or 0) + 1
            local spec = skillData.specialization
            levelStats.skillIncreasesForSpecialization[spec] =
                (levelStats.skillIncreasesForSpecialization[spec] or 0) + 1
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

--- The gain OSSC's own formula would award, used when the caller does not say
--- how much: the SkillExperience setting as a percentage of one skill level -
--- exactly what the internal 'ossc' mode computes.
local function defaultSkillGain()
    local xpGain = Cfg.general and Cfg.general:get('SkillExperience') or 0
    return (tonumber(xpGain) or 0) * 0.01
end

--- Award spellcasting skill experience to the player.
---
---     I.OSSC.awardSkillProgress('destruction', { skillGain = 0.35 })
---
--- Works whatever the Skill Progression Mode setting says, 'none' included.
---
--- @param skillId string  skill record id: 'destruction', 'enchant', ... or a
---                        custom skill added by another framework
--- @param options table?
---   skillGain number   progress to add, in the unit skill.progress is exposed
---                      in: 1.0 == one skill level.  Major / minor /
---                      specialization bonuses are NOT applied - the caller
---                      owns the formula.
---   useType   number   SkillProgression use type, forwarded on backend = 'external'
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

    if options.backend == 'external' then
        if not (I.SkillProgression and I.SkillProgression.skillUsed) then
            return false, 'no external skill-progression interface is installed'
        end
        I.SkillProgression.skillUsed(skillId, {
            useType   = options.useType
                or I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success,
            skillGain = tonumber(options.skillGain),
        })
        debugLog("[OSSC] handed " .. skillId .. " to I.SkillProgression.skillUsed")
        return true
    end

    local gain = tonumber(options.skillGain) or defaultSkillGain()
    if gain <= 0 then return false, 'nothing to award' end

    -- skill.progress is 0..1 of the requirement, so crossing 1.0 is a level.
    local progress = stat.progress + gain
    local base = stat.base
    while progress >= 1.0 and base < 100 do
        base = base + 1
        progress = progress - 1.0
        levelUpSkill(skillId, base)
    end
    stat.progress = math.max(0, progress)
    debugLog(string.format("[OSSC] awarded %.2f progress to %s (base now %d)",
        gain, skillId, base))
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
local function effectPenaltyExempt(spell)
    if not spell then return false end
    -- Powers never pay the Quick Cast Effect Penalty (unconditional).
    if spell.type == SPELL_TYPE.Power then return true end
    local rec = (spell.id and spellRecs[spell.id]) or nil
    if not rec and spell.enchantment then rec = spell.enchantment end
    if not rec and spell.id then rec = enchRecs[spell.id] end
    if rec and rec.type == SPELL_TYPE.Power then return true end

    -- The exclusion toggle covers scrolls ONLY.  While it is off, only powers
    -- are exempt.
    if not (Cfg.general and Cfg.general:get('QuickCastEffectPenaltyScrollsExempt')) then
        return false
    end

    -- Toggle on.  A scroll is the CastOnce enchantment form and is exempt; a
    -- spell (no enchantment record) or a CastOnUse / ConstantEffect item is
    -- still penalised.
    local ench = spell.enchantment or (spell.id and enchRecs[spell.id])
    return ench ~= nil and ench.type == ENCHTYPE.CastOnce
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

-- ── Enchanted item cost / charge ──────────────────────────────────────────
-- An enchanted-item quick-cast is paid from the ITEM's charge, never from
-- magicka, and vanilla never rolls a skill check for it: the only thing that
-- can stop an item cast is a charge pool that cannot cover the cost.
--
-- [ENCHANT FORMULA] charge cost = 0.01 * (110 - Enchant skill) * spell cost.
-- The same formula lives in ossc_actor_items.lua (getEffectiveCost) and in
-- ossc_global.lua's OSSC_ConsumeCharge handler, and Spell Framework Plus
-- applies it too — Helpers.getModifiedSpellCost(actor, spellId, true). SFP
-- re-checks the charge against exactly that number in its launch-time
-- resource guard, so prefer SFP's own value when the interface is
-- registered: the gate here and the deduction at launch can never disagree.
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

-- Charge currently held by the item backing an enchanted-item cast.
-- types.Item.itemData() is the only reader the engine offers (and it can come
-- back nil on an item the engine has never had to describe), so fall back to
-- the enchantment record's capacity — a never-used item is full.
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

-- Can this enchanted item pay for one more cast?
--   * CastOnce (scrolls) are consumed whole — one has to be left to use.
--   * Constant Effect enchantments are passive and never spend charge.
--   * everything else spends charge and needs enough of it.
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
    -- ── Powers are sure casts ─────────────────────────────────────────────
    -- Vanilla never rolls to see whether a Power goes off; it spends the
    -- once-a-day use and the spell lands.  Spell Framework Plus agrees and
    -- reports a 100% chance for a power (magexp_helpers.getSpellCastChance),
    -- but the quick-cast penalty below multiplied that 100 by its own scale —
    -- and the skill scale at skill 0 is 0.5, so a power cast through the
    -- quick-cast system resolved at exactly 50% and the release-moment roll
    -- dropped every other one.  A power is answered here, before any penalty
    -- arithmetic can touch it: always 100, whatever the settings or the skill.
    local powerRec = (spell.id and spellRecs[spell.id]) or spell.enchantment or nil
    if spell.type == SPELL_TYPE.Power or (powerRec and powerRec.type == SPELL_TYPE.Power) then
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
    -- 'skill_based': the penalty follows the cast skill (0 → 50%, 100+ → none);
    -- anything else is a flat percentage (or off).
    local chanceMode = Cfg.general and Cfg.general:get('QuickCastChancePenalty')
    local chanceScale
    if Penalty.isSkillBased(chanceMode) then
        chanceScale = Penalty.skillScale(getMagicSkillValue(caster, school, false))
    else
        chanceScale = getPenaltyScale(chanceMode)
    end
    chance = math.max(0, math.min(100, util.round(chance*chanceScale)))
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

-- ── MBSP Magicka Refund (cloned 1:1 from MBSP/Scripts/MBSP/MBSP_p.lua) ──────
-- The MagickaRefund setting enables MBSP standalone's "Refund" mode behaviour
-- for OSSC quick-casts: after a successful magic-school spell cast, a portion
-- of the spell's magicka cost is returned based on your average magic skill.
-- mbspCheckSpell / mbspGetAverageSkill / mbspCalcRefund mirror MBSP's
-- checkSpell / getAverageSkill / calcRefund exactly (GameSpell cost method
-- with fEffectCostMult, per-school cost shares, exponential effective-cost
-- formula). The refund applies only to spells (not powers or enchanted
-- items), only when positive, and is skipped in god mode — matching MBSP's
-- registerSkillUsed "Refund" handler.
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
    -- MBSP: willpower/5 + luck/10, plus each magic school skill weighted by
    -- its share of the spell's calculated cost.
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

-- Reads the OSSC MagickaRefund settings. Defaults match MBSP standalone:
-- Skill Requirement 35, Magicka Cost Scaling 50% (stored as percent,
-- divided by 100 like MBSP's percentKeys), Level Scaling 100.
local function getMagickaRefundSettings()
    return {
        enabled      = Cfg.general and Cfg.general:get('MagickaRefund') == true,
        refundStart  = Cfg.general and Cfg.general:get('MagickaRefundStart') or 35,
        refundMult   = ((Cfg.general and Cfg.general:get('MagickaRefundMult')) or 50) / 100,
        levelScaling = Cfg.general and Cfg.general:get('MagickaRefundLevelScaling') or 100,
    }
end

-- MBSP "Refund" mode application: refund only when positive, never in god
-- mode (matches MBSP's registerSkillUsed). No upper clamp — MBSP has none.
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
    if not combatBlockActive then return end
    setCombatBlock(false)
end

-- Reads the caster's magicka pool. Payment itself happens in handleCastCosts,
-- at animation start: through Spell Framework Plus' consumeSpellCost when the
-- interface is registered, and from OSSC's own pocket otherwise.
local function hasMagicka(cost)
    local magicka = types.Actor.stats.dynamic.magicka(self)
    return magicka.current >= (cost or 0)
end

-- Pays (or refuses) everything a quick-cast costs. Returns
--   paid     — true when the cast may go through
--   failMsg  — the toast to show when it may not; nil when the casting
--              framework already showed its own message
local function handleCastCosts(spell)
    if debug.isGodMode() then return true end

    -- ── Enchanted item: the item's charge pays, magicka is untouched ──────
    if spell.item then
        if canAffordItemCast(spell) then
            -- The charge itself is spent by Spell Framework Plus at launch:
            -- OSSC sends isFree = false for item casts, which makes SFP's
            -- resource guard deduct the cost from the item. enchantmentCharge
            -- can only be written from a global script, so this script must
            -- not try to deduct it here (it would either error or be
            -- silently dropped, and MagExp would deduct a second time).
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
        -- SFP checks the pool AND deducts the cost, and shows its own
        -- insufficient-magicka toast — so no second toast from OSSC.
        canAfford = I.MagExp_Player.consumeSpellCost(spell.id, nil)
        debugLog(string.format("Magicka cost %s (consumeSpellCost → %s)",
            tostring(magickaCost), tostring(canAfford)))
    else
        -- No consumer registered: OSSC pays the magicka itself, right here at
        -- animation start. Vanilla drains the pool the moment the cast
        -- gesture begins — not when the spell is released at the animation's
        -- end — so deferring the deduction to SFP's launch-time resource
        -- guard is not an option. The launch therefore goes out with
        -- isFree = true (see the CastRequest) so the same cast can never be
        -- charged a second time at the release point.
        canAfford = hasMagicka(magickaCost)
        if canAfford then
            if magickaCost > 0 then
                local magicka = types.Actor.stats.dynamic.magicka(self)
                -- [MAGICKA TRACE] One of three deduction sites (the other two
                -- are in magexp_player.lua: consumeSpellCost and
                -- MagExp_ConsumeResource). This one only runs when SFP has not
                -- registered its consumer, so a player with SFP installed must
                -- never see this line and one of those in the same cast.
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
            -- MCP (Morrowind Code Patch) formula:
            --   fatigue loss = magickaCost * (fFatigueSpellBase + enc% * fFatigueSpellMult)
            -- Vanilla ships both GMSTs as 0 (no fatigue cost at all), which
            -- made UseFatigue a silent no-op. When they are untuned, fall
            -- back to a built-in default — half the magicka cost at zero
            -- encumbrance up to the full magicka cost at full encumbrance —
            -- so the setting works out of the box. Tuning either GMST
            -- switches to the GMST-driven value.
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
            if static and static.model and not spawnedModels[static.model] then
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
        if mgef then
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
    if static and static.model then
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
    -- Drop only THIS cast's queued launches. A previous cast's entry is a
    -- paid, RELEASED launch that has not fired yet: the cast unlocks on its
    -- 'stop' text key while the launch still waits for the next onUpdate to
    -- execute. Wiping the whole queue here (and at the next cast's start)
    -- swallowed that spell while its magicka stayed consumed — the reported
    -- "spamming the quickcast key sometimes costs double the magicka": one
    -- gesture pays, the next one fires, the first spell silently vanishes.
    for i = #Cast.pendingLaunches, 1, -1 do
        if Cast.pendingLaunches[i].castId == Cast.currentCastId then
            table.remove(Cast.pendingLaunches, i)
        end
    end
end

-- ── The quickkey window (helpers on the Stance table) ─────────────────────
-- A quickkey press and the cast it starts are ONE interaction: the engine
-- re-applies the key (and re-raises Spell stance with it) while the cast it
-- already started is still running, and on a spam burst each press does it
-- again. Both helpers below describe that single window. They live on the
-- Stance table rather than as file-scope locals because the handlers that need
-- them (onUpdate, the animation veto) are at LuaJIT's upvalue limit and
-- `Stance` is already one of their upvalues.
--
-- True while a quickkey press is pending OR a cast that a quickkey started is
-- still in flight. The `Cast.isCasting` test on the second half also ignores a
-- stale postCastRestore left behind by a cast that never reached animUnlock
-- (e.g. across a save load): that target may only matter while its cast runs.
function Stance.quickkeyWindowActive()
    return QuickkeyPress.slot ~= nil
        or (Cast.isCasting and Stance.postCastRestore ~= nil)
end

-- The stance to put back when a quickkey-raised Spell stance is reverted.
-- While a quickkey cast is in flight its recorded pre-press stance is
-- authoritative: a spam press's previous-frame baseline (prePressStance) is
-- captured at the end of onFrame, so the engine's own late raise — the very
-- thing being reverted — can already be in it, and reverting to it would leave
-- the weapon sheathed (Spell is never a valid target, so it degrades to
-- Nothing instead of the Weapon the player had out).
function Stance.quickkeyRevertTarget()
    local target = Stance.postCastRestore
        or QuickkeyPress.prePressStance
        or Stance.lastNonSpellStance
        or STANCE.Nothing
    if target == STANCE.Spell then target = STANCE.Nothing end
    return target
end

--- Puts the player's stance back once a quickkey cast has finished.
---
--- The engine raises Spell stance when it applies a Magic / MagicItem quickkey,
--- and on the way there it sheaths a drawn weapon. Both revert paths in the
--- quickkey handler are scoped to a *pending* press — `QuickkeyPress.slot` is
--- cleared the moment the press resolves — so a press that does resolve into a
--- cast was left in the stance the engine put it in: weapon sheathed, magic
--- hands readied, until the player pressed something else. Nothing was visible
--- when no weapon was drawn, because the pre-press stance was already Nothing
--- and reverting to it is a no-op — which is why the symptom only ever showed
--- up with a weapon out.
---
--- Scoped the same way as the rest of the stance blockade: only while the
--- SuppressSpellStance setting is on, never against a stance the player opened
--- by hand, and only when the stance really is the engine's Spell raise.
local function restoreStanceAfterCast(reason)
    local target = Stance.postCastRestore
    Stance.postCastRestore = nil
    if target == nil then return end
    if Stance.spellStanceAllowed then return end
    if not (Cfg.general and Cfg.general:get('SuppressSpellStance') == true) then return end
    if types.Actor.getStance(self) ~= STANCE.Spell then return end
    if target == STANCE.Spell then target = STANCE.Nothing end
    debugLog("[OSSC Stance] Restoring post-cast stance (" .. tostring(reason or "") .. ")")
    types.Actor.setStance(self, target)
    -- Keep the pre-toggle intent reference exact for the next frame.
    Stance.prevStance = target
end

local function animUnlock(reason)
    if not Cast.isCasting then return end
    debugLog("AnimUnlock: " .. (reason or ""))
    -- Quick-slot throttling is animation-bound, not wall-clock-bound. Release
    -- the gate only when the cast animation reports its terminal stop key.
    -- This prevents key spam from launching the native quickkey animation
    -- repeatedly during the gesture, regardless of animation speed.
    QuickkeyPress.cooldownActive = false
    if Cast.ngardeParryControlActive then setNgardeParryControl(false) end
    Cast.isCasting           = false
    Cast.currentAnimGroup    = nil
    Cast.isBound2HWeaponCast = false
    restoreShieldAfterCast()
    disableCombatBlock()
    restoreStanceAfterCast(reason)
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

-- Resolves a deferred (after-cast) PMM recall to the picked mark: queues the
-- recall launch that was held back at the 'release' text key and releases the
-- cast lock. Only called when the player actually picked a mark — every other
-- way of leaving the window (Esc, X, "Latest", window unavailable) cancels
-- the recall instead, because the vanilla mark must not go through. Safe to
-- call more than once — only the first call queues the launch.
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

-- ── NEW — Eternal Grimoire helpers ─────────────────────────────────────────
--
-- Returns true when 'eternal_grimoire' is in the CarriedLeft (shield/light) slot.
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

-- Starts the egidle2 loop at Default priority (so any Scripted cast
-- will visually override it without cancelling the underlying cycle).
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

-- ── Swimming gate for target-range quick-casts ────────────────────────────
-- While the caster is SWIMMING, quick-casts whose effects include a Target
-- range must not start. "Swimming" is the engine's own definition, reported
-- by types.Actor.isSwimming: the water level is above fSwimHeightScale
-- (≈ 0.9) of the character's height — the WHOLE body is in the water. Merely
-- wading through shallows (feet in water) does NOT count, so the gate only
-- trips when the character is actually swimming. Self and Touch casts stay
-- available while swimming.
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
    local ignoreUIMode = opts and opts.ignoreUIMode
    local ignoreWorldPause = opts and opts.ignoreWorldPause
    local uiMode = (ui and ui.activeMode)
    if not uiMode and I.UI and I.UI.getMode then uiMode = I.UI.getMode() end
    if (uiMode ~= nil and not ignoreUIMode) or (core.isWorldPaused() and not ignoreWorldPause) or Cast.isCasting then
        if Cast.isCasting then
            debugLog("Input rejected — cast in progress (currentAnimGroup=" ..
                tostring(Cast.currentAnimGroup) .. ")")
        end
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
        for _, groupName in ipairs(COMBAT_ANIM_GROUPS) do
            -- Any playing combat animation blocks quick-casting. A bow/crossbow
            -- shot blocks for its WHOLE duration — draw/aim and the
            -- follow-through after the projectile is away — so a quick 1-tap
            -- can no longer cast mid-shot the way it could when the
            -- follow-through was exempted (it used to leave a gap that held
            -- attacks covered but 1-taps did not).
            if anim.isPlaying(self, groupName) then
                debugLog("Cast blocked — combat animation playing: " .. groupName)
                self:sendEvent('OSSC_CastingState', { isCasting = false })
                return
            end
        end
        -- A held attack charge parks the weapon animation on a text key, so
        -- the isPlaying() loop above misses it: also block while the attack
        -- button is held down with a weapon from an excluded group.
        local heldGroup = isAttackUseHeld() and getExcludedWeaponGroup() or nil
        if heldGroup then
            debugLog("Cast blocked — holding attack charge with excluded weapon: " .. heldGroup)
            self:sendEvent('OSSC_CastingState', { isCasting = false })
            return
        end
    end

    -- NGarde parry block: while the player is holding up a parry guard (or is
    -- in the wind-up to raise it), a quick-cast must not start — the hands are
    -- committing to a block and the cast would play over the guard. No-op when
    -- NGarde is absent (I.NGardePlayer is only registered by NGarde's own
    -- player script) or the player is not parrying.
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

    for _, groupName in ipairs(INCAPACITATED_GROUPS) do
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

    -- ── Swimming gate (vanilla parity) ─────────────────────────────────────
    -- Target-range quick-casts attempted while swimming are NOT refused here
    -- any more. Vanilla lets the cast gesture play and consumes the magicka;
    -- the spell itself always fails. The fizzle therefore happens at the
    -- RELEASE moment, in the pending-launch executor below: the launch is
    -- vetoed and the vanilla "Spell Failure" sound plays. No message is
    -- shown. ("Swimming" is the engine's own definition — types.Actor
    -- .isSwimming, water above fSwimHeightScale ≈ 0.9 of body height, the
    -- WHOLE body in the water; wading with feet wet does not count.)

    if spellRec.type == SPELL_TYPE.Power then
        if not (Cfg.general and Cfg.general:get('AllowPowerCasting')) then
            ui.showMessage("You need bigger focus to cast powers. Use spell stance.")
            return abortCast("power blocked")
        end
        local readyTime = OSSC_PowerCooldowns[spellId]
        if readyTime and core.getGameTime() < readyTime then
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
            -- After-cast window: let the full cast animation play first and
            -- open the multi mark selection window only after the casting
            -- happens (on the animation's 'stop' text key).
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
    -- Cast.pendingLaunches is deliberately NOT reset here. Any entry still in
    -- the queue belongs to a PREVIOUS cast that was already paid and released
    -- but whose launch has not executed yet (it fires on the next onUpdate).
    -- Resetting the table dropped that launch and its spell while the magicka
    -- stayed consumed — a spam press landing in the one-frame gap between the
    -- previous cast's unlock and its launch cost double the magicka. The
    -- executor below fires every due entry, whatever cast it belongs to.
    Cast.currentCastId = Cast.currentCastId + 1
    Cast.castStartTime = now
    Cast.isBound2HWeaponCast = hasBound2HWeaponEffect(activeSpell)
    suppressShieldDuringCast()
    -- Publish the hand-occupancy state before any animation/control callback
    -- can run.  Previously currentAnimGroup was assigned after the combat
    -- locks were enabled, leaving a frame in which a held 2H attack could
    -- start before the lock considered the cast active.
    Cast.currentAnimGroup = animGroup
    enableCombatBlock()
    reconcileWeaponAttackLock()
    -- The guard-at-cast-start check has already passed. Lock NGarde now so a
    -- later parry input cannot overlay the weapon guard on this cast.
    setNgardeParryControl(true)
    self:sendEvent('OSSC_CastingState', { isCasting = Cast.isCasting })
    self:sendEvent('MagExp_SetPendingCastSpellId', { spellId = spellId })

    -- Re-arming safety unlock: while the PMM recall UI is open the cast is
    -- intentionally on hold, so a one-shot timer would expire uselessly and
    -- never run again. Keep re-arming until the cast actually resolves, and
    -- after the UI closes give the resumed animation its full grace window.
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
            -- Neither the 'release' nor the 'stop' text key fired (some
            -- animation groups — e.g. qcsnap — only carry 'start'/'release'),
            -- so the window was never opened. Open it now as the last-resort
            -- fallback instead of force-cleaning the held recall.
            debugLog("Safety unlock timer fired — opening PMM multi mark window (no cast text key)")
            openPMMRecallWindow()
            if not PMM.isWaitingForPMMInput then
                -- Window failed to load: cancel — the vanilla mark must not
                -- go through while Pure Multi Mark Compatibility is enabled.
                -- (Success is signalled by isWaitingForPMMInput staying true;
                -- pmmDeferredRecall stays true until the recall resolves, so
                -- it cannot be used to detect the failure here.)
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
    -- Per-bone-group priorities via buildCastBlendOptions:
    -- openmw.animation.playBlended seeds unlisted groups with
    -- PRIORITY.Default (0), so every bone in the blend mask must be
    -- listed. The split is:
    --   Arms + Torso = PRIORITY.Hit (6) when no 1H swing is in flight.
    --   Beats Weapon-stance idles (idle1h / idletwohand / … at Default
    --   0 / Movement 5) so a two-hander's grip cannot pin the casting
    --   arm, but stays below PRIORITY.Weapon (7) so a real weapon
    --   attack that starts mid-cast still wins the bones.
    --   When a 1H / H2H / thrown attack is already mid-swing (or a 1H
    --   charge is held), RightArm + Torso are left OUT of the mask so
    --   the cast cannot steal those bones and freeze the attack mid-
    --   animation. The cast then plays on LeftArm only (OSSC casts are
    --   left-hand flicks).
    --   LowerBody = PRIORITY.WeaponLowerBody (1). Below PRIORITY.
    --   Movement (5), so locomotion keeps owning the legs. A biped's
    --   world position comes from the root motion of whatever owns the
    --   LowerBody mask: at Scripted (13) walk/run was paused and the
    --   zero-root-motion cast anim froze movement for the whole cast.
    local blendOpts = buildCastBlendOptions(finalSpeed)
    if shouldPreserveLightAttackBones() then
        debugLog("Cast blend: preserving 1H/H2H attack bones (LeftArm-only cast)")
    end
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
                    fallback, buildCastBlendOptions(finalSpeed))
            end
        end
    end)
end



-- ── Crosshair look target (rendering ray, cached in onFrame) ───────────────
-- Vanilla determines a Touch spell's target from the crosshair with a
-- RENDERING ray (World::getFocusObject -> castCameraToViewportRay), i.e. it
-- hits exactly what the player sees — including thin door panels and chests
-- whose convex physics shape does not cover what the crosshair is on.
--
-- OpenMW only permits nearby.castRenderingRay while processing input/frame
-- events; calling it from an onUpdate engine handler throws. But OSSC launches
-- its casts from onUpdate, where the only legal query is nearby.castRay — a
-- physics ray against convex collision shapes. That ray reliably misses many
-- Doors/Containers the player is plainly aiming at (and reports the door frame
-- or terrain instead), so MagExp never receives a types.Door/types.Container
-- hitObject and its lock/unlock (Open/Lock) handler never runs.
--
-- This mirrors the framework's own SharedRay pattern (and the engine's focus
-- object): cast the rendering ray once per frame in onFrame and cache the
-- result; the onUpdate cast path consumes it, with a physics castRay kept as a
-- same-context fallback.
local cachedLookRay = { hit = false, hitPos = nil, hitNormal = nil, hitObject = nil }
local cachedLookStart = nil
local cachedLookEnd   = nil

-- The forward the *rendered view* looks along, from the angles the engine
-- builds that view out of (camera.getOrient() = roll * pitch * yaw applied to
-- +Y, mwrender/camera.cpp). Roll spins the picture around this axis, it never
-- moves it, so yaw and pitch -- including the extra angles a mod or the
-- knock-down camera adds -- are the whole story.
local function cameraForwardFromAngles()
    local pitch    = -(camera.getPitch() + camera.getExtraPitch())
    local yaw      =   camera.getYaw()  + camera.getExtraYaw()
    local cosPitch = math.cos(pitch)
    return util.vector3(
        cosPitch * math.sin(yaw),
        cosPitch * math.cos(yaw),
        math.sin(pitch))
end

-- ── The crosshair ray (origin, far end) ───────────────────────────────────
-- Everything that aims has to sit on ONE line: the line the crosshair is
-- drawn on. Origin and direction therefore have to come from the same view.
--
-- camera.viewportToWorldVector(0.5, 0.5) looks like it hands back that line
-- in one call, and on its own it does not. The engine returns
--
--     (invertedViewMatrix * (0, 0, -1)) - camera.getPosition()
--
-- -- the world point one unit in front of the camera, *measured from
-- camera.getPosition()*. Those are not the same camera. In first person the
-- view matrix is rebuilt during the cull traversal from the neck animation
-- with the position the head has this frame, while camera.getPosition()
-- still carries the head of the frame before it:
--
--     "It is a hack. Camera position depends on neck animation. [...] Note
--      that it becomes different from mPosition that is used in other parts
--      of the code."                              (mwrender/camera.cpp)
--
-- so what comes back is  forward + (renderedCamera - camera.getPosition())  --
-- a *direction* skewed by a position difference. That is not the harmless
-- error a shifted origin would be. The spell leaves the casting hand and is
-- converged on the point this ray finds, so a skewed direction tilts the
-- whole trajectory away from the crosshair and the miss grows with every unit
-- it flies: dead on across a room, a hand's width to one side of a wall 60
-- metres off, always to the same side because a cast animation always moves
-- the head the same way.
--
-- So each half is taken from where it is exact:
--   * the direction is the camera orientation -- the very forward the view
--     matrix is built from (see above);
--   * the origin is camera.getPosition() moved onto the rendered camera by
--     the difference the engine's own vector reports, so the two describe
--     the same view again. The correction is only applied while it is on the
--     scale of a camera moving inside one frame; anything larger means this
--     build scales the vector differently, and the derived ray (parallel to
--     the crosshair, off by that same small distance) is kept instead.
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

    -- castRenderingRay is only legal in a frame context, and refreshLookRay()
    -- is called from onFrame alone, so the call is legal here. A nil result
    -- still just means "no hit this frame".
    local res = nearby.castRenderingRay(camPos, rayEnd, { ignore = self })
    if not res then
        -- Rendering ray unavailable this frame (e.g. called outside a frame
        -- context). Leave the previous cache intact; onUpdate will fall back
        -- to its physics ray.
        return
    end
    cachedLookRay = {
        hit       = res.hit and true or false,
        hitPos    = res.hitPos,
        hitNormal = res.hitNormal,
        hitObject = res.hitObject,
    }
end

-- Returns a ray result for the crosshair look target. Prefers the rendering
-- ray cached in onFrame (what the player actually sees — the engine's own
-- touch/activation target); falls back to a physics castRay, which is the only
-- raycast legal from this onUpdate context.
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
-- If the crosshair ray did not hit a valid living actor, find the nearest living actor
-- within melee reach (fCombatDistance * fHandToHandReach) and within the combat tolerance
-- angles (derived from fCombatAngleXY / 90.0 and fCombatAngleZ / 90.0) with line of sight.
local function getHitContactActor(cameraPos)
    local reach = GMST.fCombatDistance * GMST.fHandToHandReach
    local fCombatAngleXY = GMST.fCombatAngleXY / 90.0
    local fCombatAngleZ = GMST.fCombatAngleZ / 90.0

    local actorPos = self.position
    local eyePos = cameraPos or (actorPos + util.vector3(0, 0, 100))
    local pitch = -(camera.getPitch() + camera.getExtraPitch())
    local yaw = camera.getYaw() + camera.getExtraYaw()
    local actorDirXY = util.vector3(math.sin(yaw), math.cos(yaw), 0):normalize()
    local actorVerticalAngle = math.sin(pitch)

    local selfHalfZ = 0
    local selfHalfY = 0
    if self.getBoundingBox then
        local selfBBox = self:getBoundingBox()
        if selfBBox and selfBBox.halfSize then
            selfHalfZ = selfBBox.halfSize.z
            selfHalfY = selfBBox.halfSize.y
        end
    end

    local canMoveByZ = isSwimmingActor(self)
    if not canMoveByZ then
        local levitate = types.Actor.activeEffects(self):getEffect(core.magic.EFFECT_TYPE.Levitate)
        if levitate and levitate.magnitude > 0 then
            canMoveByZ = true
        end
    end

    local bestActor = nil
    local minDist = math.huge

    local actorsList = nearby.actors or {}
    for _, target in ipairs(actorsList) do
        if target ~= self and not types.Actor.isDead(target) then
            local targetPos = target.position
            local targetHalfZ = 0
            local targetHalfY = 0
            if target.getBoundingBox then
                local targetBBox = target:getBoundingBox()
                if targetBBox and targetBBox.halfSize then
                    targetHalfZ = targetBBox.halfSize.z
                    targetHalfY = targetBBox.halfSize.y
                end
            end

            local dist = (targetPos - actorPos):length() - selfHalfY - targetHalfY
            if dist < 0 then dist = 0 end

            local heightDiff = math.abs(actorPos.z - targetPos.z)
            if dist < minDist and dist < reach and heightDiff < reach then
                local dx = targetPos.x - actorPos.x
                local dy = targetPos.y - actorPos.y
                local lenXY = math.sqrt(dx * dx + dy * dy)
                if lenXY > 0 then
                    local targetDirXYx = dx / lenXY
                    local targetDirXYy = dy / lenXY

                    -- Must be in front (dot product > 0)
                    local dotFront = targetDirXYx * actorDirXY.x + targetDirXYy * actorDirXY.y
                    if dotFront > 0 then
                        -- Horizontal tolerance: perp dot product <= fCombatAngleXY
                        local perpDot = math.abs(targetDirXYx * actorDirXY.y - targetDirXYy * actorDirXY.x)
                        if perpDot <= fCombatAngleXY then
                            local zCheckPassed = true
                            if not canMoveByZ then
                                local targetFeet = targetPos - eyePos
                                local targetHead = targetFeet + util.vector3(0, 0, targetHalfZ * 2.0)
                                local feetLen = targetFeet:length()
                                local headLen = targetHead:length()
                                local feetZ = feetLen > 0 and (targetFeet.z / feetLen) or 0
                                local headZ = headLen > 0 and (targetHead.z / headLen) or 0

                                if (actorVerticalAngle - headZ > fCombatAngleZ)
                                    or (actorVerticalAngle - feetZ < -fCombatAngleZ) then
                                    zCheckPassed = false
                                end
                            end

                            if zCheckPassed then
                                -- Check line of sight from eye to target center
                                local targetCenter = targetPos + util.vector3(0, 0, targetHalfZ)
                                local losRay = nearby.castRay(eyePos, targetCenter, { ignore = self })
                                if not losRay.hit or losRay.hitObject == target
                                    or (losRay.hitPos and (losRay.hitPos - targetCenter):length() < 30) then
                                    minDist = dist
                                    bestActor = target
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return bestActor
end

-- Forward declaration: processPendingLaunches is defined after onUpdate (split
-- out to stay under LuaJIT's 60-upvalue cap). Without this, the call at the
-- end of onUpdate resolves to a nil global and fails every frame.
local processPendingLaunches

-- ── onUpdate ──────────────────────────────────────────────────────────────
local function onUpdate(dt)
    reconcileShieldWeapon()
    -- Keep the mid-cast combat/attack locks in sync with the cast state, the
    -- equipped weapon and the settings.
    reconcileCombatBlock()
    reconcileWeaponAttackLock()

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
        and not Stance.spellStanceAllowed then
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
            -- Quickkey-only scope: put the raise back down ONLY inside the
            -- quickkey window — a pending press, or a cast a quickkey started
            -- that is still in flight. The engine re-applies a quickkey (and
            -- re-raises the stance with it) while its own cast runs, so
            -- without the cast half of the window the spell stance stood on
            -- screen for the whole gesture — the reported "spamming the
            -- quickkey still turns spell stance on". A stance raised any
            -- other way (R key, menu, inventory, hotbar click, another mod)
            -- is the player's own doing and is left up: with the window
            -- closed, nothing here can touch any stance, so the manual stance
            -- can never be eaten across the frame.
            if Stance.quickkeyWindowActive() then
                debugLog("[OSSC Stance] Late Spell stance raise reverted (update mirror)")
                types.Actor.setStance(self, Stance.quickkeyRevertTarget())
            end
        elseif updateStance == STANCE.Weapon or updateStance == STANCE.Nothing then
            Stance.lastNonSpellStance = updateStance
        end
    end

    -- An attack may be queued by the engine before the animation-controller
    -- callback gets a chance to cancel it. Repeat the cancel while the cast
    -- owns the hands; this closes the same one-frame queueing race as the
    -- control switch and also catches attacks started by another mod.
    if shouldBlockHeavyAttack() then
        for _, groupName in ipairs(HEAVY_ATTACK_GROUPS) do
            if anim.isPlaying(self, groupName) then
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

    -- The player, NPCs and eligible creatures must obey the same interruption rule:
    -- if an incapacitation / stagger / knockdown state lands before the cast
    -- has released, cancel the quickcast immediately instead of letting the
    -- wind-up stay active until a later release/safety timer check.
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
        -- I.UI.setMode('Interface') is not reflected synchronously by getMode().
        -- Wait briefly for the engine to enter Interface mode before treating
        -- nil as a cancellation. Otherwise OSSC can destroy the PMM window on
        -- the update immediately after creating it.
        if uiMode ~= 'Interface' and PMM.pmmUiOpenedAt
            and core.getSimulationTime() - PMM.pmmUiOpenedAt < 0.25 then
            -- Let the cast animation finish on its own: the window only
            -- opens after the 'release' key, so the casting already happened
            -- and there is nothing left to hold back.
            Cast.castStartTime = core.getSimulationTime()
            return
        end
        if uiMode == 'Interface' then
            -- Don't freeze the cast animation here. The window opens after
            -- the 'release' key, but the animation may still be playing its
            -- tail; pausing it would leave the actor stuck in the cast pose
            -- after the cast lock is released.
            for _, onFrameFunction in pairs(onFrameFunctions or {}) do
                onFrameFunction(dt)
            end
            Cast.castStartTime = core.getSimulationTime()
            return
        else
            -- Interface mode ended without a mark being picked (e.g. the
            -- player pressed Esc). Make sure the window is gone and cancel
            -- the cast: with Pure Multi Mark Compatibility enabled the
            -- vanilla mark must not go through, so there is no fallback to
            -- a standard Recall.
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
                -- ── Stagger / knockdown interruption ─────────────────────
                -- Vanilla cancels the cast when the caster is staggered; a
                -- stagger or knock that lands mid-animation cancels the OSSC
                -- cast here (before any cost is paid) instead of launching.
                if isStaggeredOrKnocked() then
                    debugLog("Launch cancelled — staggered or knocked mid-cast")
                    -- Only the CURRENT cast's launch may tear the cast state
                    -- down. A previous cast's late launch is simply dropped:
                    -- fullCleanup here would kill the new cast that just
                    -- started while the old launch was still queued.
                    if pl.castId == Cast.currentCastId then
                        fullCleanup("staggered/knocked mid-cast")
                    end
                    break
                end

                -- `== false`, not `not`: a queued launch that carries no
                -- isPaid field at all must not be read as "out of magicka".
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
                            -- PMM_loadLoc is PMM's own teleport event (handled by
                            -- PMM's global script). OSSC_PMMTeleport is handled by
                            -- ossc_global.lua with identical logic, so the recall
                            -- works even if PMM's global script is missing or
                            -- disabled. Both teleport to the exact same spot; if
                            -- both run, the second call is a no-op.
                            core.sendGlobalEvent('PMM_loadLoc', { self, selectedLocation })
                            core.sendGlobalEvent('OSSC_PMMTeleport', { self, selectedLocation })
                            debugLog(string.format(
                                '[OSSC PMM] Teleporting to selected mark %s (%s)',
                                tostring(selectedLocation.name),
                                tostring(selectedLocation.cell or
                                    (selectedLocation.gridX .. '/' .. selectedLocation.gridY))))
                            if I.SkillProgression and I.SkillProgression.skillUsed then
                                I.SkillProgression.skillUsed('mysticism', {
                                    skillGain = 3,
                                    useType = I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success,
                                })
                            end
                            self:sendEvent('OSSC_OnSpellCast', { spellId = spell.id })
                        else
                            -- The forward the view looks along — the same one the
                            -- crosshair ray below is built from, so the casting
                            -- hand is placed with the view that aims the spell.
                            local cameraDir = cameraForwardFromAngles()
                            local flatForward = util.vector3(cameraDir.x, cameraDir.y, 0):normalize()
                            local leftDir     = util.vector3(-flatForward.y, flatForward.x, 0)
                            local startPos
                            if hasEternalGrimoire() then
                                -- ── Grimoire spawn offsets (right-hand cast) ──────────
                                -- One global set for all animations; see
                                -- scripts/ossc/ossc_launch_offsets.lua to edit it.
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
                                -- ── Normal spawn offsets (left-hand cast) ─────────────
                                -- Per-animation offsets; see scripts/ossc/ossc_launch_offsets.lua
                                -- to tune every animation separately (1st and 3rd person).
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

                            -- Aim along the crosshair line as it is *now*, not the
                            -- one cached when the frame started (see
                            -- getCameraAimRay). The cache is from onFrame; the
                            -- world update in between moves the camera, and the
                            -- hand the spell leaves is read from the camera after
                            -- that too. A line taken a frame early is a line the
                            -- crosshair has already left: the launch converges on
                            -- a point beside the one the player is aiming at, and
                            -- a turned-away line (the player swinging round onto a
                            -- target as the cast releases) misses by an angle --
                            -- an error that grows with the distance to the target.
                            local cameraPos, endPos = getCameraAimRay()
                            -- This code runs from onUpdate, where OpenMW does NOT
                            -- permit castRenderingRay (it throws outside frame/input
                            -- processing). Use the crosshair rendering ray cached in
                            -- onFrame (refreshLookRay) — it hits exactly what the
                            -- player sees, including thin Door/Container panels, and
                            -- is the same targeting source vanilla uses for Touch
                            -- spells (World::getFocusObject). A same-context physics
                            -- castRay is used as a fallback when the cache is empty;
                            -- it is also the query used by the off-centre Touch fan
                            -- rays below.
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
                                local contactActor = getHitContactActor(cameraPos)
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
                                        -- Same onUpdate restriction as the primary
                                        -- query above: use the physics ray directly.
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
                            -- Fallback: if touch spell hit an inanimate object (e.g. background wall/door/floor)
                            -- or a dead actor instead of a living actor, run OpenMW's getHitContact fallback
                            -- to find an eligible living target within reach and tolerance angles.
                            if range == RANGE.Touch and (not hitObject or (hitObject.type ~= types.NPC and hitObject.type ~= types.Creature)) then
                                local contactActor = getHitContactActor(cameraPos)
                                if contactActor then
                                    hitObject = contactActor
                                end
                            end
                            local aimPoint       = ray.hit and ray.hitPos or endPos
                            local distFromPlayer = (aimPoint - self.position):length()
                            -- ── Parallax convergence ──────────────────────────
                            -- The spell does not leave the eye, it leaves the
                            -- casting hand (startPos, up to ~80 units to the side
                            -- of the camera). Aiming it at the crosshair point is
                            -- therefore a convergence problem: the trajectory
                            -- crosses the crosshair line exactly ONCE, at the
                            -- point it was converged on. Before that point it is
                            -- offset toward the hand, after it the same offset
                            -- appears mirrored on the other side and keeps
                            -- growing with distance.
                            --
                            -- So the convergence point has to be where the spell
                            -- really stops, and the projectile stops on PHYSICS
                            -- geometry, while the crosshair ray above is a
                            -- RENDERING ray (it must be: it is what the player
                            -- sees and what the engine uses to pick a Touch
                            -- target). The two disagree whenever the visible
                            -- surface is nearer than the collision surface —
                            -- foliage, glass, banners and other non-collidable
                            -- decoration, an actor's visual mesh in front of its
                            -- capsule, or a dead actor the projectile flies
                            -- through. Converging on the visual hit in those
                            -- cases makes the spell land beside the crosshair,
                            -- further off the further away the real target is.
                            --
                            -- Keep the rendering hit for target selection, and
                            -- converge the launch direction on the first physics
                            -- obstacle the projectile can actually collide with.
                            local convergePoint = aimPoint
                            do
                                local from = cameraPos
                                local aimDir = (endPos - cameraPos):normalize()
                                for _ = 1, 4 do
                                    local physRay = nearby.castRay(from, endPos, { ignore = self })
                                    if not (physRay.hit and physRay.hitPos) then break end
                                    -- The projectile passes through dead actors;
                                    -- their capsules must not converge the aim.
                                    local o = physRay.hitObject
                                    local t = o and o.type
                                    local isDeadActor = (t == types.NPC or t == types.Creature)
                                        and types.Actor.isDead(o)
                                    if not isDeadActor then
                                        convergePoint = physRay.hitPos
                                        break
                                    end
                                    from = physRay.hitPos + aimDir * 2
                                end
                            end
                            local skewedDir      = (convergePoint - startPos):normalize()
                            if range == RANGE.Touch and hitObject then
                                local fMaxActivateDist = GMST.iMaxActivateDist
                                local maxDist = fMaxActivateDist + camera.getThirdPersonDistance() + 25
                                local telekinesis = types.Actor.activeEffects(self)
                                     :getEffect(core.magic.EFFECT_TYPE.Telekinesis)
                                if telekinesis then maxDist = maxDist + telekinesis.magnitude*22 end
                                local distFromEye = (aimPoint - cameraPos):length()
                                if distFromEye > maxDist then hitObject = nil end
                            end
                            local spawnOffset = 80
                            local distFromStart = (aimPoint - startPos):length()
                            if (hitObject or ray.hit) and distFromPlayer < 200 then spawnOffset = 10 end
                            if ray.hit and spawnOffset >= distFromStart then
                                spawnOffset = math.max(5, distFromStart - 10)
                            end
                            local kineticSpells = { kinetic_bolt = true, kinetic_expl = true }
                            -- Friendlier Fire: never launch a harmful quick-cast at a
                            -- follower/summon. Spell Framework Plus applies OSSC casts
                            -- from Lua (ActiveSpells:add()), which bypasses FF's sweep,
                            -- so OSSC must detect friendly fire before firing instead
                            -- of relying on FF to clean up afterwards.
                            local friendlyFireBlocked = false
                            if hitObject and types.Actor.objectIsInstance(hitObject) then
                                friendlyFireBlocked = friendlyFire.isFriendlyFireBlocked(self, hitObject, spell.effects)
                            end
                            if friendlyFireBlocked then
                                debugLog("Cast vetoed — friendly fire: " .. tostring(spell.id) .. " -> " .. tostring(hitObject and hitObject.recordId or "nil"))
                            end
                            -- ── Swimming fizzle (vanilla parity) ─────────────
                            -- A target-range quick-cast released while the caster
                            -- is swimming always fails, exactly like vanilla:
                            -- the gesture plays, the magicka paid at animation
                            -- start stays consumed, and the spell fizzles at the
                            -- release moment with the vanilla failure sound —
                            -- no projectile, no message, no skill XP, no power
                            -- cooldown. Self- and Touch-range casts are
                            -- unaffected, and merely WADING (feet in water)
                            -- never counts as swimming.
                            local swimmingFizzle = false
                            if Cfg.general and Cfg.general:get('BlockTargetSpellsWhileSwimming')
                                and hasTargetRangeEffect(spell) and isSwimmingActor(self) then
                                swimmingFizzle = true
                                debugLog("Launch fizzled — swimming: target-range spells always fail (vanilla parity), magicka stays consumed")
                                core.sound.playSound3d("Spell Failure", self, { volume = 1.0 })
                            end

                            local sentCastRequest = false
                            if swimmingFizzle then
                                -- Vanilla parity: guaranteed fizzle — nothing
                                -- launches, the paid magicka is not refunded.
                            elseif not friendlyFireBlocked and not kineticSpells[spell.id] then
                                -- 'skill_based': the penalty follows the cast
                                -- skill (0 → 50%, 100+ → none), Enchant for
                                -- items; anything else is a flat percentage.
                                local effectMode = Cfg.general and Cfg.general:get('QuickCastEffectPenalty')
                                local effectScale
                                if effectPenaltyExempt(spell) then
                                    -- Powers are always full strength; so are
                                    -- scrolls while the exclusion toggle is on.
                                    effectScale = 1.0
                                elseif Penalty.isSkillBased(effectMode) then
                                    local effectSchool = spell.item and 'enchant'
                                        or getDominantSkillSchool(spell) or 'destruction'
                                    effectScale = Penalty.skillScale(
                                        getMagicSkillValue(self, effectSchool, spell.item ~= nil))
                                else
                                    effectScale = getPenaltyScale(effectMode)
                                end
                                -- A spell's magicka was already paid at ANIMATION
                                -- START (handleCastCosts — through the framework's
                                -- consumeSpellCost when it is registered, from
                                -- OSSC's own pocket otherwise), so the launch must
                                -- be marked prepaid: isFree = true keeps Spell
                                -- Framework Plus' launch-time resource guard from
                                -- charging the release a second time. An enchanted
                                -- item is the exception — its charge can only be
                                -- written from a global script, so the deduction
                                -- stays with SFP's guard at launch (isFree = false).
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

                                -- The source object must always be the caster
                                -- itself, Self-range included: Spell Framework
                                -- Plus' MagExp_CastRequest handler validates
                                -- `type(data.attacker) == 'userdata'` and rejects
                                -- the whole request when it is not an object
                                -- (launchSpell requires an attacker too — the
                                -- history comment about "self casts pass
                                -- attacker == nil" described a contract that was
                                -- never actually accepted).  A nil attacker for
                                -- a Self-range quick cast therefore meant the
                                -- spell silently never happened at all — no
                                -- summon, no bound item, no heal — with every
                                -- effect-penalty mechanic downstream (registry
                                -- sweep, stat scaling, item swap) starved of its
                                -- cast.  Every other sender in this repo (NPC
                                -- quick-casts, item casts) already passes self.
                                core.sendGlobalEvent('MagExp_CastRequest', {
                                    attacker     = self,
                                    caster       = self,
                                    spellId      = spell.id,
                                    startPos     = startPos,
                                    direction    = skewedDir,
                                    area         = spell.area,
                                    isFree       = not isEnchantment,
                                    item         = spell.item,
                                    itemRecordId = spell.item and spell.item.recordId or nil,
                                    hitObject    = hitObject,
                                    -- Exact crosshair impact point. Spell Framework
                                    -- Plus uses it to shorten the projectile spawn
                                    -- offset at point-blank range, so a spell fired
                                    -- at something right in front of the player can
                                    -- no longer spawn past it.
                                    hitPos       = (ray.hit and ray.hitPos) or nil,
                                    spawnOffset  = spawnOffset,
                                    isGodMode    = debug.isGodMode(),
                                    effectScale  = effectScale,
                                    showAllCastVfx = showAll,
                                    userData     = { OSSC = true },
                                })
                                sentCastRequest = true
                                self:sendEvent('OSSC_OnSpellCast', { spellId = spell.id })
                            end

                            -- ── Skill Progression Backend ─────────────────────────────────────
                            local xpGain = Cfg.general and Cfg.general:get('SkillExperience') or 0
                            local spMode = SkillModes.normalize(
                                Cfg.general and Cfg.general:get('SkillProgressionMode'))
                            debugLog("[OSSC] SkillProgressionMode = " .. spMode)

                            -- ──────────────────────────────────────────────────────────────────
                            -- MODE: ossc ── Direct stat mutation (legacy/vanilla).
                            -- Uses the SkillExperience + ExperienceFormula settings.
                            -- No external mod events are fired.
                            -- ──────────────────────────────────────────────────────────────────
                            local function awardSkillXP_OSSC(skillId)
                                local skill = types.NPC.stats.skills[skillId](self)
                                if not skill or skill.base >= 100 then return end
                                local gain = xpGain * 0.01
                                if gain <= 0 then return end
                                local prog = skill.progress + gain
                                local base = skill.base
                                while prog >= 1.00 and base < 100 do
                                    base = base + 1
                                    prog = prog - 1.00
                                    levelUpSkill(skillId, base)
                                end
                                skill.progress = math.max(0, prog)
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
                            local function awardSkillXP_External(skillId, isEnchant)
                                if not (I.SkillProgression and I.SkillProgression.skillUsed) then
                                    debugLog("[OSSC] skillUsed unavailable, falling back to OSSC direct for " .. skillId)
                                    awardSkillXP_OSSC(skillId)
                                    return
                                end
                                local useType = isEnchant
                                    and (I.SkillProgression.SKILL_USE_TYPES.Enchant_UseMagicItem or 1)
                                    or  I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success

                                local options = { useType = useType }
                                if isEnchant then
                                    local baseGain = 0.1
                                    local rec = core.stats.Skill.record(skillId)
                                    if rec and rec.skillGain and rec.skillGain[useType + 1] then
                                        local recVal = rec.skillGain[useType + 1]
                                        if math.abs(recVal - 0.123) > 0.001 then
                                            baseGain = recVal
                                        end
                                    end
                                    options.skillGain = baseGain
                                end

                                -- Delay by 200ms so the animation 'release' text key has time to fire first.
                                async:newUnsavableSimulationTimer(0.2, function()
                                    I.SkillProgression.skillUsed(skillId, options)

                                    local isSkillEvo = SkillModes.isSkillEvolution(spMode)
                                    if isEnchant and not isSkillEvo then
                                        local skillStat = types.NPC.stats.skills[skillId](self)
                                        if skillStat and skillStat.base < 100 then
                                            local factor = core.getGMST("fMiscSkillBonus") or 1.25
                                            local npcRec = types.NPC.record(self)
                                            if npcRec and npcRec.class then
                                                local cls = types.NPC.classes.record(npcRec.class)
                                                if cls then
                                                    local isMajor = false
                                                    for _, s in ipairs(cls.majorSkills or {}) do
                                                        if s == skillId then factor = core.getGMST("fMajorSkillBonus") or 0.75; isMajor = true; break end
                                                    end
                                                    if not isMajor then
                                                        for _, s in ipairs(cls.minorSkills or {}) do
                                                            if s == skillId then factor = core.getGMST("fMinorSkillBonus") or 1.0; break end
                                                        end
                                                    end
                                                    local sRec = core.stats.Skill.record(skillId)
                                                    if sRec and sRec.specialization == cls.specialization then
                                                        factor = factor * (core.getGMST("fSpecialSkillBonus") or 0.8)
                                                    end
                                                end
                                            end
                                            local req = (skillStat.base + 1) * factor
                                            if req <= 0 then req = 1 end

                                            local prog = skillStat.progress + ((options.skillGain or 0.1) / req)
                                            local base = skillStat.base
                                            while prog >= 1.00 and base < 100 do
                                                base = base + 1
                                                prog = prog - 1.00
                                                levelUpSkill(skillId, base)
                                            end
                                            skillStat.progress = math.max(0, prog)
                                        end
                                    end
                                end)
                            end

                            -- ──────────────────────────────────────────────────────────────────
                            -- MODE: sus ── Skill Uses Scaled
                            -- SUS reads its internal pc.spell pointer to compute cost-scaled gain.
                            -- We must patch that pointer to the current OSSC spell BEFORE calling
                            -- skillUsed, then restore it immediately afterwards.
                            -- ──────────────────────────────────────────────────────────────────
                            local function awardSkillXP_SUS(skillId, isEnchant)
                                if not (I.SkillProgression and I.SkillProgression.skillUsed) then
                                    debugLog("[OSSC] SUS: skillUsed unavailable, falling back to OSSC direct for " .. skillId)
                                    awardSkillXP_OSSC(skillId)
                                    return
                                end
                                local useType = isEnchant
                                    and (I.SkillProgression.SKILL_USE_TYPES.Enchant_UseMagicItem or 1)
                                    or  I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success

                                local options = { useType = useType }
                                if isEnchant then
                                    local baseGain = 0.1
                                    local rec = core.stats.Skill.record(skillId)
                                    if rec and rec.skillGain and rec.skillGain[useType + 1] then
                                        local recVal = rec.skillGain[useType + 1]
                                        if math.abs(recVal - 0.123) > 0.001 then
                                            baseGain = recVal
                                        end
                                    end
                                    options.skillGain = baseGain
                                end

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

                                    if isEnchant then
                                        local skillStat = types.NPC.stats.skills[skillId](self)
                                        if skillStat and skillStat.base < 100 then
                                            local factor = core.getGMST("fMiscSkillBonus") or 1.25
                                            local npcRec = types.NPC.record(self)
                                            if npcRec and npcRec.class then
                                                local cls = types.NPC.classes.record(npcRec.class)
                                                if cls then
                                                    local isMajor = false
                                                    for _, s in ipairs(cls.majorSkills or {}) do
                                                        if s == skillId then factor = core.getGMST("fMajorSkillBonus") or 0.75; isMajor = true; break end
                                                    end
                                                    if not isMajor then
                                                        for _, s in ipairs(cls.minorSkills or {}) do
                                                            if s == skillId then factor = core.getGMST("fMinorSkillBonus") or 1.0; break end
                                                        end
                                                    end
                                                    local sRec = core.stats.Skill.record(skillId)
                                                    if sRec and sRec.specialization == cls.specialization then
                                                        factor = factor * (core.getGMST("fSpecialSkillBonus") or 0.8)
                                                    end
                                                end
                                            end
                                            local req = (skillStat.base + 1) * factor
                                            if req <= 0 then req = 1 end

                                            local prog = skillStat.progress + ((options.skillGain or 0.1) / req)
                                            local base = skillStat.base
                                            while prog >= 1.00 and base < 100 do
                                                base = base + 1
                                                prog = prog - 1.00
                                                levelUpSkill(skillId, base)
                                            end
                                            skillStat.progress = math.max(0, prog)
                                        end
                                    end
                                end)
                            end

                            -- ──────────────────────────────────────────────────────────────────
                            -- Top-level dispatcher
                            -- ──────────────────────────────────────────────────────────────────
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

                            local function awardSkillXP(skillId, isEnchant)
                                debugLog("[OSSC] awardSkillXP: id=" .. skillId
                                    .. " enchant=" .. tostring(isEnchant)
                                    .. " mode=" .. spMode)
                                    
                                -- 'none' leaves spellcasting progression entirely
                                -- to another mod, so nothing is awarded here -
                                -- the Incantation award included.  That mod still
                                -- needs to hear that a cast happened, or it has
                                -- nothing to call I.OSSC.awardSkillProgress for.
                                if SkillModes.isDisabled(spMode) then
                                    core.sendGlobalEvent('OSSC_SkillProgressSkipped', {
                                        actor     = self,
                                        skillId   = skillId,
                                        spellId   = spell and spell.id,
                                        cost      = (spell and spell.cost) or 0,
                                        isEnchant = isEnchant == true,
                                    })
                                    return
                                end

                                awardSkillXP_Incantation()

                                if spMode == 'ossc' then
                                    awardSkillXP_OSSC(skillId)
                                elseif SkillModes.isExternal(spMode) then
                                    awardSkillXP_External(skillId, isEnchant)
                                elseif spMode == 'sus' then
                                    awardSkillXP_SUS(skillId, isEnchant)
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

                                if isItem then
                                    awardSkillXP('enchant', true)
                                else
                                    local school = resolveMagicSchool()
                                    if school and MAGIC_SKILLS[school] then
                                        awardSkillXP(school, false)
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
            -- A previous cast's late launch: its state was already unlocked at
            -- its own 'stop' key, and the VFX it left behind share this cast's
            -- vfx ids — the current cast's own launchCleanup/fullCleanup sweeps
            -- them. Touch nothing here, or a cast mid-wind-up loses its spell
            -- state and never launches.
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
        -- ── One cast start per cast (vanilla audio behaviour) ─────────────
        -- The cast sound / cast VFX / safety-launch timer belong to the very
        -- beginning of a cast and must fire exactly once per quickcast.
        -- `hasQueuedLaunch` alone is not enough of a latch: launchCleanup()
        -- clears it the moment the spell is released, so any further 'start'
        -- (or 'equip start') text key that reaches this handler afterwards —
        -- a re-played / re-blended cast animation, an animation that loops
        -- back, or a second animation instance of the same group — re-entered
        -- this branch and played the school cast sound A SECOND TIME, right
        -- at the release. Vanilla plays the cast sound only at cast start;
        -- the release has its own (different) sound. Latch on the cast id and
        -- on hasFiredThisCast so a post-release 'start' can never replay it.
        if Cast.hasFiredThisCast then return end
        if Cast.startKeyCastId == Cast.currentCastId then return end
        if Cast.hasQueuedLaunch then return end
        Cast.startKeyCastId  = Cast.currentCastId
        Cast.hasQueuedLaunch = true

        -- Resource payment is a one-shot transaction for the active cast.
        -- Keep this separate from the animation-start/audio latch so a rapid
        -- re-entry or duplicate start callback cannot debit Magicka/fatigue
        -- twice for the same cast transaction.
        if Cast.costPaidCastId ~= Cast.currentCastId then
            local paid, costMessage = handleCastCosts(Cast.currentSpell)
            Cast.currentIsPaid      = paid
            Cast.currentCostMessage = costMessage
            Cast.costPaidCastId     = Cast.currentCastId
        end
        -- A refused cast has to say why. handleCastCosts only fills in a
        -- message when OSSC was the one that refused; when a casting framework
        -- owns the pool it shows its own toast and returns nil, so the guard
        -- on currentCostMessage is what stops the player getting two.
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

        -- PMM multi mark window: with after-cast behavior the full cast
        -- animation plays first. The window is opened on the 'release' text
        -- key (with a 'stop' key / safety-timer fallback, see below) instead
        -- of here at cast start.

        local safetySpell  = Cast.currentSpell
        local safetyCastId = Cast.currentCastId
        -- Snapshotted with the spell, like castId: the safety launch queue
        -- entry must carry the payment verdict of THIS cast. Reading
        -- Cast.currentIsPaid when the timer fires instead would let a later
        -- cast's (or the default's) value leak into this launch, and dropping
        -- the field entirely made every safety-timer launch read as unpaid —
        -- which failed every cast that resolves through this fallback with
        -- "not enough magicka" (most animation groups never emit a 'release'
        -- text key before the timer runs out).
        local safetyPaid   = Cast.currentIsPaid
        local safetyTimerDuration = 0.96 / Cast.currentFinalSpeed
        -- Re-arm while the PMM recall UI is open: a one-shot timer that
        -- expires during the selection dialog would leave the cast stranded.
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
                -- After-cast PMM recall: the launch is queued when the PMM
                -- window resolves (the window opens on the 'release' key,
                -- or via the 'stop' key / safety fallback), so there is
                -- nothing to do here.
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
            -- After-cast PMM window: the casting just happened at the
            -- 'release' key, so this is the moment to open the multi mark
            -- window. Waiting for the 'stop' key is not reliable — some
            -- animation groups (e.g. qcsnap) carry no 'stop' text key. The
            -- recall launch stays held until the player picks a mark.
            debugLog("'release' — opening PMM multi mark window after the cast")
            openPMMRecallWindow()
            if not PMM.isWaitingForPMMInput then
                -- The window could not be opened (module failed to load) —
                -- openPMMRecallWindow resets isWaitingForPMMInput on failure.
                -- With Pure Multi Mark Compatibility enabled the vanilla
                -- mark must not go through — cancel the recall instead of
                -- falling back to a standard Recall. (pmmDeferredRecall
                -- stays true until the recall resolves, so checking it here
                -- would also destroy a successfully opened window.)
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
            -- Staggered/knocked at the release moment: cancel the cast the
            -- way vanilla does instead of launching the spell.
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
            -- Fallback for animation groups that emit 'stop' but no
            -- 'release' key: the casting is over, so open the multi mark
            -- window here.
            debugLog('[OSSC] Cast complete — opening PMM Recall UI window')
            openPMMRecallWindow()
        end
        if PMM.pmmDeferredRecall and PMM.isWaitingForPMMInput then
            -- The window is up: keep the cast locked (and the combat block
            -- active) until the player picks a mark or closes the window.
            debugLog('[OSSC] PMM window open — holding cast lock until it resolves')
            return
        end
        if PMM.pmmDeferredRecall then
            -- The window could not be opened (module failed to load). With
            -- Pure Multi Mark Compatibility enabled the vanilla mark must
            -- not go through — cancel the recall instead of casting it.
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
--   pendingQuickkeyPageSwitch — the press carried the row-switch modifier
--   pendingQuickkeyEquipment  — equipment snapshot taken at press time, so a
--                               slot that equips something is never a re-cast
--   hotbarSlotOverride(+Time) — the real (row*10+n) slot a hotbar mod says
--                               this press activated; nil = nothing at all
--   hotbarMagicActivation     — { slot, time } when a hotbar mod reports the
--                               press activated a SPELL / ENCHANTED-ITEM tile,
--                               even one whose magic was already selected (a
--                               reselect changes nothing observable — no new
--                               selection id, no stance raise, no equipment
--                               change — so without this signal the press is
--                               indistinguishable from an empty slot and a
--                               fresh load, with no recast markers set yet,
--                               wrongly refuses to cast it)
--   quickkeyVetoUntil         — a hotbar mod consumed the press for something
--                               that is not a cast (works regardless of which
--                               mod's input handler the engine runs first)
local pendingQuickkeyPageSwitch = false
local pendingQuickkeyEquipment  = nil
local pendingQuickkeyPressTime  = 0
local hotbarSlotOverride        = nil
local hotbarSlotOverrideTime    = 0
local hotbarMagicActivation     = nil
local quickkeyVetoUntil         = 0
local QUICKKEY_VETO_WINDOW      = 0.15
local HOTBAR_SLOT_MATCH_WINDOW  = 0.5

-- Wall clock for hotkey timing
local function realTimeNow()
    return core.getRealTime()
end

-- ── Row-switch modifier detection ────────────────────────────────────────
-- Mirrors QuickSelect Ultimate's own rule (SettingsQuickSelectKeyboard /
-- barSelectionMode + hotbarCount, see QuickSelect_p.lua) so a row switch is
-- never mistaken for a cast request. When no paged hotbar mod is installed
-- the check falls back to "any modifier is held": vanilla quick keys have no
-- modifier meaning either, and the result only gates the ambiguous
-- "nothing changed" re-cast below — a real activation (selection change or
-- Spell stance raised) still casts.
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

    -- Row switching only uses keys 1..hotbarCount; the other keys always
    -- activate a slot on the visible row.
    if slotIndex < 1 or slotIndex > maxBars then return false end
    if mode == 'Ctrl Modifier'  then return heldCtrl  end
    if mode == 'Alt Modifier'   then return heldAlt   end
    if mode == 'Shift Modifier' then return heldShift end
    return false
end

-- ── Equipment snapshot ───────────────────────────────────────────────────
-- A hotbar slot that equips something (weapon / armour / potion / …) is not a
-- request to re-cast whatever magic happens to stay selected. Comparing the
-- equipment at press time and at resolve time catches exactly that — including
-- another row's slot 1 that holds a plain item while the previous row's slot 1
-- held the enchanted weapon.
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

-- ── Previous-frame baseline for quickkey change detection ─────────────────
-- The engine's ActionManager::executeAction runs the NATIVE quickkey first
-- (selection + setDrawState(Spell)) and only afterwards queues the Lua input
-- callbacks — so by the time handleQuickkeyPress runs, getSelectedSpell /
-- getSelectedEnchantedItem / getStance / equipment already describe the
-- POST-press state. Change detection against a snapshot taken in the handler
-- can therefore never fire for an immediate quickkey (previous == current by
-- construction, and the stance at handler time is always already Spell).
-- Capture the baseline at the END of every onFrame instead — after
-- suppression has reverted any automatic stance — so the handler always
-- compares against the true pre-press state. Called at every onFrame exit
-- (all early returns included, and even when the quickkeys/stance settings
-- are off, so a later re-enable starts from a fresh baseline rather than a
-- stale one).
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
    if realTimeNow() < quickkeyVetoUntil then
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
    quickkeyPreviousSpellRecordId = Stance.prevFrameSpell
    quickkeyPreviousItemRecordId  = Stance.prevFrameItem

    QuickkeyPress.slot                  = slotIndex
    QuickkeyPress.timer                 = onCooldown and 0.05 or 0.25
    QuickkeyPress.startedInSpellStance  = (Stance.prevFrameStance == STANCE.Spell)
    QuickkeyPress.prePressStance        = Stance.prevFrameStance
    QuickkeyPress.sawSpellStance        = false
    QuickkeyPress.blockedByCooldown    = onCooldown
    -- A press that turns out not to cast must not inherit a restore target left
    -- over from an earlier cast that never reached animUnlock. A press that
    -- arrives while a quickkey cast IS in flight (spamming the key) must not
    -- steal that cast's target either: animUnlock is the only place that puts
    -- the pre-press stance back, so clearing it here left the player in the
    -- engine's Spell stance for good — the reported "spamming the quickkey
    -- still leaves me in spell stance". The stale-target cleanup therefore
    -- only runs when no cast is in flight, and an in-flight cast keeps its
    -- target for animUnlock (Stance.quickkeyWindowActive uses the same test).
    if not Cast.isCasting then
        Stance.postCastRestore          = nil
    end
    pendingQuickkeyPressTime            = realTimeNow()
    pendingQuickkeyEquipment            = Stance.prevFrameEquipment
    pendingQuickkeyPageSwitch           = hotbarRowSwitchPressed(slotIndex)

    debugLog("[OSSC Hotkey] QuickKey PRESS accepted: slot="
        .. tostring(slotIndex)
        .. " prevSpell=" .. tostring(quickkeyPreviousSpellRecordId)
        .. " prevMagicItem=" .. tostring(quickkeyPreviousItemRecordId)
        .. " startedInSpellStance="
        .. tostring(QuickkeyPress.startedInSpellStance)
        .. " rowSwitchModifier=" .. tostring(pendingQuickkeyPageSwitch)
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

    -- Mid-cast heavy-weapon attack cancellation (BlockWeaponDuringQuickcast):
    -- if the player starts a 2H / bow / crossbow attack while the cast
    -- animation has the hands busy, cancel it so the attack never plays over
    -- the cast. This is the smooth backup to the Fighting control switch and
    -- also covers a 1-tap attack that gets through the switch.
    -- One-handed / hand-to-hand / thrown groups are intentionally never
    -- cancelled here — they must play (and finish) through a quickcast.
    if I.AnimationController.addPlayBlendedAnimationHandler then
        I.AnimationController.addPlayBlendedAnimationHandler(function(groupname, options)
            if type(groupname) ~= 'string' then return end
            -- ── Native spell-stance VFX suppression (pre-play veto) ──────────
            -- Veto the engine's 'spell' / 'spellcast' equip animation when the
            -- player is NOT in an OSSC quickcast. This prevents the engine from
            -- spawning cast VFX on the hands when just readying spell stance.
            -- OSSC casts use their own animation groups, so this never affects
            -- an actual quickcast.
            --
            -- Inside an OSSC quickcast the veto stays on for the QUICKKEY
            -- window: the engine re-applies a spammed quickkey while the cast
            -- it started is still running, and the native equip animation that
            -- comes with that re-raise is the whole-actor twitch on every spam
            -- press — the re-initiation the dedicated quick-cast button never
            -- shows, because that key touches no engine draw state. A manual
            -- spell stance (R) keeps its vanilla equip animation.
            --
            -- Scoped to SuppressSpellStance: with the setting OFF, hotkeys and
            -- the ready-magic key must raise the spell stance EXACTLY like
            -- vanilla — the equip animation is what visibly brings the hands
            -- up, and skipping it made quickkey stance raises look like
            -- nothing happened. The blockade owns quickkey stances only while
            -- the setting is on.
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
            -- Hard allow-list: never touch light attack groups, even if a
            -- future change broadens shouldBlockHeavyAttack.
            for _, g in ipairs(LIGHT_ATTACK_GROUPS) do
                if groupname == g then return end
            end
            -- Heavy attack cancel: 2H/bow/crossbow attacks blocked mid-cast.
            if shouldBlockHeavyAttack() then
                for _, g in ipairs(HEAVY_ATTACK_GROUPS) do
                    if groupname == g then
                        -- Only cancel actual attacks, NOT weapon equip/draw/holster animations.
                        -- Equip/draw animations use stopkey "equip stop"; attack animations use "stop".
                        -- Without this guard, a bound-weapon spell that auto-equips the weapon
                        -- mid-cast has its draw animation cancelled, leaving the mesh invisible.
                        local sk = type(options) == 'table' and type(options.stopkey) == 'string'
                                   and options.stopkey or ''
                        if sk:find('equip') then
                            debugLog("Allowed " .. g .. " equip/draw animation during quickcast (not an attack)")
                            return
                        end
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

    -- ── Hit / Death animation abort ────────────────────────────────────────
    -- If the caster takes a hit or dies while quickcasting, abort the cast
    -- immediately so the hit / death animation is not fighting the cast anim.
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

    local hitDeathGroups = {
        'hit1','hit2','hit3','hit4','hit5',
        'death1','death2','death3','death4','death5',
        'swimhit','swimdeath1',
    }
    for _, g in ipairs(hitDeathGroups) do
        I.AnimationController.addTextKeyHandler(g, onHitDeathTextKey)
    end

    I.AnimationController.addTextKeyHandler('egidle2', onegidle2TextKey)

    -- ── Native Spell Stance VFX Suppression ────────────────────────────────
    -- When entering spell stance natively (e.g. via ready weapon key or hotbar)
    -- without SpeedyMagick, the engine plays the 'spell' and 'spellcast' equip
    -- animations and natively spawns the cast VFX on the hands at 'equip start'.
    -- Cancelling these animations at that text key prevents the VFX from
    -- appearing when just readying spell stance (as opposed to actually casting
    -- via OSSC, which uses its own animations).
    --
    -- Scoped to SuppressSpellStance: with the setting OFF the native spell
    -- stance must be indistinguishable from vanilla — hotkeys and the
    -- ready-magic key raise the hands and play the native equip animations and
    -- hand VFX, so nothing may cancel them.
    local function suppressStanceVfx(groupname, key)
        -- Suppress outside an OSSC quickcast — OSSC casts use their own
        -- animation groups and are never cancelled here — and also inside one
        -- while the QUICKKEY window is open: a quickkey press during its own
        -- cast makes the engine re-ready the stance, and the equip animation
        -- it re-plays is the whole-actor twitch seen on every spam press. A
        -- manual spell stance (spellStanceAllowed) is the player's own and is
        -- never touched.
        if Cast.isCasting
            and (Stance.spellStanceAllowed or not Stance.quickkeyWindowActive()) then
            return
        end
        -- And only while the stance blockade is enabled: with the setting off,
        -- a natively raised spell stance is the player's own (or the engine's
        -- quickkey's) doing and plays out exactly like vanilla.
        if not (Cfg.general and Cfg.general:get('SuppressSpellStance') == true) then return end
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
    restoreShieldAfterCast()
    return {
        powerCooldowns = OSSC_PowerCooldowns,
        pmmLocations = PMM.pmmLocations,
        weaponAttackLockActive = weaponAttackLockActive,
        combatBlockActive = combatBlockActive,
    }
end

local function onLoad(data)
    restoreShieldAfterCast()
    -- External NGarde control is transient engine state and must never survive
    -- loading a save made during a quickcast.
    setNgardeParryControl(false)
    if data and data.powerCooldowns then OSSC_PowerCooldowns = data.powerCooldowns end
    if data and type(data.pmmLocations) == 'table' then PMM.pmmLocations = data.pmmLocations end
    -- The Fighting control switch / combat-control override are engine state
    -- that can survive a save load inside the same session: if the save was
    -- made while one of OSSC's mid-cast locks was engaged, release it
    -- explicitly so attacking is never stuck disabled after the load.
    if weaponAttackLockActive or (data and data.weaponAttackLockActive) then
        weaponAttackLockActive = false
        setWeaponAttackLock(false)
    end
    if combatBlockActive or (data and data.combatBlockActive) then
        combatBlockActive = false
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
    quickkeyPreviousSpellRecordId = Stance.prevFrameSpell
    quickkeyPreviousItemRecordId  = Stance.prevFrameItem
    lastSpellHotkeySlot = nil
    -- No slot has cast an enchanted item in this session yet; require an
    -- actual magic activation (change / spell stance) before the first cast.
    lastMagicItemHotkeySlot = nil
    debugLog("onLoad — QuickKey tracking initialised from current selection: spell="
        ..tostring(quickkeyPreviousSpellRecordId).." item="..tostring(quickkeyPreviousItemRecordId))
end

--- item and spell in these opts are ids, because we can't serialize full game objects to pass to events
local function OSSC_QuickCast_Handler(opts)
    if not opts then
        triggerQuickCast()
        return
    end

    --get item by id
    if opts.item then
        local id = opts.item
        local items = types.Actor.inventory(self):getAll()
        for _, item in ipairs(items) do
            if item.id == id and item:isValid() then
                opts.item = item
                break
            end
        end
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
    -- Refresh the crosshair look target every frame. castRenderingRay is only
    -- legal here (frame/input context); the onUpdate cast path uses the cached
    -- result. Must run before the early-return below so Touch targeting works
    -- regardless of the quickkeys/stance settings.
    refreshLookRay()

    local isQuickkeysOn  = (Cfg.general and Cfg.general:get('CastOnQuickkeys') == true)
    local isStanceBlockOn = (Cfg.general and Cfg.general:get('SuppressSpellStance') == true)
    if not (isQuickkeysOn or isStanceBlockOn) then
        -- Nothing below runs while disabled, but the change-detection
        -- baseline must not go stale: a re-enabled CastOnQuickkeys would
        -- otherwise compare its first press against an ancient snapshot.
        updatePrevFrameStore()
        return
    end

    local currentStance = types.Actor.getStance(self)

    -- ── Manual stance keys (R / spell key, F / weapon key) ──────────────────
    -- The engine processes the native ToggleSpell toggle BEFORE Lua runs, so
    -- on the rising edge of the spell key `currentStance` is already the
    -- POST-toggle stance. Enter/exit intent must therefore come from the
    -- stance on the previous frame (Stance.prevStance), never from the
    -- current one: testing `currentStance == STANCE.Spell` here inverts the
    -- intent, and every attempt to LEAVE spell stance is misread as ENTER —
    -- OSSC then calls setStance(Spell) and the stance can never be unequipped
    -- (this bit even with SuppressSpellStance off, while CastOnQuickkeys is on).
    --
    -- The handler lets the engine perform the actual toggle and only maintains
    -- `spellStanceAllowed`, so it can never double-toggle against the native
    -- toggle the engine just consumed. The single exception is ENTER when the
    -- stance did not change at all: the key press produced no native toggle
    -- (consumed or ignored), so the stance is raised explicitly — a single
    -- entry, not a double toggle.
    --
    -- This runs in onFrame, ahead of the suppression check below, so the
    -- suppression always sees the allowance the key press just set — no
    -- revert-then-re-enter flicker across the onFrame/onUpdate boundary.
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

        -- Stance keys are gameplay keys: ignore edges while a menu is open
        -- (the engine ignores the native toggle then too), but still track
        -- the key states so no phantom edge fires when the menu closes.
        local uiMode = ui and ui.activeMode
        if not uiMode and I.UI and I.UI.getMode then uiMode = I.UI.getMode() end
        if uiMode == nil then
            -- Rising edge on spell key: was in spell stance → EXIT,
            -- was out of it → ENTER.
            if spellKeyDown and not Stance.prevSpellKeyDown then
                if Stance.prevStance == STANCE.Spell then
                    Stance.spellStanceAllowed = false
                    debugLog("[OSSC Stance] User pressed Spell stance key to exit spell stance")
                    -- No setStance: the engine already left spell stance for
                    -- this press. An explicit set here would double-toggle
                    -- straight back into it.
                else
                    -- ENTER always works, SuppressSpellStance or not: the
                    -- blockade only owns the stance a QUICKKEY raises, never
                    -- the one the player raises by hand. Mods that need the
                    -- native spell stance (Powers, enchanted items, grimoires,
                    -- ...) must stay able to open it with the Ready-Magic key.
                    -- The allowance set here is what tells the suppression
                    -- below and its onUpdate mirror to leave this stance up.
                    Stance.spellStanceAllowed = true
                    debugLog("[OSSC Stance] User pressed Spell stance key to enter spell stance")
                    if currentStance ~= STANCE.Spell then
                        types.Actor.setStance(self, STANCE.Spell)
                    end
                end
            end

            -- Rising edge on weapon key: cancel spell stance allowance
            -- (the engine performs the stance switch itself).
            if weaponKeyDown and not Stance.prevWeaponKeyDown then
                Stance.spellStanceAllowed = false
                debugLog("[OSSC Stance] Weapon key pressed — clearing spellStanceAllowed")
            end
        end

        -- If the player returned to a non-spell stance by any other means,
        -- the manual allowance is spent. This is plain state tracking, NOT a
        -- key edge, so it must run even while a menu is open: leaving spell
        -- stance from the inventory/magic menu (the engine lowers the stance
        -- itself there) is exactly the case that has to clear it. While this
        -- lived inside the menu guard above, a stale `spellStanceAllowed`
        -- survived the menu and the very next automatic spell stance was
        -- mistaken for a manual one — SuppressSpellStance = ON then silently
        -- stopped suppressing anything for the rest of the session.
        --
        -- The clear is deliberately NOT conditioned on the spell key: manual
        -- spell stance only exists while the stance IS Spell, so whenever the
        -- stance is observed as non-Spell the allowance is necessarily spent —
        -- even if the R channel reads held (key-up swallowed by alt-tab or a
        -- menu transition, a stuck binding, R held through a menu that lowered
        -- the stance). Conditioning on the key here is what let a stale
        -- allowance survive those cases and silently disable suppression.
        --
        -- The test is the LIVE stance, not the frame-start `currentStance`:
        -- the ENTER branch above may have raised the stance itself (engine
        -- toggle consumed), and the manual allowance must survive the very
        -- frame that raised it. It is also never cleared merely because
        -- SuppressSpellStance is ON — that setting blocks quickkey-raised
        -- stances, not the manual one.
        local liveStance = types.Actor.getStance(self)
        if liveStance ~= STANCE.Spell then
            Stance.spellStanceAllowed = false
        end

        Stance.prevSpellKeyDown  = spellKeyDown
        Stance.prevWeaponKeyDown = weaponKeyDown
        -- Re-read after the ENTER branch above: it is the only stance writer
        -- in this block, and prevStance must reflect it. Every other in-frame
        -- stance writer (suppression revert, quickkey revert) refreshes
        -- prevStance itself right after writing.
        Stance.prevStance = liveStance
    end

    -- ── QuickKey pending cast ────────────────────────────────────────────────
    if QuickkeyPress.slot ~= nil then
        -- OpenMW's Magic and MagicItem quickkeys enter Spell stance.
        -- A normal Item quickkey does not. Capture this before OSSC's stance
        -- suppression restores the previous non-spell stance later this frame.
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
            local wasRowSwitch    = pendingQuickkeyPageSwitch
            local blockedByCooldown = QuickkeyPress.blockedByCooldown
            local equipmentAtPress = pendingQuickkeyEquipment
            local pressTime       = pendingQuickkeyPressTime

            QuickkeyPress.slot                  = nil
            QuickkeyPress.timer                 = 0
            QuickkeyPress.startedInSpellStance  = false
            QuickkeyPress.prePressStance        = nil
            QuickkeyPress.sawSpellStance        = false
            QuickkeyPress.blockedByCooldown    = false
            pendingQuickkeyPageSwitch           = false
            pendingQuickkeyEquipment            = nil
            pendingQuickkeyPressTime            = 0

            local function revertQuickkeySpellStance()
                if not Stance.spellStanceAllowed and isStanceBlockOn then
                    local stance = types.Actor.getStance(self)
                    if stance == STANCE.Spell then
                        debugLog("[OSSC Stance] Reverting automatic QuickKey spell stance")
                        -- The revert target comes from the shared helper: for a
                        -- spam press during its own cast, the cast's recorded
                        -- pre-press stance wins over this press's previous-frame
                        -- baseline, which the engine's re-raise can already have
                        -- polluted (see Stance.quickkeyRevertTarget).
                        local targetStance = Stance.quickkeyRevertTarget()
                        types.Actor.setStance(
                            self,
                            targetStance
                        )
                        -- Keep the pre-toggle intent reference exact: this
                        -- frame returns early below without another refresh.
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

            -- These are directional changes: magic became selected.
            -- A selection being cleared does not authorize a cast.
            local spellBecameSelected =
                validSpell
                and currentSpellRecordId
                    ~= quickkeyPreviousSpellRecordId

            local magicItemBecameSelected =
                validMagicItem
                and currentItemRecordId
                    ~= quickkeyPreviousItemRecordId

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
            if hotbarSlotOverrideTime > 0
                and math.abs(hotbarSlotOverrideTime - pressTime)
                    < HOTBAR_SLOT_MATCH_WINDOW then
                effectiveSlot = hotbarSlotOverride
            end
            local equipmentChanged = equipmentChangedSince(equipmentAtPress)

            local magicItemRecast =
                validMagicItem
                and not magicItemBecameSelected
                and effectiveSlot ~= nil
                and effectiveSlot == lastMagicItemHotkeySlot
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
                hotbarMagicActivation ~= nil
                and hotbarMagicActivation.slot == effectiveSlot
                and math.abs(hotbarMagicActivation.time - pressTime)
                    < HOTBAR_SLOT_MATCH_WINDOW

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
                tostring(lastMagicItemHotkeySlot),
                tostring(lastSpellHotkeySlot),
                tostring(wasRowSwitch),
                tostring(equipmentChanged),
                tostring(effectiveSlot),
                tostring(currentSpellRecordId),
                tostring(quickkeyPreviousSpellRecordId),
                tostring(currentItemRecordId),
                tostring(quickkeyPreviousItemRecordId)
            ))

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

            -- The slot whose magic was activated by this press. With a paged
            -- hotbar this is the real (row*10+n) slot, not the physical key.
            local activatedSlot = effectiveSlot or slotIndex

            -- Selected enchanted items take precedence over the previously
            -- equipped ordinary spell.
            if validMagicItem then
                local enchantmentType = selectedItemSpell.type
                local enchantmentTypes = ENCHTYPE

                -- Only manually castable enchantments are eligible.
                -- CastOnStrike and ConstantEffect are equip/proc enchantments.
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
                    if lastMagicItemHotkeySlot == activatedSlot then
                        lastMagicItemHotkeySlot = nil
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
                lastMagicItemHotkeySlot = activatedSlot

                local castIdBefore = Cast.currentCastId
                triggerQuickCast({
                    item           = selectedEnchantedItem,
                    ignoreUIMode   = true,
                    strictOnlyItem = true,
                })
                if Cast.currentCastId ~= castIdBefore then
                    QuickkeyPress.cooldownActive = true
                    -- The press resolved into a real cast, so the quickkey
                    -- handler's own revert paths are already out of scope (its
                    -- slot was cleared above). Remember the stance that existed
                    -- before the engine applied the key so animUnlock can put
                    -- it back when the gesture ends.
                    Stance.postCastRestore = prePressStance
                end

            elseif validSpell then
                debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                    .. " — Magic spell hotkey confirmed; casting "
                    .. tostring(currentSpellRecordId))

                -- A normal spell is now the selected magic (the engine also
                -- clears the selected enchanted item), so no slot holds an
                -- enchantment to recast.
                lastMagicItemHotkeySlot = nil

                -- Record the slot that cast this spell. Only a repeat press of
                -- THIS slot — with the same spell still selected and no other
                -- magic signal — is allowed to re-cast it (see spellRecast).
                lastSpellHotkeySlot = activatedSlot

                local castIdBefore = Cast.currentCastId
                triggerQuickCast({
                    spell           = currentSpellRecordId,
                    ignoreUIMode    = true,
                    strictOnlySpell = true,
                })
                if Cast.currentCastId ~= castIdBefore then
                    QuickkeyPress.cooldownActive = true
                    -- The press resolved into a real cast, so the quickkey
                    -- handler's own revert paths are already out of scope (its
                    -- slot was cleared above). Remember the stance that existed
                    -- before the engine applied the key so animUnlock can put
                    -- it back when the gesture ends.
                    Stance.postCastRestore = prePressStance
                end

            else
                debugLog("[OSSC Hotkey] Slot " .. tostring(slotIndex)
                    .. " — magic activation detected, but no valid magic selected.")

                -- Whatever this slot held is gone (spell removed/unselected,
                -- item swapped out mid-press): forget its markers so a later
                -- no-change press of the same slot cannot resurrect it.
                if lastSpellHotkeySlot == activatedSlot then
                    lastSpellHotkeySlot = nil
                end
                if lastMagicItemHotkeySlot == activatedSlot then
                    lastMagicItemHotkeySlot = nil
                end
            end

            revertQuickkeySpellStance()
            updatePrevFrameStore()
            return
        end
    end

    -- NOTE: there is deliberately NO general suppression of Spell stance
    -- here. The blockade is scoped to QUICKKEY-raised stances only: it owns
    -- the resolve-time revert (revertQuickkeySpellStance, above) and the
    -- pending-gated revert in the onUpdate mirror. A stance raised any
    -- other way — R key, menu, inventory, hotbar click, another mod — is
    -- the player's own doing and is never touched, so the manual stance
    -- can no longer be eaten by a revert racing the stance key across the
    -- onFrame/onUpdate boundary.

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

    -- Same shape as the quick-cast model, so every shared helper (penalty
    -- exemption, dominant school) reads it the same way.
    local firstEffect = record.effects and record.effects[1]
    local spell = {
        id      = spellId,
        type    = record.type,
        cost    = record.cost or 0,
        effects = record.effects,
        area    = firstEffect and firstEffect.area or 0,
        range   = firstEffect and firstEffect.range or RANGE.Self,
    }

    local startPos = self.position
    local direction = self.rotation * util.vector3(0, 1, 0)
    local hitObject, hitPos = nil, nil
    if spell.range == RANGE.Self then
        targetObj, targetPos = self, self.position
        hitObject, hitPos = self, self.position
    elseif targetPos then
        local aim = targetPos + EXTERNAL_CAST_AIM_OFFSET
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

return {
    engineHandlers = { onUpdate=onUpdate, onFrame=onFrame, onSave=onSave, onLoad=onLoad },
    interfaceName = 'OSSC',
    interface = {
        triggerQuickCast = triggerQuickCast,
        isCasting = function() return Cast.isCasting end,
        version = 1,

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
            return tonumber(Cfg.npc and Cfg.npc:get('NPCQuickCastMinDistance')) or 500
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
            quickkeyVetoUntil = realTimeNow() + QUICKKEY_VETO_WINDOW
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
            pendingQuickkeyPageSwitch           = false
            pendingQuickkeyEquipment            = nil
            pendingQuickkeyPressTime            = 0
        end,

        -- notifyQuickkeyActivation(slot)
        --   The press activated hotbar `slot` (the real slot number of a
        --   paged hotbar, e.g. row 2 key 3 = 13), or `nil` when it activated
        --   nothing at all. OSSC uses it to decide whether this press is a
        --   repeat of the slot that cast the current magic item.
        notifyQuickkeyActivation = function(slot)
            hotbarSlotOverride     = slot
            hotbarSlotOverrideTime = realTimeNow()
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
            hotbarMagicActivation = { slot = slot, time = realTimeNow() }
            debugLog("[OSSC Hotkey] Hotbar mod reported magic-tile activation slot="
                .. tostring(slot))
        end,
    },
    eventHandlers  = {
        OSSC_OnSpellCast = function(data)
            for _, handler in ipairs(OSSC_EventHandlers) do
                handler(data)
            end
        end,

        -- Spell filter, pushed by the global script on every change (and on
        -- request).  Kept as a mirror so isSpellIgnored keeps working even if
        -- the global interface is not reachable.
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

        -- OpenMW's built-in omw.music actor script sends this event to every
        -- nearby player when an actor's combat-target list changes. Forward it
        -- to OSSC's global attachment manager; only actors with a live combat
        -- target receive their NPC/Creature scripts.
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