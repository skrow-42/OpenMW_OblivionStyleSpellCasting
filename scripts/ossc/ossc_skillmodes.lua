-- Shared Skill Progression Mode definitions (settings, player scripts).
-- Legacy 'ncg+se' values normalise to 'skillevo'.

local SkillModes = {}

-- 'none' awards no skill XP.
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

-- Mode for a stored value; unknown falls back to 'ossc'.
function SkillModes.normalize(rawValue)
    if rawValue == nil then return 'ossc' end
    local v = tostring(rawValue)
    if SkillModes.valid[v] then return v end
    local lowered = v:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if SkillModes.valid[lowered] then return lowered end
    return SkillModes.aliases[v] or SkillModes.aliases[lowered] or 'ossc'
end

-- True when an external mod owns the XP formula.
function SkillModes.isExternal(mode)
    local m = SkillModes.normalize(mode)
    return m == 'ncg' or m == 'skillevo' or m == 'mbsp'
end

-- True for Skill Evolution's handler chain.
function SkillModes.isSkillEvolution(mode)
    return SkillModes.normalize(mode) == 'skillevo'
end

--- True when the mode awards no experience at all.
function SkillModes.isDisabled(mode)
    return SkillModes.normalize(mode) == 'none'
end

return SkillModes
