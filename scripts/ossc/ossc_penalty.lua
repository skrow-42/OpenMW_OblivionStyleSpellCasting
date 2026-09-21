-- Shared quick-cast penalty definitions for the OSSC settings, player and
-- actor scripts.
--
-- The select list shown in the settings menu, the set of values the settings
-- migration accepts, and the multiplier the scripts apply are all derived from
-- the same STEP / MAX pair below, so the three can never disagree about which
-- penalties exist or what one means.
--
-- Stored values are 'off', 'reduce_<percent>' or 'skill_based'. The multiplier
-- is the percentage that is LEFT after the penalty, so no penalty is 1.0 and a
-- 25% penalty is 0.75.
--
-- 'skill_based' is the last item of the same select as the flat percentages:
-- the penalty then follows the caster's skill in the cast's school (Enchant
-- for enchanted items) instead of a fixed percentage — see Penalty.skillScale.
-- It used to be a separate checkbox next to each select; the settings script
-- folds a ticked checkbox into the select once (see ossc_settings.lua).

local STEP = 5
local MAX  = 50

local SKILL_BASED = 'skill_based'

local Penalty = {}

-- The stored value of the skill-based choice, for the settings migration and
-- for any script that wants to write it.
Penalty.SKILL_BASED = SKILL_BASED

-- Select items for the settings renderer: Off, then the flat percentages in
-- ascending penalty order, then Skill based.
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

--- True when a stored value asks for the skill-based penalty.
---
--- Accepts the current 'skill_based' key and the spellings a hand-edited
--- save might carry ('skill', 'skill based', 'skill-based', 'skillbased').
--- Callers must resolve a skill-based value through Penalty.skillScale with
--- the caster's skill; Penalty.scale cannot know the skill and treats the
--- value as no penalty.
function Penalty.isSkillBased(rawValue)
    if rawValue == nil then return false end
    local v = trimmedLower(rawValue)
    return v == SKILL_BASED
        or v == 'skill'
        or v == 'skillbased'
        or v == 'skill based'
        or v == 'skill-based'
end

--- The multiplier for a penalty given as a percentage.
--- Values outside 0..MAX are clamped rather than rejected: a hand-edited save
--- asking for more than the menu offers should still behave sensibly.
function Penalty.scaleFromPercent(pct)
    if type(pct) ~= 'number' or pct <= 0 then return 1.0 end
    if pct > MAX then pct = MAX end
    return (100 - pct) / 100
end

--- The multiplier for the skill-based penalty: 0 skill is a 50% penalty,
--- 100+ skill is no penalty, linear in between (50 skill → 25% penalty).
function Penalty.skillScale(skillValue)
    local s = tonumber(skillValue) or 0
    if s < 0 then s = 0 end
    if s > 100 then s = 100 end
    return (100 - 50 * (1 - s / 100)) / 100
end

--- The multiplier for a value exactly as it is stored in player storage.
---
--- Accepts the current 'off' / 'reduce_<percent>' keys, and the forms older
--- releases wrote: the select index (0 = off, 1 = 25%, 2 = 50%), a bare or
--- signed percentage string, and the 'ossc_penalty_*' keys. Anything
--- unrecognised falls back to no penalty rather than to a guess.
---
--- The skill-based choice is not a fixed multiplier and is answered as no
--- penalty here: check Penalty.isSkillBased first and use Penalty.skillScale
--- with the caster's skill when it is set.
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

--- The multiplier for a stored value, with the skill-based choice resolved.
---
--- `skillValue` is the caster's skill in the cast's school (or Enchant for an
--- enchanted item); it is only consulted when the value is skill-based, so
--- callers that already know the value is flat may pass nil.
function Penalty.resolve(rawValue, skillValue)
    if Penalty.isSkillBased(rawValue) then
        return Penalty.skillScale(skillValue)
    end
    return Penalty.scale(rawValue)
end

-- ── Shield Casting Penalty ──────────────────────────────────────────────────
-- A different animal from the two above: the shield penalty is a cast-speed
-- slowdown computed from the equipped shield's weight against the caster's
-- Strength and cast skill (the Carry-Capacity Ratio formula in the player and
-- NPC scripts). The setting decides how much of that computed slowdown is
-- applied — its STRENGTH:
--
--   'off'          nothing
--   'shield_<n>'   n% of the formula's slowdown; 100 is the whole of it (the
--                  old 'full'), 50 is half (the old 'reduced')
--   'skill_based'  the strength follows the cast skill: 0 skill → 100%,
--                  100+ skill → 0%, linear in between (50 skill → the old
--                  'reduced' half)
--
-- Stored values other than these are the ones older releases wrote ('reduced',
-- 'full', the skill-based checkbox that the settings script folds in).

local SHIELD_STEP = 10
local SHIELD_MAX  = 100

local Shield = {}
Penalty.shield = Shield

-- Select items for the settings renderer: Off, the strengths in ascending
-- order, then Skill based.
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

--- The stored key for a strength given as a percentage, snapped to the
--- nearest step the menu offers (0 → 'off').
function Shield.keyFromPercent(pct)
    pct = tonumber(pct) or 0
    if pct <= 0 then return 'off' end
    if pct > SHIELD_MAX then pct = SHIELD_MAX end
    local stepped = math.floor(pct / SHIELD_STEP + 0.5) * SHIELD_STEP
    if stepped < SHIELD_STEP then stepped = SHIELD_STEP end
    return 'shield_' .. stepped
end

--- The strength (0..1) of the shield penalty for a stored value.
---
--- Accepts the current keys, the old 'reduced' / 'full' words, and a bare or
--- '%'-suffixed percentage. Anything unrecognised — and the skill-based
--- choice, which is not a fixed strength: check Penalty.isSkillBased first
--- and use Shield.skillStrength with the caster's skill — reads as 0, i.e.
--- no penalty rather than a guess.
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

--- The strength for the skill-based choice: 0 skill → 1.0 (the whole
--- slowdown), 100+ skill → 0 (none), linear in between.
function Shield.skillStrength(skillValue)
    local s = tonumber(skillValue) or 0
    if s < 0 then s = 0 end
    if s > 100 then s = 100 end
    return 1 - s / 100
end

--- The strength for a stored value, with the skill-based choice resolved
--- through `skillValue` (the caster's skill in the cast's school, or Enchant
--- for an enchanted item).
function Shield.resolve(rawValue, skillValue)
    if Penalty.isSkillBased(rawValue) then
        return Shield.skillStrength(skillValue)
    end
    return Shield.strength(rawValue)
end

--- The current select item for a value exactly as stored in player storage:
--- 'reduced' → 'shield_50', 'full' → 'shield_100', the skill-based spellings
--- → 'skill_based', a percentage → the nearest step, anything unrecognised →
--- 'off' (the setting's default).
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
