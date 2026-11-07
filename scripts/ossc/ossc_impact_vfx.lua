-- ossc_impact_vfx.lua — WHERE a spell's hit VFX is drawn.
--
-- Vanilla OpenMW puts a spell's hit static in one of two places, both in
-- mwmechanics/spellcasting.cpp:
--
--   * `CastSpell::playEffects` hands the per-effect static to the TARGET's
--     animation — `anim->addEffect(model, id, loop, {}, particle)` — so it is
--     parented to the actor and moves with the body. This is the placement the
--     PLAYER has always had, and the one every report compares against.
--
--   * `CastSpell::explodeSpell` spawns its impact in the world instead:
--     `world->spawnEffect(model, texture, mHitPosition, 1.0f)` — at the point
--     the bolt actually hit. That is for a blast or an impact on the world
--     (ground, door, crate), where there is no actor to parent it to.
--
-- OSSC mirrors both, in that order:
--
--   1. A hit on an NPC or a Creature is handed to that actor's own `AddVfx`
--      handler (ossc_global's `MagExp_OnMagicHit` -> `ossc_actor_hit_vfx.lua`),
--      which makes the same `anim.addVfx(self, model, options)` call SFP's
--      player script makes, so the static is parented to the actor and moves
--      with the body. The one thing that must not be copied verbatim is the
--      effect's HEIGHT: OpenMW's `Animation::addEffect` places a boneless
--      effect by shifting it down from the 128-unit reference height the vanilla
--      statics are authored at (`offset = height - 128`), but only for actors
--      where `isNpc()` is false — creatures and the Player. An NPC keeps
--      its identity transform and the flash stays up at the reference height,
--      which is the "spawned way higher than the model" report. The actor
--      handler therefore applies that same downward correction, measured on the
--      actor (`ossc_body_anchor.attachedOffset`), and it never ADDS height: an
--      earlier version did, and put the flash two metres over the head.
--
--   2. Everything else — no actor at all, or an actor whose handler could not
--      be attached yet — is spawned in the WORLD at the impact point, which is
--      vanilla's `explodeSpell`.
--
-- `modelsFor`/`requestFor` still do the first half of the job: they decide
-- WHICH statics a hit shows (verified against SFP's own record lookup) and ask
-- SFP to skip its copy (`userData.suppressImpactVfx`), so the static is drawn
-- exactly once.
--
-- Everything here needs the GLOBAL context: `world.vfx.spawn` is a global
-- binding, and the event that delivers the impact point (`MagExp_OnMagicHit`)
-- is broadcast globally by SFP.
-- ============================================================================
local core  = require('openmw.core')
local types = require('openmw.types')
-- The one body anchor OSSC uses: the middle of the actor, measured from its own
-- bounding box. Shared with the aim point, so a flash and the bolt that made it
-- can never sit at different heights.
--
-- This module is loaded by the GLOBAL script, which only gets the global and
-- common packages: `openmw.nearby`, `openmw.animation` and `openmw.self` are
-- local-only, so requiring ossc_cast_rules (which needs nearby and animation)
-- from here made the whole global script fail to start with
-- "module not found: openmw.nearby". ossc_body_anchor needs only openmw.util,
-- which every context has.
local bodyAnchor = require('scripts.ossc.ossc_body_anchor')
-- NOTE: `openmw.world` is a GLOBAL-only package (mwlua/luabindings.cpp,
-- initLocalPackages does not provide it), and the caster scripts require this
-- module from their LOCAL contexts to build the launch's userData. Requiring it
-- here would make every quick-cast throw, so `spawn` pulls it in lazily — it is
-- only ever called from the global script.

local M = {}

--- Vanilla's fallback when an effect names no hit static.
M.DEFAULT_HIT_STATIC = 'VFX_DefaultHit'

-- Spell Framework Plus' own STACK_CONFIG.PERSISTENT_EFFECTS. A cast that
-- applies one of these with a duration gets a LOOPING static that SFP attaches
-- to the actor, follows the body and removes by tag when the spell ends — that
-- half must stay SFP's, so OSSC never suppresses such a cast (and never draws
-- it twice).
local PERSISTENT_EFFECTS = {
    shield = true,
    fireshield = true,
    frostshield = true,
    lightningshield = true,
    soultrap = true,
}

local function modelOf(staticId)
    if type(staticId) ~= 'string' or staticId == '' then return nil end
    local record = types.Static.records[staticId:lower()]
    return record and record.model or nil
end

--- The statics a hit with `spell` should show, or nil when OSSC must keep its
--- hands off the cast.
---
--- Returning nil is not an error: a spell without a single resolvable static
--- has nothing to draw, and a spell carrying a persistent looping effect is
--- SFP's to place.
function M.modelsFor(spell)
    local effects = type(spell) == 'table' and spell.effects or nil
    if type(effects) ~= 'table' or #effects == 0 then return nil end
    local models, seen = {}, {}
    for _, eff in ipairs(effects) do
        local mgef = eff and eff.id and core.magic.effects.records[eff.id] or nil
        if mgef then
            local id = tostring(mgef.id):lower()
            local duration = tonumber(eff.duration)
            if PERSISTENT_EFFECTS[id] and duration and duration > 0 then
                return nil
            end
            local model = modelOf(mgef.hitStatic) or modelOf(M.DEFAULT_HIT_STATIC)
            -- Two effects that resolve to the same static are one flash in
            -- vanilla (playEffects skips an effect already added this hit).
            if model and not seen[model] then
                seen[model] = true
                models[#models + 1] = { model = model, texture = mgef.particle }
            end
        end
    end
    if #models == 0 then return nil end
    return models
end

--- Put the impact-VFX request into a launch's `userData`, in place of nothing.
---
--- Returns the table the launch must send: the caller's own table plus the two
--- fields SFP and OSSC need. A table that is not ours (a shared constant, say)
--- is copied, never mutated.
function M.requestFor(userData, spell)
    local models = M.modelsFor(spell)
    if not models then return userData end
    local out = {}
    if type(userData) == 'table' then
        for key, value in pairs(userData) do out[key] = value end
    end
    -- SFP skips BOTH its attached statics and its world-space fallback.
    out.suppressImpactVfx = true
    out.osscImpactVfx = models
    return out
end

--- Draw a hit's statics at `pos`, the point the bolt landed.
---
--- The WORLD-space half of vanilla (explodeSpell), used for an impact with no
--- actor to parent the static to, and for an actor whose `AddVfx` handler is
--- not attached yet: it sits where the impact happened and does not follow the
--- body.
function M.spawn(models, pos)
    if type(models) ~= 'table' or pos == nil then return false end
    local world = require('openmw.world')
    local spawned = 0
    for _, entry in ipairs(models) do
        if type(entry) == 'table' and type(entry.model) == 'string' then
            world.vfx.spawn(entry.model, pos, {
                mwMagicVfx = true,
                useAmbientLight = true,
                particleTextureOverride = entry.texture,
            })
            spawned = spawned + 1
        end
    end
    return spawned > 0
end

--- How close to the actor's base a reported hit point may be before it is
--- treated as "no impact point at all". Spell Framework Plus fills a missing
--- impact position with `target.position` -- the ground under the actor's feet
--- (magexp_global.lua, the MagExp_OnMagicHit builders) -- so the two are the
--- same vector to within serialisation noise.
M.FOOT_EPSILON = 4.0

--- Where a hit happened: the reported impact point, else the middle of the
--- actor that was hit.
---
--- A reported point that sits at the actor's feet is rejected on purpose: it is
--- what SF+ substitutes when a cast carries no impact point, and drawing there
--- is the feet placement this module exists to avoid. A real collision point on
--- the body is far from the base and is kept as it is.
---
--- The replacement is the actor's own middle (`ossc_body_anchor.point`) — the
--- same measurement every OSSC bolt is aimed at. It is deliberately NOT the raw
--- bounding-box centre: that box is cull-safe (inflated by every drawable's
--- initial bound), so its centre can sit well above the body.
function M.positionFor(hitPos, target)
    local base, body = nil, nil
    if target and target.isValid and target:isValid() then
        base = target.position
        body = bodyAnchor.point(target)
        if body == nil then
            local bbox = target:getBoundingBox()
            body = bbox and bbox.center or nil
        end
    end
    if hitPos ~= nil then
        if base ~= nil and body ~= nil
            and (hitPos - base):length() <= M.FOOT_EPSILON then
            return body
        end
        return hitPos
    end
    return body or base
end

return M
