-- Shared quick-cast penalty definitions (settings, player, actor scripts).
-- Stored: 'off', 'reduce_<percent>', 'skill_based'. Multiplier = fraction left (25% penalty = 0.75).

local STEP = 5
local MAX  = 50

local SKILL_BASED = 'skill_based'

local Penalty = {}

-- Stored skill-based value.
Penalty.SKILL_BASED = SKILL_BASED

-- Select items: Off, percentages ascending, Skill based.
Penalty.items = { 'off' }

-- Every value the current release considers valid, keyed by the stored string.
Penalty.valid = { off = true }

for pct = STEP, MAX, STEP do
    local key = 'reduce_' .. pct
    Penalty.items[#Penalty.items + 1] = key
    Penalty.valid[key] = true
end

Penalty.items[#Penalty.items + 1] = SKILL_BASED
Penalty.valid[SKILL_BASED] = true

local function trimmedLower(rawValue)
    local v = tostring(rawValue):lower():gsub('^%s+', ''):gsub('%s+$', '')
    return v
end

-- True for skill-based values (incl. legacy spellings). Resolve via Penalty.skillScale.
function Penalty.isSkillBased(rawValue)
    if rawValue == nil then return false end
    local v = trimmedLower(rawValue)
    return v == SKILL_BASED
        or v == 'skill'
        or v == 'skillbased'
        or v == 'skill based'
        or v == 'skill-based'
end

-- Multiplier for a percentage, clamped to 0..MAX.
function Penalty.scaleFromPercent(pct)
    if type(pct) ~= 'number' or pct <= 0 then return 1.0 end
    if pct > MAX then pct = MAX end
    return (100 - pct) / 100
end

-- 0 skill = 50% penalty, 100+ = none, linear.
function Penalty.skillScale(skillValue)
    local s = tonumber(skillValue) or 0
    if s < 0 then s = 0 end
    if s > 100 then s = 100 end
    return (100 - 50 * (1 - s / 100)) / 100
end

-- Multiplier for a stored value, incl. legacy forms; unknown = no penalty.
-- Skill-based reads as no penalty: check isSkillBased first.
function Penalty.scale(rawValue)
    if rawValue == nil then return 1.0 end

    -- Legacy select index.
    local n = tonumber(rawValue)
    if n == 0 then return 1.0 end
    if n == 1 then return 0.75 end
    if n == 2 then return 0.50 end

    local v = trimmedLower(rawValue)
    if v == 'off' or v == 'disabled' or v == '' or v == 'ossc_penalty_off' then
        return 1.0
    end
    if Penalty.isSkillBased(v) then return 1.0 end

    local pct = tonumber(v:match('^reduce_(%d+)$'))
        or tonumber(v:match('^ossc_penalty_(%d+)$'))
        or tonumber(v:match('^(%d+)%%$'))
        or tonumber(v:match('^%-(%d+)%%$'))
        or tonumber(v:match('^(%d+)$'))
    if pct then return Penalty.scaleFromPercent(pct) end

    return 1.0
end

-- Multiplier with skill-based resolved; skillValue only used when skill-based.
function Penalty.resolve(rawValue, skillValue)
    if Penalty.isSkillBased(rawValue) then
        return Penalty.skillScale(skillValue)
    end
    return Penalty.scale(rawValue)
end

-- ── Shield Casting Penalty ──
-- Strength (0..1) of the shield cast-speed slowdown.
-- Stored: 'off', 'shield_<n>' (n%), 'skill_based'; legacy 'reduced'/'full'.

local SHIELD_STEP = 10
local SHIELD_MAX  = 100

local Shield = {}
Penalty.shield = Shield

-- Select items: Off, strengths ascending, Skill based.
Shield.items = { 'off' }

-- Every value the current release considers valid, keyed by the stored string.
Shield.valid = { off = true }

for pct = SHIELD_STEP, SHIELD_MAX, SHIELD_STEP do
    local key = 'shield_' .. pct
    Shield.items[#Shield.items + 1] = key
    Shield.valid[key] = true
end

Shield.items[#Shield.items + 1] = SKILL_BASED
Shield.valid[SKILL_BASED] = true

-- Stored key for a percentage, snapped to the nearest step.
function Shield.keyFromPercent(pct)
    pct = tonumber(pct) or 0
    if pct <= 0 then return 'off' end
    if pct > SHIELD_MAX then pct = SHIELD_MAX end
    local stepped = math.floor(pct / SHIELD_STEP + 0.5) * SHIELD_STEP
    if stepped < SHIELD_STEP then stepped = SHIELD_STEP end
    return 'shield_' .. stepped
end

-- Strength for a stored value; unknown or skill-based reads as 0.
function Shield.strength(rawValue)
    if rawValue == nil then return 0 end
    local v = trimmedLower(rawValue)
    if v == 'off' or v == '' or v == 'disabled' then return 0 end
    if v == 'full' then return 1.0 end
    if v == 'reduced' then return 0.5 end
    if Penalty.isSkillBased(v) then return 0 end
    local pct = tonumber(v:match('^shield_(%d+)$'))
        or tonumber(v:match('^(%d+)%%$'))
        or tonumber(v:match('^(%d+)$'))
    if not pct then return 0 end
    if pct < 0 then pct = 0 end
    if pct > SHIELD_MAX then pct = SHIELD_MAX end
    return pct / 100
end

-- 0 skill = 1.0, 100+ = 0, linear.
function Shield.skillStrength(skillValue)
    local s = tonumber(skillValue) or 0
    if s < 0 then s = 0 end
    if s > 100 then s = 100 end
    return 1 - s / 100
end

-- Strength with skill-based resolved.
function Shield.resolve(rawValue, skillValue)
    if Penalty.isSkillBased(rawValue) then
        return Shield.skillStrength(skillValue)
    end
    return Shield.strength(rawValue)
end

-- Normalize a stored value to a current select item; unknown = 'off'.
function Shield.normalize(rawValue)
    if rawValue == nil then return 'off' end
    local v = trimmedLower(rawValue)
    if Shield.valid[v] then return v end
    if Penalty.isSkillBased(v) then return SKILL_BASED end
    if v == 'full' then return 'shield_100' end
    if v == 'reduced' then return 'shield_50' end
    local pct = tonumber(v:match('^(%d+)%%$')) or tonumber(v:match('^(%d+)$'))
    if pct then return Shield.keyFromPercent(pct) end
    return 'off'
end

return Penalty
