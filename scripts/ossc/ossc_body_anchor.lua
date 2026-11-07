---@omw-context common
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_body_anchor.lua — the ONE measurement of "the middle of an actor".
--
-- Everything that has to put something on an actor's body — the point a bolt is
-- aimed at, the point a hit's statics are drawn at, a blast centre, the ghost
-- shield — measures the body here, so no two of them can disagree.
--
-- The height is the rise from the actor's feet (its `.position`, which is the
-- object origin) to the CENTRE of its bounding box, never its half-size:
-- OpenMW's `getBoundingBox` is a CULL-SAFE box (RenderingManager::
-- getCullSafeBoundingBox runs SceneUtil::CullSafeBoundsVisitor, which merges
-- every drawable's `getInitialBound()` into its real bounds), so the half-size
-- is deliberately generous — bigger than half the actor's height — and using it
-- as "the middle" puts effects above the head.
--
-- CONTEXT: this module is loaded from BOTH sides. The global script pulls it in
-- through ossc_impact_vfx.lua (that is where a hit's statics are spawned), and
-- the local caster scripts reach it through ossc_cast_rules.lua. It may
-- therefore require only packages the GLOBAL context has — `openmw.util` is a
-- common package (components/lua/initCommonPackages), while `openmw.nearby`,
-- `openmw.animation` and `openmw.self` are local-only and would make the global
-- script fail to start with "module not found".
-- ============================================================================
local util  = require('openmw.util')
-- A GLOBAL-package module (mwlua/luabindings.cpp: initGlobalPackages serves
-- core/types/world), so it is reachable from both the global script and a local
-- one. Used only to recognise an NPC, the one actor kind `Animation::addEffect`
-- does not centre itself.
local types = require('openmw.types')

local M = {}

--- Fallback height when an actor cannot be measured at all.
M.DEFAULT_HEIGHT = 70

-- Keep a measurement inside a torso band: a modded or malformed box can report
-- zero, or something absurd.
M.MIN_HEIGHT = 25
-- CEILING, and the reason it is 80 rather than the actor's own head height:
-- `getBoundingBox` is CULL-SAFE on an NPC (RenderingManager::getCullSafeBoundingBox
-- merges every drawable's `getInitialBound()`, and the merged spheres pull the
-- centre upward), so a measured rise can sit at the top of the head or above
-- it. Anything placed there reads as "spawned way above the model" -- the exact
-- report this constant fixes -- while the same measurement on the PLAYER, whose
-- box reports its real centre, lands on the body and looks correct.
--
-- 80 is the vanilla humanoid reference: OpenMW's own reference actor height is
-- 128 units (mwrender/animation.cpp centres effects on 128), so its middle is
-- 64 and a tall or scaled NPC reaches ~70-80. Nothing about an NPC's body --
-- the only actor kind this measurement places things on, creatures are
-- engine-placed -- is above that.
M.MAX_HEIGHT = 80

-- ── The engine's own reference height, and the correction it skips ──────────
-- OpenMW's `Animation::addEffect` (mwrender/animation.cpp) is what renders a
-- spell's hit static once it has been attached to an actor:
--
--     if (!mPtr.getClass().isNpc() && autoTransform)
--     {
--         osg::Vec3f bounds(getHalfExtents(mPtr) * 2.f);
--         float scale = std::max({bounds.x(), bounds.y(), bounds.z() / 2.f}) / 64.f;
--         ...
--         float offset = 0.f;
--         if (bounds.z() < 128.f)
--             offset = bounds.z() - 128.f;
--         else if (bounds.z() < bounds.x() + bounds.y())
--             offset = 128.f - bounds.z();
--         ...
--         finalTransform.setTrans(osg::Vec3f(0.f, 0.f, offset * scale));
--     }
--
-- Two facts follow, and they are the whole story of the "hit VFX floats above
-- the actor" reports:
--
--   * 128 is the height the vanilla hit statics are authored for (that is why
--     the engine shifts them by `height - 128` and scales them by a factor
--     derived from 128), and
--   * the engine applies that shift ONLY to actors for which `isNpc()` is
--     false — creatures and, in a first-person game, the Player. An NPC gets
--     `finalTransform` identity: the static stays where its own geometry puts
--     it, i.e. around the 128-unit reference height, which on a 128-unit
--     humanoid is the TOP OF THE HEAD and on a shorter actor is above it.
--
-- So "place an actor's hit exactly like the Player's" is not "do nothing" and
-- it is not a lift either: it is the engine's own shift, applied to the actor
-- kind the engine skips, measured on THIS actor instead of assumed. The value
-- is negative (`middle - 128`, about -48..-103), which is why every earlier
-- attempt that ADDED height put the flash two metres over the actor's head.
M.REFERENCE_HEIGHT = 128

--- How far an ATTACHED (actor-parented) vanilla hit static has to move along Z
--- so it blooms around the middle of `obj` instead of the 128-unit reference
--- height it was authored at.
---
--- Zero for an actor the engine already centres (anything not an NPC), so a
--- handler can call this unconditionally.
function M.attachedOffset(obj)
    if obj == nil then return 0 end
    if obj.type ~= types.NPC then return 0 end
    return M.heightAboveBase(obj) - M.REFERENCE_HEIGHT
end

--- The box of an object, or nil when the engine cannot measure it.
function M.boxOf(obj)
    if obj and obj.getBoundingBox then
        local box = obj:getBoundingBox()
        if box then return box end
    end
    return nil
end

--- How far the object's box centre sits above its own origin (an actor's feet).
--- Capped by the half-size so a box whose centre lies outside itself is not
--- trusted either.
function M.centreRise(obj)
    local box = M.boxOf(obj)
    if not box or not box.center or not box.halfSize then return nil end
    local pos = obj.position
    if pos == nil then return nil end
    local rise, half = box.center.z - pos.z, box.halfSize.z
    if half and half > 0 and rise > half then rise = half end
    return rise
end

--- The height of an object's middle above its base, clamped to the torso band.
---
--- A box that cannot be measured — or one whose centre is not above the origin
--- at all (a cull-safe NPC box can report its centre at the FEET, because the
--- merged spheres of the body parts swallow the real one) — falls back to
--- `fallbackZ`, which is itself clamped so a caller cannot introduce an
--- unclamped height by accident.
---
--- The fallback must NEVER be `box.halfSize.z`: the half-size IS the inflated
--- number (cull-safe bounds merge every drawable's `getInitialBound()`), and
--- using it as "the middle" puts the aim point and any world-space impact
--- static above the actor's head. A plain 70-unit chest-height default — the
--- same figure Spell Framework Plus' player side uses when it has nothing to
--- measure — is what the clamp band turns an unmeasurable box into.
function M.heightAboveBase(obj, fallbackZ)
    local z = M.centreRise(obj)
    if not z or z <= 0 then z = tonumber(fallbackZ) or M.DEFAULT_HEIGHT end
    if z < M.MIN_HEIGHT then z = M.MIN_HEIGHT elseif z > M.MAX_HEIGHT then z = M.MAX_HEIGHT end
    return z
end

--- The middle of the object in world space, or nil when it has no position.
function M.point(obj, fallbackZ)
    if obj == nil or obj.position == nil then return nil end
    return obj.position + util.vector3(0, 0, M.heightAboveBase(obj, fallbackZ))
end

return M
