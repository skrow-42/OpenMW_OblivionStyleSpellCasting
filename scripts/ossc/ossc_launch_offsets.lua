---@omw-context none
-- ============================================================================
-- OSSC launch offsets (editable data file)
-- Per-animation offsets, first and third person; GRIMOIRE is one global set.
-- Units: game units (1 ≈ 1.4 cm). forward = along facing, left = +left/-right, up = +up.
-- First person: from camera. Third person: from actor feet along camera yaw (up ≈ 115 = chest).
-- NPCs/creatures use 'third' along actor facing.
-- Applied on Lua reload. Missing keys/animations fall back to DEFAULT.
-- ============================================================================

local DEFAULT = {
    first = { forward = 40, left =  35, up =  -8 },  -- normal left-hand cast, 1st person
    third = { forward = 40, left =  25, up = 115 },  -- normal left-hand cast, 3rd person
}

-- One global set for the Eternal Grimoire (right-hand cast), all anims.
local GRIMOIRE = {
    first = { forward = 40, left = -30, up = -16 },  -- right hand, 1st person
    third = { forward = 40, left = -20, up = 115 },  -- right hand, 3rd person
}

-- Per-animation overrides. Missing keys inherit from DEFAULT above.
local ANIMS = {
    quickcast = {                                   -- generic target cast
        first = { forward = 5, left =  35, up =  -8 },
        third = { forward = 5, left =  25, up = 115 },
    },
    quickbuff = {                                   -- self / buff cast
        first = { forward = 10, left =  55, up =  33 },
        third = { forward = 10, left =  25, up = 125 },
    },
    qcconj = {                                      -- conjuration cast
        first = { forward = 5, left =  80, up =  -8 },
        third = { forward = 10, left =  25, up = 115 },
    },
    qctouch = {                                     -- touch cast
        first = { forward = 3, left =  45, up =  -11 },
        third = { forward = 10, left =  25, up = 115 },
    },
    qcalt = {                                       -- alteration target cast
        first = { forward = 5, left =  28, up =  -23 },
        third = { forward = 10, left =  20, up = 115 },
    },
    qcalts = {                                      -- alteration self cast
        first = { forward = 40, left =  35, up =  -8 },
        third = { forward = 40, left =  25, up = 115 },
    },
    qcill = {                                       -- illusion cast
        first = { forward = 5, left =  31, up =  -23 },
        third = { forward = 10, left =  20, up = 115 },
    },
    qcsnap = {                                      -- snap (mysticism) cast
        first = { forward = -5, left =  57, up =  -10 },
        third = { forward = 5, left =  30, up = 115 },
    },
    qcdrain = {                                     -- drain (destruction/resto touch)
        first = { forward = 0, left =  55, up =  -15 },
        third = { forward = 10, left =  35, up = 115 },
    },
    qcskrow = {                                     -- skrow cast
        first = { forward = 5, left =  70, up =  3 },
        third = { forward = 10, left =  35, up = 115 },
    },
    eqcastr = {                                     -- grimoire-stance fallback cast
        first = { forward = 40, left =  35, up =  -8 },
        third = { forward = 40, left =  25, up = 115 },
    },
}

-- ── helpers ──
-- Resolved once at load; getters return shared read-only tables.

local function num(v, fallback)
    local n = tonumber(v)
    if n and n == n then return n end -- rejects NaN too
    return fallback
end

local function resolve(view, base)
    if not view then return base end
    return {
        forward = num(view.forward, base.forward),
        left    = num(view.left,    base.left),
        up      = num(view.up,      base.up),
    }
end

local FIRST = {}
local THIRD = {}
for animGroup, entry in pairs(ANIMS) do
    FIRST[animGroup] = resolve(entry.first, DEFAULT.first)
    THIRD[animGroup] = resolve(entry.third, DEFAULT.third)
end

local GRIMOIRE_FIRST = resolve(GRIMOIRE.first, DEFAULT.first)
local GRIMOIRE_THIRD = resolve(GRIMOIRE.third, DEFAULT.third)

local M = {}

-- Returns { forward, left, up }. NPCs pass firstPerson = false.
function M.get(animGroup, firstPerson)
    if firstPerson then return FIRST[animGroup] or DEFAULT.first end
    return THIRD[animGroup] or DEFAULT.third
end

-- Returns { forward, left, up } from the global Grimoire set.
function M.getGrimoire(firstPerson)
    if firstPerson then return GRIMOIRE_FIRST end
    return GRIMOIRE_THIRD
end

return M
