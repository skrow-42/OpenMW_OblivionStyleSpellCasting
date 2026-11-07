---@omw-context runtime
-- Shared spell classification. Actor.spells includes abilities and diseases;
-- only castable spells (or Powers when enabled) grant creature eligibility.
-- spellIdFromEntry() is shared with the local caster scripts so every reader
-- decodes Actor.spells() the same way (records, id strings, or id keys).
local core  = require('openmw.core')
local types = require('openmw.types')

local SPELL_TYPE   = core.magic.SPELL_TYPE
local spellRecords = core.magic.spells.records

local function isCastableSpellRecord(record, allowPowers)
    if not record then return false end
    if record.type == SPELL_TYPE.Spell then return true end
    return allowPowers == true and record.type == SPELL_TYPE.Power
end

--- "Sure cast" records: abilities (SPELL_TYPE.Ability — innate, always in
--- effect), lesser/greater powers (SPELL_TYPE.Power — the once-a-day casts)
--- and spells flagged "Always Succeeds" (alwaysSucceedFlag). Vanilla never
--- rolls to see whether one of these goes off — it simply lands — so the
--- Quick Cast Chance Penalty must never roll one either (it is answered 100
--- before any penalty scaling). That chance exemption is what this rule
--- grants: the Quick Cast Effect Penalty keeps its own, separate Powers-only
--- exclusion (see effectPenaltyExempt in the caster scripts), and the
--- UseFatigue fatigue cost and the Shield Casting Penalty slowdown apply to
--- every cast.
---
--- `type` is only ever a SPELL record type here. An enchantment record's
--- `type` is an EnchantmentType whose numbers overlap SpellType's
--- (CastOnUse == Ability == 1), so enchanted-item casts must not be run
--- through this check — callers pass spell records (or spell tables that
--- carry a spell-record type) only.
local function isSureCastRecord(record)
    if not record then return false end
    if record.type == SPELL_TYPE.Ability or record.type == SPELL_TYPE.Power then return true end
    return record.alwaysSucceedFlag == true
end

--- Extract a spell record id from an Actor.spells() entry. OpenMW documents
--- spell records as the values of pairs(), but some builds / collections also
--- expose plain id strings or key-by-id tables. Every reader of Actor.spells()
--- must accept all three, otherwise the global attach check can see a spell
--- while a local caster script caches zero spells (reported in a Mercy CAO
--- log as "onInit: cached 0 castable spells" with no quick-casts at all).
local function spellIdFromEntry(key, value)
    if type(value) == 'string' then return value end
    -- No pcall: a record whose `id` read raises is a real error in the engine
    -- binding and must surface, not be mistaken for an undecodable entry (a
    -- swallowed read is what once made a whole actor look spell-less).
    if type(value) == 'table' or type(value) == 'userdata' then
        local id = value.id
        if type(id) == 'string' then return id end
    end
    if type(key) == 'string' then return key end
    return nil
end

local function hasCastableSpell(actor, allowPowers)
    if not actor then return false end
    local knownSpells = types.Actor.spells(actor)
    if not knownSpells then return false end
    local function found(spellId)
        return spellId ~= nil
            and isCastableSpellRecord(spellRecords[spellId], allowPowers)
    end
    for key, value in pairs(knownSpells) do
        if found(spellIdFromEntry(key, value)) then return true end
    end
    -- A read-only iterable can expose its records through numeric indexing
    -- while pairs() only reports its methods / keys. Both reads are plain:
    -- no pcall (see spellIdFromEntry).
    if type(knownSpells) == 'table' then
        for i = 1, #knownSpells do
            if found(spellIdFromEntry(i, knownSpells[i])) then return true end
        end
    end
    return false
end

-- ── NPC settings schema ──
-- SettingsOSSC_NPC keys and defaults; must mirror ossc_settings.lua.
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
    NPCQuickCastTouchChance       = 60,
    NPCQuickCastTouchTargetChance = 10,
    NPCQuickCastCooldownMin       = 3.5,
    NPCQuickCastCooldownMax       = 8.5,
    NPCMercyVanillaCastWindow      = 5.0,
    NPCMercyQuickcastWindow        = true,
    NPCMercyQuickcastWindowCooldown = 2.0,
    NPCQuickCastEquipReadiness      = 1.5,
    NPCVanillaCastUnequipTimeout    = 5.0,
    NPCVanillaCastsAllowedMin       = 1,
    NPCVanillaCastsAllowedMax       = 2,
    NPCVanillaCastAllowanceTimeout  = 6.0,
    NPCVanillaCastAllowanceReadiness = 1.5,
    NPCProjectilesPassThroughBystanders = true,
    NPCPauseResumeGrace            = 2.0,
}

-- Snapshot of NPC settings from `section` (player section or global mirror); defaults while unset. Fresh copy.
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
    isSureCastRecord = isSureCastRecord,
    spellIdFromEntry = spellIdFromEntry,
    hasCastableSpell = hasCastableSpell,
    NPC_SETTINGS_DEFAULTS = NPC_SETTINGS_DEFAULTS,
    readNPCSettings = readNPCSettings,
}
