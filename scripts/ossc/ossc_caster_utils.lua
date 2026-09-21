---@omw-context runtime
-- Shared spell classification for the OSSC actor scripts.
--
-- `types.Actor.spells(actor)` lists every spell-list entry, including passive
-- abilities and diseases. Creature quick-cast eligibility is only granted by
-- an actively castable spell (or, when enabled, a Power), never by an
-- Ability. The check is record based, so creatures added or altered by
-- content mods are covered without relying on names, ids or mesh paths.
local core  = require('openmw.core')
local types = require('openmw.types')

local SPELL_TYPE   = core.magic.SPELL_TYPE
local spellRecords = core.magic.spells.records

local function isCastableSpellRecord(record, allowPowers)
    if not record then return false end
    if record.type == SPELL_TYPE.Spell then return true end
    return allowPowers == true and record.type == SPELL_TYPE.Power
end

local function hasCastableSpell(actor, allowPowers)
    if not actor then return false end
    local knownSpells = types.Actor.spells(actor)
    if not knownSpells then return false end
    for _, knownSpell in pairs(knownSpells) do
        local spellId = knownSpell
        if type(knownSpell) ~= 'string' then spellId = knownSpell.id end
        if spellId and isCastableSpellRecord(spellRecords[spellId], allowPowers) then return true end
    end
    return false
end

-- ── NPC settings schema ─────────────────────────────────────────────────────
-- Every key of the SettingsOSSC_NPC group with its registered default (the
-- defaults mirror ossc_settings.lua exactly).  Single source of truth for the
-- interfaces that expose the NPC quick-cast settings to other mods
-- (I.OSSC_Casters.getNPCSettings / I.OSSC.getNPCSettings /
-- I.OSSC_Caster.getNPCSettings), so the global, player and actor scripts can
-- never disagree about which keys exist or what an unset one means.
local NPC_SETTINGS_DEFAULTS = {
    NPCQuickCastEnabled           = true,
    NPCQuickCastCreatures         = true,
    NPCQuickCastNonBipedCreatures = true,
    NPCQuickCastDebugLog          = false,
    NPCQuickCastAllowPowers       = false,
    NPCQuickCastRandomAnims       = true,
    NPCQuickCastPollInterval      = 1.0,
    NPCQuickCastBaseChance        = 100,
    NPCQuickCastMinDistance       = 500,
    NPCQuickCastMaxDistance       = 700,
    NPCQuickCastHealThreshold     = 40,
    NPCQuickCastCooldownMin       = 3.5,
    NPCQuickCastCooldownMax       = 8.5,
}

--- A snapshot of every NPC quick-cast setting for other mods to read.
---
--- `section` is the SettingsOSSC_NPC storage section the caller can see (the
--- player-settings section from a player script, its global-storage mirror
--- from a global or actor script).  Each registered key maps to its live
--- value, falling back to the registered default while the value is unset
--- (e.g. before the settings mirror's first sync).  The returned table is a
--- fresh copy — callers may keep or mutate it without touching OSSC's state.
local function readNPCSettings(section)
    local values = {}
    for key, default in pairs(NPC_SETTINGS_DEFAULTS) do
        local value = section and section:get(key)
        if value == nil then value = default end
        values[key] = value
    end
    return values
end

return {
    isCastableSpellRecord = isCastableSpellRecord,
    hasCastableSpell = hasCastableSpell,
    NPC_SETTINGS_DEFAULTS = NPC_SETTINGS_DEFAULTS,
    readNPCSettings = readNPCSettings,
}
