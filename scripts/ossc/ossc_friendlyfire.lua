---@omw-context runtime
-- ============================================================================
-- OSSC: Friendlier Fire compatibility gate
-- SFP applies casts via ActiveSpells:add(), bypassing FF's sweep, so check here using FDU followers.
-- FF settings honoured read-only. No-op without FF and FDU.
-- ============================================================================
local core       = require('openmw.core')
local types      = require('openmw.types')
local storage    = require('openmw.storage')
local interfaces = require('openmw.interfaces')

local FF_SETTINGS_SECTION = 'SettingsFriendlierFire_settings'
local NO_FOLLOWERS = {}
local NO_SCRIPTS = {}

local function getFfSetting(key, default)
    local section = storage.globalSection(FF_SETTINGS_SECTION)
    if not section then return default end
    local value = section:get(key)
    if value == nil then return default end
    return value
end

local function getFollowerList()
    local fdu = interfaces.FollowerDetectionUtil
    if not fdu or type(fdu.getFollowerList) ~= 'function' then return NO_FOLLOWERS end
    local list = fdu.getFollowerList()
    if type(list) ~= 'table' then return NO_FOLLOWERS end
    return list
end

local function isCommanded(target)
    if not types.Actor.objectIsInstance(target) then return false end
    local activeEffects = types.Actor.activeEffects(target)
    if not activeEffects then return false end
    local commandCreature = activeEffects:getEffect('commandcreature')
    if commandCreature and commandCreature.magnitude ~= 0 then return true end
    local commandHumanoid = activeEffects:getEffect('commandhumanoid')
    return commandHumanoid ~= nil and commandHumanoid.magnitude ~= 0
end

local function isSummonRecord(recordId)
    if type(recordId) ~= 'string' then return false end
    return recordId:find('_summon$') ~= nil or recordId == 'bonewalker_greater_summ'
end

local function hasBlacklistedScript(target)
    local objectType = target.type
    local records = objectType and objectType.records
    local record = records and records[target.recordId]
    local mwscript = record and record.mwscript
    if not mwscript then return false end
    local blacklist = getFfSetting('blacklistedScripts', NO_SCRIPTS)
    if type(blacklist) ~= 'table' then return false end
    for _, blacklisted in ipairs(blacklist) do
        if mwscript == blacklisted then return true end
    end
    return false
end

-- Mirrors FF's victim-side spell protection gates.
local function spellProtectionActive(target)
    if not (target and types.Actor.objectIsInstance(target)) then return false end
    if not getFfSetting('disableSpells', true) then return false end
    -- FF's command check applies to non-player victims only.
    if target.type == types.Player then return true end
    if getFfSetting('commandDisablesProtection', true) and isCommanded(target) then return false end
    if isSummonRecord(target.recordId) and not getFfSetting('protectSummons', true) then return false end
    return not hasBlacklistedScript(target)
end

-- Same test as FF's isFriendlyFire.
local function isFriendlyPair(caster, target, followers)
    if caster.id == target.id then return false end
    local casterState = followers[caster.id]
    if not (casterState and casterState.followsPlayer) and caster.type ~= types.Player then return false end
    local victimState = followers[target.id]
    return (victimState ~= nil and victimState.followsPlayer) or target.type == types.Player
end

-- Same test as Friendlier Fire's spellIsHarmful.
local function hasHarmfulEffects(effects)
    if not effects then return false end
    local effectRecords = core.magic.effects.records
    for _, effect in ipairs(effects) do
        local mgef = effect and effect.id and effectRecords[effect.id]
        if mgef and mgef.harmful then return true end
    end
    return false
end

--- True when a Lua-applied cast from `caster` onto `target` would be harmful
--- friendly fire, meaning OSSC should not launch it.
--- @param caster  GameObject  The actor casting the spell (OSSC `self`).
--- @param target  GameObject|nil  The aimed target (followers/summons/player).
--- @param effects table|nil   The spell record's `effects` (objects with `.id`).
--- @return boolean
local function isFriendlyFireBlocked(caster, target, effects)
    if not (caster and target and types.Actor.objectIsInstance(target)) then return false end
    if not spellProtectionActive(target) then return false end
    if not isFriendlyPair(caster, target, getFollowerList()) then return false end
    return hasHarmfulEffects(effects)
end

return {
    isFriendlyFireBlocked = isFriendlyFireBlocked,
}
