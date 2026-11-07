---@omw-context local
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_actor_hit_vfx.lua — lets a non-player actor interpret Spell Framework
-- Plus' `AddVfx` / `RemoveVfx` events.
--
-- SFP renders a spell's per-effect hit static by sending an `AddVfx` event to
-- the TARGET's own local script, and then
--
--     anim.addVfx(self, data.model, data.options)
--
-- inside it. The Player has that handler in SFP's own player script
-- (`magexp_player.lua`), which passes `data.options` straight through to
-- `anim.addVfx`. A non-player actor had no handler at all: SFP's launch path
-- attaches its actor handler to the CASTER and, for a plain (non-persistent)
-- effect, never attaches one to the target. The event then landed on nothing —
-- which is why an actor's quick-cast at the Player showed its hit flash and the
-- Player's quick-cast at an actor showed none at all.
--
-- ── Placement: what "exactly like the Player's" actually means ─────────────
-- The Player's flash is placed by the ENGINE, not by the Lua handler:
-- `Animation::addEffect` (mwrender/animation.cpp) shifts a boneless,
-- transform-less effect by `height - 128` (and scales it) — but ONLY when
-- `!mPtr.getClass().isNpc()`, i.e. for creatures and for the Player. An NPC is
-- skipped, so the static stays where its own geometry is authored: around the
-- 128-unit reference height, which on a 128-unit humanoid is the top of the
-- head and on a shorter actor is above it.
--
-- That is the whole history of this file's placement bugs. The first version
-- ADDED a measured mid-height on top of those 128 units and put the flash two
-- metres over the head; the next one passed the sender's options through
-- untouched, which is right for a creature (the engine still centres it) but
-- leaves an NPC's flash above the model.
--
-- So the correction is the engine's own, with the sign it actually has: move
-- the effect DOWN by `middle - 128` (ossc_body_anchor.attachedOffset — the
-- actor's measured middle, clamped into the torso band, minus the reference
-- height) so it blooms where the Player's does. It is applied only where the
-- engine applies nothing itself:
--
--   * a sender that names a bone (the cast swirls pass the root bone "") or
--     supplies its own `transform` has already decided where the effect goes;
--     every one of those options is handed through untouched,
--   * a creature is already centred by the engine and is never shifted twice.
--
-- Only two kinds of event are refused: one without a model, and one on an
-- object with no animation (`anim.addVfx` raises "Object has no animation"
-- there). The condition is queryable, so nothing is wrapped in pcall — a raise
-- here would be a real engine error worth seeing.
--
-- The handler is attached by the GLOBAL script (`ossc_global.ensureHitVfxHandler`)
-- to the actor a cast is about to land on; see there for why it has to come
-- from outside.
-- ============================================================================
local self = require('openmw.self')
local anim = require('openmw.animation')
local util = require('openmw.util')
local bodyAnchor = require('scripts.ossc.ossc_body_anchor')

-- anim.addVfx / removeVfx raise "Object has no animation" on an actor that has
-- none. Ask instead of wrapping the call: the condition is queryable, and a
-- raise here would be a real engine error worth seeing.
local function hasAnimation()
    return anim.hasAnimation(self)
end

--- The options an attached hit static is added with.
---
--- The sender's table is never mutated (events hand out shared tables) and is
--- returned as it is whenever the placement is already decided: an explicit
--- `boneName` or `transform`, or an actor the engine centres itself. Otherwise
--- the engine's own reference-height correction is applied, pointing DOWN.
local function placedOptions(options)
    local offset = bodyAnchor.attachedOffset(self)
    if offset == 0 then return options end
    if type(options) == 'table' and (options.transform ~= nil or options.boneName ~= nil) then
        return options
    end
    local out = {}
    if type(options) == 'table' then
        for key, value in pairs(options) do out[key] = value end
    end
    out.transform = util.transform.move(0, 0, offset)
    return out
end

return {
    eventHandlers = {
        AddVfx = function(data)
            if type(data) ~= 'table' or type(data.model) ~= 'string'
                or data.model == '' then
                return
            end
            if not hasAnimation() then return end
            anim.addVfx(self, data.model, placedOptions(data.options))
        end,
        RemoveVfx = function(tag)
            if type(tag) ~= 'string' or tag == '' then return end
            if not hasAnimation() then return end
            anim.removeVfx(self, tag)
        end,
    },
}
