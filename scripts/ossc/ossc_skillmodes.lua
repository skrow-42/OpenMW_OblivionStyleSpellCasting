-- Shared Skill Progression Mode definitions for the OSSC settings and player
-- scripts.
--
-- 'ncg+se' and 'ncg+se (auto)' used to be separate menu choices. Both routed to
-- exactly the same external handler chain as 'skillevo' - the only difference
-- was the promise that Skill Evolution would auto-detect MBSP, which Skill
-- Evolution does for itself - so they are gone from the menu. Values written by
-- older saves are normalised to 'skillevo' rather than rejected.
--
-- The menu's item list, the settings migration and the player script's dispatch
-- all read from here, so the three cannot drift apart.

local SkillModes = {}

-- 'none' awards no skill experience at all. It exists for players who drive
-- spellcasting progression from a mod that does not hook skillUsed: without it
-- the only way to stop OSSC adding its own XP on top was to pick an external
-- mode and hope that mod was installed.
SkillModes.items = { 'ossc', 'ncg', 'skillevo', 'sus', 'mbsp', 'none' }

SkillModes.valid = {}
for _, mode in ipairs(SkillModes.items) do
    SkillModes.valid[mode] = true
end

--- Values older releases stored, mapped onto a current choice.
SkillModes.aliases = {
    ['ncg+se']       = 'skillevo',
    ['ncg+se (auto)'] = 'skillevo',
    ['ncg+se(auto)'] = 'skillevo',
}

--- The mode to actually run for a value exactly as stored in player storage.
--- Anything unrecognised falls back to 'ossc', which is the setting's default,
--- so a hand-edited save degrades to OSSC's own formula instead of to nothing.
function SkillModes.normalize(rawValue)
    if rawValue == nil then return 'ossc' end
    local v = tostring(rawValue)
    if SkillModes.valid[v] then return v end
    local lowered = v:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if SkillModes.valid[lowered] then return lowered end
    return SkillModes.aliases[v] or SkillModes.aliases[lowered] or 'ossc'
end

--- True when the mode hands skill progression to an external mod, which then
--- owns the XP formula and OSSC must not apply its own.
function SkillModes.isExternal(mode)
    local m = SkillModes.normalize(mode)
    return m == 'ncg' or m == 'skillevo' or m == 'mbsp'
end

--- True when the mode runs Skill Evolution's own handler chain, which is also
--- what decides whether the enchant path is left to that mod.
function SkillModes.isSkillEvolution(mode)
    return SkillModes.normalize(mode) == 'skillevo'
end

--- True when the mode awards no experience at all.
function SkillModes.isDisabled(mode)
    return SkillModes.normalize(mode) == 'none'
end

return SkillModes
