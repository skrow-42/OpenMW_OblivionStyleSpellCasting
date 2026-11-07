-- ============================================================================
-- OSSC: Moving-target lead (velocity leading) for quick-cast projectiles.
--
-- A faithful Lua clone of the OpenMW engine's AI spell leading, ported from
-- C++ so that OSSC quick-casts — player casts from ANY stance (Weapon, Spell
-- or relaxed) and NPC / eligible-creature casts — lead moving targets the way
-- the engine's own combat AI does:
--
--   * apps/openmw/mwmechanics/aicombat.cpp, AimDirToMovingTarget()
--     (introduced by commit 67abc60264 "aiming to moving target in ranged
--     combat ai", 2014; present in OpenMW 0.45 – 0.51.x)
--   * apps/openmw/mwmechanics/aitimer.hpp, AI_REACTION_TIME = 0.25 s — the
--     window the engine estimates the target's velocity over
--   * apps/openmw/mwworld/projectilemanager.cpp — the bolt speed the engine
--     flies magic projectiles at: fTargetSpellMaxSpeed × effect speed, which
--     is also the speed Spell Framework Plus launches OSSC quick-casts at
--     (see the "Auto speed from MagicEffect record" block in
--     scripts/OMW_MagExp/magexp_global.lua).
--
-- The engine's idea: decompose the target's velocity into components
-- perpendicular and parallel to the line of sight, then find the time at
-- which a projectile travelling at projSpeed can meet the target — the
-- perpendicular velocity components of target and projectile have to match:
--
--     projDistDiff  = sqrt(dist² − (vDirToTarget · vMoveDirN)²)
--     tCollision    = projDistDiff / (sqrt(projSpeed² − velPerp²) − velDir)
--     aim point     = target position + target velocity × tCollision
--
-- This module is data + math: callers own WHEN they sample positions (the
-- player script feeds the actor under the crosshair every simulation tick, the
-- NPC script feeds its combat target) and WHEN they ask for a lead direction.
-- Each eligible cast rolls a private 50/50 decision here; nothing touches the
-- shared math.random stream or reads stances, settings or input.
-- ============================================================================

local util = require('openmw.util')
local core = require('openmw.core')
local types = require('openmw.types')

local Lead = {}

-- Private MINSTD Lehmer stream for the per-cast 50/50 choice. Never consume
-- math.random here: NPC spell selection and stance behavior share that stream.
-- Seeding is lazy and keyed by caster id + first-call simulation time; each
-- script context (player / individual actor) owns its own independent state.
local ROLL_MODULUS = 2147483647
local leadRollState, leadRollSeeded = 0, false

local function seedLeadRoll(casterId, now)
    local seed = 1013904223
    local id = tostring(casterId or '')
    for i = 1, #id do
        seed = (seed * 31 + string.byte(id, i)) % ROLL_MODULUS
    end
    seed = (seed + math.floor((tonumber(now) or 0) * 1000)) % ROLL_MODULUS
    if seed == 0 then seed = 1 end
    return seed
end

function Lead.shouldLead(casterId, now)
    if not leadRollSeeded then
        leadRollState = seedLeadRoll(casterId, now)
        leadRollSeeded = true
    end
    -- 48271 * (2^31 - 1) remains exact in a Lua double (below 2^53).
    leadRollState = (leadRollState * 48271) % ROLL_MODULUS
    return leadRollState < (ROLL_MODULUS / 2)
end

-- ── Tuning (engine values unless noted) ────────────────────────────────────

-- AI_REACTION_TIME from apps/openmw/mwmechanics/aitimer.hpp. The engine
-- estimates the target's velocity as (posNow − posThen) / AI_REACTION_TIME.
local VELOCITY_WINDOW = 0.25

-- OSSC addition: velocity samples survive this long after a target leaves the
-- crosshair (player) or the combat slot (NPCs), so a cast fired right after a
-- brief loss of aim still has history to estimate from. Purely a retention
-- window — it never extends the 0.25 s estimation window above.
local SAMPLE_RETENTION = 1.0

-- OSSC addition: an estimated speed above this is a teleport / respawn /
-- cell-transition artefact, not movement. The engine never needed this guard
-- because AI targets don't teleport mid-pursuit; the player's crosshair can
-- end up on something that does.
local MAX_PLAUSIBLE_SPEED = 2000

-- OSSC addition: cap on the predicted intercept time. The engine leaves
-- tCollision unbounded; when a fleeing target's speed approaches the bolt
-- speed the intercept time (and with it the lead distance) blows up towards
-- infinity, which for a human-controlled caster produces absurd aims. Three
-- seconds is already far beyond any honest combat shot.
local MAX_INTERCEPT_TIME = 3.0

-- ── Velocity tracking ──────────────────────────────────────────────────────
-- One tracker table per script context (the player script, and each NPC /
-- creature actor script gets its own Lua VM, hence its own copy). Entries are
-- kept in a small array and found by linear scan with object identity — the
-- same == comparison this codebase already relies on (e.g. ray hitObject ==
-- target in ossc_player.lua). Objects are never used as table keys: OpenMW
-- object wrappers are userdata whose hash need not be stable across frames.

local tracker = { entries = {} }

local MAX_ENTRIES = 8
local MAX_SAMPLES = 64

local function findEntry(object)
    for i = 1, #tracker.entries do
        if tracker.entries[i].object == object then return tracker.entries[i] end
    end
    return nil
end

local function objectUsable(object)
    if not object then return false end
    if object.isValid and not object:isValid() then return false end
    return true
end

-- Record the object's current position at simulation time 'now'.
function Lead.track(object, now)
    if not objectUsable(object) then return end
    -- Plain read, no pcall: `objectUsable` has already established that this is
    -- a live object in the world, so a raising `position` read is a real engine
    -- problem and must surface instead of being retried silently every frame.
    local pos = object.position
    if not pos then return end

    local entry = findEntry(object)
    if not entry then
        -- Evict the stalest entry when the table is full (a caster flicking
        -- the crosshair across a crowd must not grow the table unbounded).
        if #tracker.entries >= MAX_ENTRIES then
            local oldestIdx, oldestSeen = 1, math.huge
            for i, e in ipairs(tracker.entries) do
                local last = e.samples[#e.samples]
                local seen = last and last.t or 0
                if seen < oldestSeen then oldestIdx, oldestSeen = i, seen end
            end
            table.remove(tracker.entries, oldestIdx)
        end
        entry = { object = object, samples = {} }
        tracker.entries[#tracker.entries + 1] = entry
    end

    local samples = entry.samples
    samples[#samples + 1] = { t = now, pos = pos }
    -- Prune old samples and cap the buffer (frames can tick at any rate).
    while #samples > 0 and now - samples[1].t > SAMPLE_RETENTION do
        table.remove(samples, 1)
    end
    while #samples > MAX_SAMPLES do
        table.remove(samples, 1)
    end
end

-- Drop everything (used on save/load so stale cell positions from a previous
-- session can never leak into a velocity estimate).
function Lead.reset()
    tracker.entries = {}
end

-- Estimated velocity of 'object' at simulation time 'now' as util.vector3
-- (units/sec), or nil when there is not enough fresh history. The estimate
-- spans at most VELOCITY_WINDOW of recent movement, mirroring the engine's
-- (mLastTargetPos → now) / AI_REACTION_TIME update.
function Lead.velocity(object, now)
    local entry = findEntry(object)
    if not entry or #entry.samples < 2 then return nil end

    local samples = entry.samples
    local newest = samples[#samples]
    -- Ignore estimates built from stale history (target left the crosshair
    -- longer ago than the retention window).
    if now - newest.t > SAMPLE_RETENTION then return nil end

    -- Oldest sample inside the velocity window (with a little slack so a
    -- low simulation rate still yields a baseline sample).
    local windowStart = now - VELOCITY_WINDOW - 0.1
    local oldest = samples[1]
    for i = 1, #samples - 1 do
        if samples[i].t >= windowStart then
            oldest = samples[i]
            break
        end
    end

    local dt = newest.t - oldest.t
    if dt < 0.02 then return nil end

    local velocity = (newest.pos - oldest.pos) * (1 / dt)
    if velocity:length() > MAX_PLAUSIBLE_SPEED then return nil end
    return velocity
end

-- ── Projectile speed ───────────────────────────────────────────────────────

local cachedBaseSpeed = nil

-- The speed Spell Framework Plus will actually fly the bolt at (and the
-- engine's ProjectileManager uses for magic bolts):
-- fTargetSpellMaxSpeed × average(mgef.speed over the spell's effects).
-- Kept numerically identical to the "Auto speed from MagicEffect record"
-- block in scripts/OMW_MagExp/magexp_global.lua so the lead math aims with
-- the speed the projectile really has.
function Lead.boltSpeed(effects, effectRecords, gmstBaseSpeed)
    local base = gmstBaseSpeed
    if not base then
        if not cachedBaseSpeed then
            cachedBaseSpeed = core.getGMST('fTargetSpellMaxSpeed') or 1000
        end
        base = cachedBaseSpeed
    end

    local sum, count = 0, 0
    for _, eff in ipairs(effects or {}) do
        local rec = eff and eff.id and effectRecords and effectRecords[eff.id] or nil
        local spd = rec and rec.speed
        if spd then
            sum = sum + spd
            count = count + 1
        end
    end
    if count > 0 then return base * (sum / count) end
    return base
end

-- ── The engine's intercept math (AimDirToMovingTarget, cloned) ─────────────

local UP = util.vector3(0, 0, 1)

-- Returns the lead displacement w (util.vector3) to add to the aim point, or
-- nil when the engine's math yields no usable lead (target too slow to matter
-- is fine and returns a zero-ish lead only if the math runs; unusable cases —
-- aim parallel to the world Z axis, projectile slower than the target's
-- sideways motion, target outrunning the bolt — return nil).
--
-- Cloned from AimDirToMovingTarget (apps/openmw/mwmechanics/aicombat.cpp):
--
--     osg::Vec3f vDirToTarget = ...aimToTarget(...);
--     float distToTarget = vDirToTarget.length();
--     osg::Vec3f vPerpToDir = vDirToTarget ^ osg::Vec3f(0, 0, 1);
--     vPerpToDir.normalize();
--     float velPerp = vTargetMoveDir * vPerpToDir;
--     float velDir  = vTargetMoveDir * vDirToTargetNormalized;
--     float projVelDirSquared = projSpeed * projSpeed - velPerp * velPerp;
--     if (projVelDirSquared > 0) {
--         float projDistDiff = vDirToTarget * vTargetMoveDirNormalized;
--         projDistDiff = std::sqrt(dist * dist - projDistDiff * projDistDiff);
--         tCollision = projDistDiff / (std::sqrt(projVelDirSquared) - velDir);
--     } else tCollision = 0;
--     return vDirToTarget + vTargetMoveDir * tCollision;
--
-- The engine's return value (vDirToTarget + w) is geometrically the direction
-- towards targetPos + w, so here w is returned on its own and callers add it
-- to whatever aim point they already converged on. A stationary target yields
-- w ≈ zero, so aim points that never move (the crosshair convergence point)
-- are preserved exactly — leading is a strict no-op for still targets.
function Lead.leadDisplacement(startPos, aimPoint, targetVel, projSpeed)
    if not startPos or not aimPoint or not targetVel or not projSpeed
        or projSpeed <= 0 or targetVel:length() < 1 then
        return nil
    end

    local vDirToTarget = aimPoint - startPos
    local distToTarget = vDirToTarget:length()
    if distToTarget < 1 then return nil end

    local vDirToTargetNormalized = vDirToTarget * (1 / distToTarget)

    -- vPerpToDir = vDirToTarget ^ (0,0,1), then normalized. Degenerate when
    -- the aim is parallel to the world Z axis (straight up/down): the cross
    -- product collapses, and the engine's normalize would produce garbage.
    local vPerpToDir = vDirToTarget:cross(UP)
    if vPerpToDir:length() < 0.001 then return nil end
    vPerpToDir = vPerpToDir:normalize()

    local vTargetMoveDirNormalized = targetVel:normalize()
    local velPerp = targetVel:dot(vPerpToDir)
    local velDir = targetVel:dot(vDirToTargetNormalized)

    -- Time to collision between target and projectile.
    local tCollision = 0
    local projVelDirSquared = projSpeed * projSpeed - velPerp * velPerp
    if projVelDirSquared > 0 then
        -- Engine quirk kept verbatim: projDistDiff starts as the dot of the
        -- UNNORMALISED dir-to-target with the normalised target move dir,
        -- i.e. how far along the target's track the target currently is;
        -- what remains after the square root is the perpendicular distance
        -- from the shooter to that track.
        local projDistDiff = vDirToTarget:dot(vTargetMoveDirNormalized)
        projDistDiff = math.sqrt(math.max(0, distToTarget * distToTarget - projDistDiff * projDistDiff))
        local closingSpeed = math.sqrt(projVelDirSquared) - velDir
        -- The engine happily produces a negative tCollision when the target
        -- outruns the bolt along the line of sight (aiming BEHIND it); refuse
        -- to lead in that case instead.
        if closingSpeed <= 0 then return nil end
        tCollision = projDistDiff / closingSpeed
    else
        -- Speed of the projectile is not enough to reach the moving target
        -- sideways; the engine sets tCollision = 0 (no lead).
        return nil
    end

    if tCollision <= 0 then return nil end
    if tCollision > MAX_INTERCEPT_TIME then tCollision = MAX_INTERCEPT_TIME end

    return targetVel * tCollision
end

-- ── One-call pipeline for launch sites ─────────────────────────────────────

-- params = {
--   startPos      = util.vector3, -- where the projectile spawns (the hand)
--   aimPoint      = util.vector3, -- where the cast is currently aimed
--   target        = the actor being led (must be a valid living actor)
--   effects       = spell.effects (for the bolt speed)
--   effectRecords = core.magic.effects.records
--   now           = core.getSimulationTime() at the launch moment
--   gmstBaseSpeed = optional fTargetSpellMaxSpeed override (cached otherwise)
-- }
-- Returns the lead-adjusted launch DIRECTION (util.vector3, normalised), or
-- nil when leading does not apply (no fresh velocity, still target, unusable
-- geometry). Callers fall back to their own direction on nil, so a launch is
-- never held up by this module.
function Lead.launchDirection(params)
    local target = params.target
    if not objectUsable(target) then return nil end
    if types.Actor.isDead(target) then return nil end

    local targetVel = Lead.velocity(target, params.now)
    if not targetVel then return nil end

    local projSpeed = Lead.boltSpeed(params.effects, params.effectRecords, params.gmstBaseSpeed)
    local w = Lead.leadDisplacement(params.startPos, params.aimPoint, targetVel, projSpeed)
    if not w then return nil end

    local launchPoint = params.aimPoint + w
    local dir = launchPoint - params.startPos
    if dir:length() < 1 then return nil end
    return dir:normalize()
end

return Lead
