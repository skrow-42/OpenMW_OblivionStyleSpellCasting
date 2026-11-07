---@omw-context common
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_spell_area.lua — the ONE answer to "does this cast explode, and how wide
-- is its blast?".
--
-- Every OSSC cast entry point hands Spell Framework Plus a launch, and SFP takes
-- the bolt's blast radius from that launch's own `area` field, falling back to
-- the record ONLY when the field is absent. A sender that passes a wrong number
-- therefore silently rewrites the spell: `area = 0` turns an area spell into a
-- plain bolt (no explosion at all — "area spells do not trigger"), and a
-- too-wide number explodes things the spell never touched.
--
-- There are three senders (the player's quick-cast, an actor's quick-cast, and
-- the global `castSpellAtTarget` interface) and they used to resolve this each
-- in their own way; two of them read the record's FIRST effect, which is
-- usually a Self or Touch rider in front of the actual blast. The rule lives
-- here once, and it needs only `openmw.core`, so the GLOBAL script can require
-- it (`openmw.nearby` and friends are local-only — see ossc_body_anchor.lua).
-- ============================================================================
local core = require('openmw.core')

local M = {}

--- The blast radius a launch of `spell` really has: the largest `area` among
--- its TARGET-range effects, or 0 for a bolt that only hits what it hits.
---
--- Target range only, because that is the cast leg SFP explodes at the collision
--- point: a Touch effect's blast detonates at the touched actor and a Self
--- effect's nova at the caster, both resolved by SFP's own per-range partition,
--- and neither is widened or narrowed by the bolt's radius. Use `explodes` for
--- "will this cast explode at all?".
function M.impactArea(spell)
    local best = 0
    if type(spell) ~= 'table' or type(spell.effects) ~= 'table' then return 0 end
    for _, eff in ipairs(spell.effects) do
        if eff and eff.range == core.magic.RANGE.Target then
            local area = tonumber(eff.area) or 0
            if area > best then best = area end
        end
    end
    return best
end

--- True when the cast explodes somewhere: any effect with an area of its own.
---
--- OpenMW's `CastSpell::explodeSpell` runs once per effect whose own `mArea` is
--- above zero, at whatever range that effect carries — a Self nova, a Touch
--- blast, a Target bolt's blast — and the blast is drawn by the engine (SFP
--- mirrors it in `detonateSpellAtPos`, which spawns the effect's own
--- `areaStatic` exactly as `explodeSpell` does). OSSC must therefore keep its
--- hands off such a cast: taking it over sets `suppressImpactVfx`, which
--- deletes that spawn and replaces it with a HIT static — the reason a blast was
--- showing the wrong effect entirely.
---
--- Note this is deliberately not `impactArea`, which answers a different
--- question ("how wide is the bolt's blast?") and only looks at Target-range
--- effects: a Touch or Self area spell has no such effect and would slip
--- through.
function M.explodes(spell)
    if type(spell) ~= 'table' or type(spell.effects) ~= 'table' then return false end
    for _, eff in ipairs(spell.effects) do
        if eff and (tonumber(eff.area) or 0) > 0 then return true end
    end
    return false
end

return M
