--@omw-context runtime
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_vanilla_spellcast.lua — shared detector for REAL engine spellcasts and
-- the SpellCast Unequip Stop handshake.
--
-- `anim.isPlaying(self, 'spellcast')` is far too broad for actors: the engine
-- also uses the spellcast group for equip / unequip / idle posture animations.
-- Treating any of those as a real cast makes OSSC stand down for the whole
-- fight while an AI-driven actor sits in Spell stance.
--
-- The only keys that mean "the engine is actually casting" are the nine
-- per-range Start / Release / Stop markers on the `spellcast` group:
--
--   self start / self release / self stop
--   target start / target release / target stop
--   touch start / touch release / touch stop
--
-- OpenMW Lua receives them as groupname='spellcast' and key='self start', etc.
-- Some animation sources expose the full NIF text key ("SpellCast: Self
-- Start"), so both forms are accepted.
--
-- COOPERATION HANDSHAKE with Mercy CAO / vanilla engine AI:
--
--  1. Any of the nine real-cast keys means the engine spell list was (or must
--     be) temporarily restored for a vanilla cast. OSSC restores its cached
--     spells, holds all quick-casts and marks a cast cycle pending.
--  2. Release / Stop do NOT re-arm quick-casts by themselves: the actor can
--     still be in Spell stance with the engine owning the spell list.
--  3. Only "SpellCast: Unequip Stop" (also accepted as group 'spellcast' +
--     key 'unequip stop', or the user form "SpellCast Unequip Stop") ends the
--     cycle. At that point the local caster strips the engine-facing spells
--     again and quick-casts may resume.
--
-- A configurable timeout releases the cycle if an unequip key is never seen;
-- 0 means strict waiting. This keeps both systems from deadlocking.
-- ============================================================================
local M = {}

--- Default seconds to hold the diagnostic cast window after Start / Release.
M.KEY_HOLD = 3.0
--- Default seconds to wait for SpellCast Unequip Stop before falling back.
M.DEFAULT_UNEQUIP_TIMEOUT = 5.0

local START_KEYS = {
    ['self start'] = true,
    ['target start'] = true,
    ['touch start'] = true,
}

local RELEASE_KEYS = {
    ['self release'] = true,
    ['target release'] = true,
    ['touch release'] = true,
}

local STOP_KEYS = {
    ['self stop'] = true,
    ['target stop'] = true,
    ['touch stop'] = true,
}

local function trim(s)
    return s:match('^%s*(.-)%s*$') or ''
end

local function normalize(value)
    local s = trim(tostring(value or ''):lower())
    -- Accept both the Lua key ("self start") and the raw NIF text key
    -- ("SpellCast: Self Start"). Some logs use a space instead of a colon
    -- ("SpellCast Unequip Stop"), so strip that prefix too.
    local colon = s:find(':', 1, true)
    if colon then
        s = trim(s:sub(colon + 1))
    else
        local first, rest = s:match('^(%S+)%s+(.+)$')
        if first == 'spellcast' then
            s = trim(rest)
        end
    end
    return s
end

--- True when `groupname` belongs to the vanilla spellcast animation group.
--- The all-keys handler passes '' / nil, which is accepted.
function M.isSpellcastGroup(groupname)
    local g = normalize(groupname)
    return g == '' or g == 'spellcast' or g:find('spellcast', 1, true) ~= nil
end

--- Return 'start', 'release', 'stop', or nil for a real vanilla cast key.
function M.keyKind(groupname, key)
    if not M.isSpellcastGroup(groupname) then return nil end
    local k = normalize(key)
    if START_KEYS[k] then return 'start' end
    if RELEASE_KEYS[k] then return 'release' end
    if STOP_KEYS[k] then return 'stop' end
    return nil
end

--- True for the spellcast stance unequip completion key.
function M.isUnequipStop(groupname, key)
    if not M.isSpellcastGroup(groupname) then return false end
    return normalize(key) == 'unequip stop'
end

--- Fresh per-script state table.
function M.newState()
    return {
        vanillaSpellcastUntil = 0.0,
        vanillaSpellcastLastKey = nil,
        awaitVanillaUnequipStop = false,
        vanillaCastCycleStartedAt = 0.0,
        vanillaCastCycleStartKey = nil,
        vanillaCastCycleEndKey = nil,
        vanillaCastTimedOut = false,
    }
end

--- Note a text key on a per-script state table. Returns:
---   'start' / 'release' / 'stop' for real cast keys,
---   'unequip_stop' for SpellCast Unequip Stop,
---   nil for every other animation key,
--- plus a second value `newCycle` that is true only for the key that OPENED a
--- cast cycle (so a caller can count one vanilla cast per cycle instead of
--- once per key).
function M.noteKey(state, groupname, key, now, hold)
    state = state or M.newState()
    if M.isUnequipStop(groupname, key) then
        state.awaitVanillaUnequipStop = false
        state.vanillaSpellcastUntil = 0.0
        state.vanillaSpellcastLastKey = tostring(key)
        state.vanillaCastCycleStartedAt = 0.0
        state.vanillaCastCycleEndKey = tostring(key)
        state.vanillaCastTimedOut = false
        return 'unequip_stop', false
    end
    local kind = M.keyKind(groupname, key)
    if not kind then return nil, false end
    local newCycle = false
    if not state.awaitVanillaUnequipStop then
        state.awaitVanillaUnequipStop = true
        state.vanillaCastCycleStartedAt = now
        state.vanillaCastCycleStartKey = tostring(key)
        state.vanillaCastCycleEndKey = nil
        state.vanillaCastTimedOut = false
        newCycle = true
    end
    state.vanillaSpellcastLastKey = tostring(key)
    state.vanillaSpellcastUntil = now + (tonumber(hold) or M.KEY_HOLD)
    return kind, newCycle
end

--- True while a real vanilla spellcast cycle is pending (or its short key hold
--- is still open). `timeout` <= 0 means strict waiting for Unequip Stop.
function M.active(state, now, timeout)
    if not state then return false end
    timeout = tonumber(timeout) or M.DEFAULT_UNEQUIP_TIMEOUT
    if state.awaitVanillaUnequipStop then
        if timeout <= 0 then return true end
        local started = state.vanillaCastCycleStartedAt or now
        return now - started < timeout
    end
    return (state.vanillaSpellcastUntil or 0.0) > now
end

--- Clear a pending cycle when the Unequip Stop timeout elapsed.
--- Returns true when it actually expired the cycle.
function M.expireCycle(state, now, timeout)
    if not state or not state.awaitVanillaUnequipStop then return false end
    timeout = tonumber(timeout) or M.DEFAULT_UNEQUIP_TIMEOUT
    if timeout <= 0 then return false end
    local started = state.vanillaCastCycleStartedAt or now
    if now - started < timeout then return false end
    state.awaitVanillaUnequipStop = false
    state.vanillaSpellcastUntil = 0.0
    state.vanillaCastCycleStartedAt = 0.0
    state.vanillaCastCycleEndKey = 'timeout'
    state.vanillaCastTimedOut = true
    return true
end

function M.cyclePending(state)
    return state ~= nil and state.awaitVanillaUnequipStop == true
end

--- Remaining seconds until quick-casts may resume, for diagnostics.
function M.remaining(state, now, timeout)
    if not state then return 0.0 end
    timeout = tonumber(timeout) or M.DEFAULT_UNEQUIP_TIMEOUT
    if state.awaitVanillaUnequipStop then
        if timeout <= 0 then return M.KEY_HOLD end
        local started = state.vanillaCastCycleStartedAt or now
        return math.max(0.0, timeout - (now - started))
    end
    return math.max(0.0, (state.vanillaSpellcastUntil or 0.0) - now)
end

function M.reset(state)
    if not state then return end
    state.vanillaSpellcastUntil = 0.0
    state.vanillaSpellcastLastKey = nil
    state.awaitVanillaUnequipStop = false
    state.vanillaCastCycleStartedAt = 0.0
    state.vanillaCastCycleStartKey = nil
    state.vanillaCastCycleEndKey = nil
    state.vanillaCastTimedOut = false
end

return M
