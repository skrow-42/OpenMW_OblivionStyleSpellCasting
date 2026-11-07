---@omw-context runtime
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_mercy.lua — the Mercy CAO bridge (Mercy: Combat AI Overhaul, Max Yari)
--
-- WHY THIS FILE EXISTS
--
-- Mercy CAO is a second AI driver on the same actor. Its ImprovedAI.lua is a
-- local script attached to every NPC, and it writes exactly the things OSSC's
-- caster script writes:
--
--   * the draw state        — selfActor:setStance(state.stance), every frame
--                             it drives (ImprovedAI.lua, "Mercy sets stance")
--   * the attack input      — omwself.controls.use = state.attack, every frame
--   * the actor's spells    — it gives and takes its own custom spell records
--
-- OSSC was written against the engine's AI, where it is the only script driving
-- the body, so it assumes it may take the stance back from Spell stance, force
-- Weapon stance, and release the engine attack input whenever that input looks
-- stuck. With Mercy installed those assumptions are false, and the two scripts
-- overwrite each other every frame.
--
-- Which of them wins is decided by the content-file order, not by anything
-- either mod can control: OpenMW keeps an object's local scripts in a
-- std::map<int, Script> keyed by script id and keeps every engine-handler list
-- sorted by that same id (components/lua/scriptscontainer.cpp), and script ids
-- follow the order the .omwscripts files load in. So the fight can never be won
-- by writing harder or in a cleverer order — the only stable fix is for OSSC to
-- stop writing what Mercy owns. That is what this module is for, and it is why
-- every gate below is a "does Mercy drive this actor right now" test rather
-- than anything to do with ordering.
--
-- THE SHORT QUICK-CAST WINDOW (why this file now has a small state machine)
--
-- canHandOverForMagic() deliberately returns false whenever OSSC is installed,
-- so Mercy never opens one of its own vanilla magic windows. That is right —
-- OSSC picks the actor's own spells — but Mercy can also keep STANCE.Spell as
-- a posture (STAND_GROUND, or a spellcaster waiting at range), and OSSC's
-- vanilla-stance stand-down then silences it for the whole fight.
--
-- Instead of fighting over stance and controls, ossc_npc.lua now asks Mercy to
-- yield for ONE quick-cast: combatEnabled(OSSC_QuickCast, false) stops Mercy's
-- Combat/CombatAux trees (it keeps the current stance and writes no attack),
-- and the small set of fields updateOSSCHold() reads is presented as an
-- uncommitted FIGHT. Mercy then releases its own pause through its normal
-- code path. OSSC swaps to Weapon stance, casts once with its usual blended
-- animation, and endYield() restores the saved state and re-enables the trees.
-- A real engine spellcast cycle (self/target/touch Start, Release, Stop plus
-- SpellCast Unequip Stop) still wins: the window is never opened while the
-- engine owns the temporarily restored spell list.
--
-- WHAT MERCY ALREADY DOES FOR OSSC (so we must keep our side of it)
--
-- Mercy ships an OSSC integration layer in scripts/MaxYari/MercyCAO:
--   * magic_util.osscInstalled()   — detects us by the content file name
--                                    "Oblivion Style Spell Casting OSSC.omwscripts"
--   * I.OSSC_Caster.pause/unpause  — holds our quick-casting while its own
--                                    routines own the body (updateOSSCHold)
--   * I.OSSC_Casters.ignoreSpell   — keeps Mercy's own custom spell records out
--                                    of OSSC's spell *picking*
--   * I.OSSC_Caster.castSpellAtTarget / the OSSC_CastSpellAtTarget global event
--                                  — how Mercy casts through our pipeline
--   * withOSSCSpellsRestored()     — pauses us for the instant it scans the
--                                    actor's spells, because we keep them out of
--                                    the engine's list while we own casting
--
-- So Mercy already knows about us. Nothing here changes the contract Mercy
-- codes against: the pause reasons, the spell filter and castSpellAtTarget all
-- keep working exactly as before.
--
-- THE TWO THINGS MERCY CANNOT FIX FROM ITS SIDE
--
-- 1. OSSC's per-frame writes. Mercy cannot stop OSSC from calling setStance or
--    from releasing the attack input; it can only write over them, and whether
--    its write is the one that survives is the load-order coin flip above.
--
-- 2. A stranded hold. Mercy's hold is sent from ITS onUpdate, and that function
--    returns before the hold update whenever Mercy is switched off — and both
--    Fair Care and NGarde (both bundled here) do exactly that, mid-fight, to
--    let the engine use a healing item. A hold Mercy never releases is a silent
--    caster for the rest of the fight, so OSSC reads Mercy's live state itself
--    instead of trusting only the hold (see busyReason below and
--    releaseStaleHold in ossc_npc.lua).
--
-- Context note: `openmw.interfaces` is per-sandbox, and OpenMW gives every
-- script sandbox its own `require` cache (LuaState::runInNewSandbox builds a
-- fresh `loaded` table), so the `interfaces` captured here is the one belonging
-- to the script that required this module. Require it from a LOCAL script:
-- I.MercyCAO is a local interface and only exists on actors Mercy runs on.
-- ============================================================================
local core = require('openmw.core')

-- Plain require on purpose: this module is only ever loaded from the actor and
-- the player quick-cast scripts, both of which run in a script sandbox where
-- `openmw.interfaces` always exists. A pcall here would have turned a real
-- require failure into "Mercy is not installed" and hidden it forever.
local interfaces = require('openmw.interfaces')

local M = {}

--- The content file Mercy ships. Mercy checks ours by name (see
--- magic_util.OSSC_CONTENT_FILE); this is our half of the same handshake.
M.CONTENT_FILE = 'MercyCAO.omwscripts'

--- Mercy's combat states (scripts/MaxYari/MercyCAO/scripts/enums.lua).
M.COMBAT_STATE_NO_STATE = 'NO_STATE'
M.COMBAT_STATE_FIGHT    = 'FIGHT'

--- Fixed compatibility policy: OSSC keeps casting the actor's own spells but
--- hands Mercy the draw state and attack input, and yields when Mercy's body is
--- committed. There is intentionally no user-selectable off/yield mode.
M.MODE_COOPERATE = 'cooperate'

--- The pause reason keys Mercy uses (magic_util.osscSetPaused and
--- magic_util.withOSSCSpellsRestored). OSSC only ever drops these two on its
--- own, never a reason another mod filed.
M.PAUSE_REASONS = { 'MercyCAO', 'MercyCAO_scan' }

--- Source name OSSC files with Mercy's combatEnabled()/locomotionEnabled()
--- switch while it owns a short quick-cast window. A source of its own means
--- another mod disabling Mercy at the same time is never overwritten when the
--- window ends.
M.YIELD_SOURCE = 'OSSC_QuickCast'

--- Source name for the invisible-and-seen hold (ossc_npc.Combat.updateHidden).
--- Its own source, so the hold and a quick-cast window can never release each
--- other, and another mod's switch is never overwritten.
M.HIDDEN_SOURCE = 'OSSC_Hidden'

--- State fields OSSC borrows for the duration of a quick-cast window. They are
--- NOT cleared by Mercy's state:clear(), so setting them to a straight-fight
--- snapshot makes updateOSSCHold() release Mercy's own pause through Mercy's
--- normal code path instead of OSSC editing someone else's pause reasons.
local YIELD_FIELDS = {
    'combatState', 'inAttackSequence', 'magicBusy', 'castingCustom',
    'repositioning', 'isWerewolf',
}

local installed = nil

--- True when Mercy CAO is in the load order. Fixed for the session.
function M.isInstalled()
    if installed == nil then
        installed = core.contentFiles.has(M.CONTENT_FILE) == true
    end
    return installed
end

--- Mercy's local interface on this very actor, or nil.
---
--- I.MercyCAO only exists while Mercy's ImprovedAI.lua is attached to this
--- object, and Mercy attaches it to NPCs only — so creatures never have it and
--- are never affected by any of this. A blacklisted NPC still has the
--- interface: it is attached, it just never drives (see isDriving).
function M.driver()
    local iface = interfaces.MercyCAO
    if type(iface) ~= 'table' then return nil end
    if type(iface.state) ~= 'table' then return nil end
    return iface
end

--- True while Mercy's AI is the one driving this actor.
---
--- Read off Mercy's own state rather than off the pause it sends us, for the
--- two reasons listed in the header: the hold is one frame stale and depends on
--- Mercy's script getting as far as its hold update, which it does not when
--- another mod switched Mercy off or when Mercy never started on this actor at
--- all (blacklisted NPCs, and the window before Mercy's startup data arrives).
---
--- The test is `combatState` having left NO_STATE: Mercy's main loop is the
--- only thing that ever changes that field (every write to it is below the
--- function's early returns), so an actor Mercy is not driving sits at
--- NO_STATE forever while an actor it drives is in a real state on every frame
--- after the first.
---
--- `hasCombatTarget` is what OSSC itself sees on the actor (I.AI.getActiveTarget
--- 'Combat'); requiring it keeps the gate honest even if Mercy's state is stale.
function M.isDriving(hasCombatTarget)
    return hasCombatTarget == true and M.isActive()
end

--- True while Mercy's AI loop is active on this actor, without requiring the
--- caller to already have a combat target. Used to decide who OWNS a Spell
--- stance: under Mercy it is usually a posture, not an engine vanilla cast.
function M.isActive()
    local iface = M.driver()
    if not iface then return false end
    if iface.enabled == false then return false end
    local state = iface.state
    local combatState = state and state.combatState
    if combatState == nil then return false end
    return combatState ~= M.COMBAT_STATE_NO_STATE
end

--- Mercy holds OSSC back in every combat state except a straight FIGHT. A
--- quick-cast window temporarily presents FIGHT so the hold is released by
--- Mercy itself.
function M.isFightState()
    local iface = M.driver()
    if not iface then return false end
    local state = iface.state
    return state ~= nil and state.combatState == M.COMBAT_STATE_FIGHT
end

--- Why Mercy's body is committed right now, or nil when OSSC may cast.
---
--- This is Mercy's own rule, read live instead of received as a hold:
--- ImprovedAI.updateOSCHold holds OSSC back unless the actor is in a straight
--- fight and none of Mercy's routines owns the body. The states and the flags
--- are the same ones that rule reads.
---
--- A nil `combatState` (the first frame of a fight, before the main loop has
--- decided) counts as NOT busy: Mercy's own hold covers that window, and an
--- over-cautious gate here would be a silent caster.
function M.busyReason()
    local iface = M.driver()
    if not iface then return nil end
    local state = iface.state
    local combatState = state.combatState
    if combatState ~= nil and combatState ~= M.COMBAT_STATE_FIGHT then
        return 'combat state ' .. tostring(combatState)
    end
    if state.inAttackSequence then return 'attack sequence' end
    if state.magicBusy then return 'magic action' end
    if state.castingCustom then return 'custom spell' end
    if state.repositioning then return 'repositioning' end
    return nil
end

--- Make Mercy's state look like an uncommitted straight fight. This is the
--- half of the handshake Mercy CANNOT do from its side: its own hold is driven
--- by these fields, and OSSC is the one that knows it is about to quick-cast.
--- beginYield() saves the real values separately for endYield() to restore.
function M.applyYieldState(state)
    if not state then return false end
    state.combatState = M.COMBAT_STATE_FIGHT
    state.inAttackSequence = false
    state.magicBusy = false
    state.castingCustom = false
    state.repositioning = false
    state.isWerewolf = false
    state.attack = 0
    return true
end

--- Whether this actor has a Mercy interface OSSC can ask to yield. This is
--- deliberately broader than isActive(): a bare Spell posture can appear while
--- Mercy's combatState is still NO_STATE (blacklisted actor, other mod
--- disabling Mercy, or startup), yet its Combat tree can still write stance.
--- Asking it to yield is harmless and prevents a per-frame stance fight.
function M.canYield()
    local iface = M.driver()
    return iface ~= nil and type(iface.combatEnabled) == 'function'
end

--- Begin a short OSSC-owned quick-cast window. combatEnabled(source, false)
--- stops Mercy's Combat/CombatAux trees from writing stance or attack input
--- for the window; Locomotion is deliberately left running so movement does
--- not freeze. Returns a snapshot for endYield(), or nil when the installed
--- Mercy is too old to expose the switch.
function M.beginYield()
    if not M.canYield() then return nil end
    local iface = M.driver()
    local state = iface.state
    local snapshot = {}
    for i = 1, #YIELD_FIELDS do
        local field = YIELD_FIELDS[i]
        snapshot[field] = state[field]
    end
    M.applyYieldState(state)
    iface.combatEnabled(M.YIELD_SOURCE, false)
    return snapshot
end

--- Re-assert the yield every OSSC update: Mercy's own onUpdate can run before
--- or after OSSC's, and its state:clear() resets some fields every frame.
function M.maintainYield()
    local iface = M.driver()
    if not iface then return false end
    if type(iface.combatEnabled) == 'function' then
        iface.combatEnabled(M.YIELD_SOURCE, false)
    end
    return M.applyYieldState(iface.state)
end

-- ── Invisible-and-seen hold ────────────────────────────────────────────────
-- Two of Mercy's three trees have to go for the hold to mean anything:
--
--   * Combat/CombatAux — attacks, spells and combat barks. Leaving them on is
--     what made a low-health actor break its own invisibility by swinging.
--   * Locomotion — movement, and Mercy's own retreats, hiding and surrenders.
--     Leaving it on is what made the same actor keep walking INTO the player:
--     invisibility does not stop Mercy from closing the distance, and a body
--     pressed against the player is given away as fast as a swung fist.
--
-- With both off Mercy writes no attack and no movement, and OSSC walks the
-- actor away itself (ossc_npc.Combat.retreatFrom) through the actor's own
-- controls. Nothing of Mercy's own state is written here: both switches are
-- filed under OSSC_Hidden and released by endHiddenHold(), so an attack in
-- progress is not interrupted mid-swing and Mercy resumes on its own terms
-- when the player loses sight.

--- Hold Mercy's attacks AND its movement while an invisible actor breaks away
--- from the player. False when this actor has no Mercy interface to ask.
function M.beginHiddenHold()
    local iface = M.driver()
    if iface == nil or type(iface.combatEnabled) ~= 'function' then return false end
    iface.combatEnabled(M.HIDDEN_SOURCE, false)
    -- Older Mercy builds expose combatEnabled only. The hold then still stops
    -- the attacks — OSSC's own casts are withheld either way.
    if type(iface.locomotionEnabled) == 'function' then
        iface.locomotionEnabled(M.HIDDEN_SOURCE, false)
    end
    return true
end

--- Re-assert the hold every frame: Mercy resets its own source table.
function M.maintainHiddenHold()
    return M.beginHiddenHold()
end

--- Release the hold. Safe to call when it was never taken.
function M.endHiddenHold()
    local iface = M.driver()
    if iface == nil or type(iface.combatEnabled) ~= 'function' then return end
    iface.combatEnabled(M.HIDDEN_SOURCE, true)
    if type(iface.locomotionEnabled) == 'function' then
        iface.locomotionEnabled(M.HIDDEN_SOURCE, true)
    end
end

--- End the window: re-enable Mercy's combat trees under our own source and
--- restore the exact state snapshot captured in beginYield().
function M.endYield(snapshot)
    local iface = M.driver()
    if not iface then return end
    if type(iface.combatEnabled) == 'function' then
        iface.combatEnabled(M.YIELD_SOURCE, true)
    end
    if not snapshot then return end
    local state = iface.state
    if not state then return end
    for i = 1, #YIELD_FIELDS do
        local field = YIELD_FIELDS[i]
        state[field] = snapshot[field]
    end
end

return M
