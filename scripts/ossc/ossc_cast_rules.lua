-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_cast_rules.lua — casting rules shared by EVERY OSSC caster.
--
-- The player script (ossc_player.lua) and the actor script (ossc_npc.lua,
-- which ossc_creature.lua re-exports unchanged) must apply the same rules:
-- one implementation here, both scripts call it. Anything that used to be a
-- per-file copy and drifted (touch reach, cast animation blending) lives here.
--
-- Pure helpers: no per-actor state, no engine handlers. Callers pass in the
-- actor and the facing they cast along (the player casts along the camera,
-- an actor along its body yaw) — the rule itself is identical.
-- ============================================================================
local core   = require('openmw.core')
local types  = require('openmw.types')
local util   = require('openmw.util')
local bodyAnchor = require('scripts.ossc.ossc_body_anchor')
local spellArea  = require('scripts.ossc.ossc_spell_area')
local nearby = require('openmw.nearby')
local anim   = require('openmw.animation')

local M = {}

-- ── Weapon draw (equip) tracking ──────────────────────────────────────────
-- A weapon DRAW reuses the weapon's attack animation group — a two-hander is
-- drawn and swung in 'weapontwohand' — and the engine attaches the weapon mesh
-- to the hand on that play's 'equip attach' text key. Cancelling the play
-- before that key fires leaves the actor holding an EQUIPPED but INVISIBLE
-- weapon: nothing in its hands, yet it hits for full two-handed damage. That
-- is exactly the bug the player script fixed for its own collapsed draws
-- (Stance.collapsedDrawGroup); every OSSC script that cancels attack
-- animations now shares this one tracker so an actor draw is never cancelled
-- either.
--
-- A play is an equip transition when either of its keys mentions "equip"
-- ("equip start" / "equip attach" / "equip stop", and the sheathe side's
-- "unequip start" / "unequip detach" — "unequip" contains "equip").
M.DRAW_WINDOW = 6.0

--- Fresh tracker. `group` is the animation group currently drawing, `until_`
--- the safety bound that closes a missed 'equip stop'.
function M.newDrawTracker()
    return { group = nil, until_ = 0.0 }
end

--- Remember that `groupname` is drawing/equipping a weapon.
function M.noteDraw(tracker, groupname, now)
    if type(groupname) ~= 'string' or groupname == '' then return false end
    tracker.group  = groupname
    tracker.until_ = (now or core.getSimulationTime()) + M.DRAW_WINDOW
    return true
end

--- Forget the draw (its 'equip stop' / 'unequip detach' arrived, or a real
--- attack play of the same group replaced it).
function M.clearDraw(tracker, groupname)
    if groupname == nil or tracker.group == groupname then
        tracker.group  = nil
        tracker.until_ = 0.0
        return true
    end
    return false
end

--- True while `groupname` is still the draw in progress. Expires on its own so
--- a missed stop key can never protect a real attack forever.
function M.isDrawPlaying(tracker, groupname, now)
    if not groupname or tracker.group ~= groupname then return false end
    now = now or core.getSimulationTime()
    if now > tracker.until_ then
        tracker.group  = nil
        tracker.until_ = 0.0
        return false
    end
    return true
end

-- ── Weapon ready / unready transition (draw vs sheathe) ───────────────────
-- A ready or unready is a TRANSITION, not a stance: the engine plays it as one
-- `equip start` → `equip stop` (draw) or `unequip start` → `unequip detach`
-- (sheathe) play of the weapon's own group, one after another, for as long as
-- the actor is flipping between Weapon / Spell / Nothing. OSSC must never
-- finish a flip somebody else started, and a cast that is already running must
-- stay running through it: cancelling the gesture, or stealing the right arm
-- and torso from the transition, is what made a ready/unready look like it
-- "cancelled" a quick-cast.
--
-- One shared state table per caster records which way the last transition went
-- and what it is playing on, so:
--   * the cast blend drops to LeftArm-only while it is in flight (see
--     `M.drawTransitionActive`), keeping the casting hand steady, and
--   * a stance OSSC did not write is never written back by OSSC.
M.TRANSITION_MEMORY = 10.0

--- Fresh transition tracker.
function M.newDrawTransition()
    return { direction = nil, group = nil, until_ = 0.0 }
end

--- Which stance a transition direction ends in. 'draw' ends in Weapon stance,
--- 'sheathe' in relaxed hands (Nothing) — nothing readied.
M.TRANSITION_TARGET = { draw = 'weapon', sheathe = 'nothing' }

--- Note an engine play. `options` is the playBlended options table the engine
--- (or another mod) passed, `startKey`/`stopKey` in either spelling.
--- Returns 'draw', 'sheathe' or nil when the play is not a ready transition.
function M.noteTransition(tracker, groupname, options, now)
    if type(groupname) ~= 'string' or groupname == '' then return nil end
    if type(options) ~= 'table' then return nil end
    local startKey = tostring(options.startKey or options.startkey or ''):lower()
    local stopKey  = tostring(options.stopKey  or options.stopkey  or ''):lower()
    local direction = nil
    if startKey:find('unequip', 1, true) then
        direction = 'sheathe'
    elseif startKey:find('equip', 1, true) then
        direction = 'draw'
    elseif stopKey:find('unequip', 1, true) then
        direction = 'sheathe'
    elseif stopKey:find('equip', 1, true) then
        direction = 'draw'
    end
    if not direction then return nil end
    -- A Stop key closes the transition; the tracker still remembers which way
    -- it went until the window below runs out.
    tracker.direction = direction
    tracker.group     = groupname
    tracker.until_    = (now or core.getSimulationTime()) + M.TRANSITION_MEMORY
    return direction
end

--- True while a ready / unready transition is in flight on `tracker`.
function M.drawTransitionActive(tracker, now)
    if not tracker or not tracker.direction then return false end
    if (now or core.getSimulationTime()) > tracker.until_ then
        tracker.direction = nil
        tracker.group     = nil
        return false
    end
    return true
end

--- The stance the transition in flight will end in ('weapon' / 'nothing'), or
--- nil when there is none.
function M.transitionTargetStance(tracker, now)
    if not M.drawTransitionActive(tracker, now) then return nil end
    return M.TRANSITION_TARGET[tracker.direction]
end

--- Does a playBlended request describe an equip transition? The engine passes
--- the keys as startKey/stopKey; Lua callers may use lowercase spellings.
function M.isEquipPlay(options)
    if type(options) ~= 'table' then return false end
    local startKey = tostring(options.startKey or options.startkey or ''):lower()
    local stopKey  = tostring(options.stopKey or options.stopkey or ''):lower()
    return startKey:find('equip', 1, true) ~= nil
        or stopKey:find('equip', 1, true) ~= nil
end

-- ── Vanilla touch contact (MWMechanics::getHitContact) ────────────────────
-- Every number below is read straight out of the engine's touch handling, so
-- OSSC and vanilla cannot drift apart:
--
--   * reach        fCombatDistance — plain, NOT fCombatDistance *
--                  fHandToHandReach. That product is the UNARMED MELEE swing
--                  reach (getMeleeWeaponReach) and has nothing to do with
--                  spells: World::castSpell calls getHitContact(actor,
--                  fCombatDistance). Multiplying by fHandToHandReach gave
--                  OSSC actors a 250–400 unit touch spell in any load order
--                  with a combat mod that raises it (actors reached across a
--                  room).
--   * eye level    0.85 * the bounding-box height above the feet
--                  (World::getHalfExtents(actor, true).z * 2 * 0.85), never a
--                  fixed offset: a tall actor looks from higher up than a
--                  short one.
--   * horizontal   fCombatAngleXY / 90 is a SINE tolerance, not degrees: the
--   cone           stock 60 means +/-41.8 degrees, and the target must be in
--                  front (positive dot product) first.
--   * vertical     fCombatAngleZ / 90, applied to the angles of the target's
--   cone           feet and head as seen from the eye ("nice cliff racer hack,
--                  Todd"): the body must be reachable somewhere between them.
--                  Only the player can look up, so a non-player actor's
--                  vertical angle is 0.
--   * distance     centre to centre minus BOTH actors' halfExtents.y, i.e.
--                  bounding-box surface to surface.
--   * height       |actor z - target z| under the same reach.
--   * line of sight  an eye-to-eye ray that only tests world geometry
--                  (PhysicsTaskScheduler::hasLineOfSight filters
--                  World|HeightMap|Door). Other actors never block it.
M.GMST = {
    iMaxActivateDist = core.getGMST('iMaxActivateDist') or 192,
    fCombatDistance  = core.getGMST('fCombatDistance') or 128,
    fCombatAngleXY   = core.getGMST('fCombatAngleXY') or 60.0,
    fCombatAngleZ    = core.getGMST('fCombatAngleZ') or 60.0,
}

--- Vanilla touch reach in game units (bounding-box surface to surface).
function M.touchReach()
    return M.GMST.fCombatDistance
end

local function boxOf(obj)
    return bodyAnchor.boxOf(obj)
end

local function halfSizeOf(obj)
    local box = boxOf(obj)
    if box and box.halfSize then return box.halfSize.z, box.halfSize.y end
    return 0, 0
end

--- Vanilla eye level above the feet: World::getHalfExtents(actor, true).z *
--- 2 * 0.85. Falls back to a normal humanoid height when an actor cannot be
--- measured.
function M.eyeHeightOf(obj)
    local halfZ = halfSizeOf(obj)
    if not halfZ or halfZ <= 0 then return 110.0 end
    return halfZ * 2.0 * 0.85
end

-- ── Vanilla aim point on an actor ─────────────────────────────────────────
-- CastSpell::launchMagicBolt (mwmechanics/spellcasting.cpp) aims at
-- `target.position + halfExtents(target).z` — the CENTRE of the actor's
-- bounding box — and the bolt's impact (and the hit effect the engine spawns at
-- that impact) lands there. A fixed height per caster cannot do that: 70 units
-- above the feet is the middle of a tall humanoid, the chest of a short one and
-- empty air above a small creature, and a bolt aimed at the legs or the ground
-- at somebody's feet puts the hit effect on the floor instead of on the actor.
-- Everything OSSC launches at an actor therefore aims at, and reports as its
-- impact point, this one value.
M.DEFAULT_AIM_HEIGHT = 70

--- The height of an actor's middle above its FEET — the same value
--- `actorAimPoint` adds to the actor's position. Anything that has to place
--- something on the body (the aim point, a hit effect anchored to the actor)
--- measures it here, so the two can never disagree.
function M.actorAnchorHeight(obj, fallbackZ)
    -- One measurement for the whole mod (ossc_body_anchor.lua): the box CENTRE
    -- above the actor's feet, never the inflated cull-safe half-size.
    return bodyAnchor.heightAboveBase(obj, fallbackZ or M.DEFAULT_AIM_HEIGHT)
end

function M.actorAimPoint(obj, fallbackZ)
    if obj == nil or obj.position == nil then return nil end
    return obj.position + util.vector3(0, 0, M.actorAnchorHeight(obj, fallbackZ))
end

-- ── Cast timing fallbacks ─────────────────────────────────────────────────
-- A quick-cast fires its payload on the animation's own `Release` text key.
-- The timers below exist ONLY for a cast whose key never arrives (no
-- animation, a blended group the engine does not report, a lost key) — but a
-- fallback that is EARLIER than the key is not a fallback: it wins the race and
-- the bolt leaves the hand before the gesture reaches it. That is exactly what
-- happened with 0.5 s and 0.65 s against the shipped animations, which put
-- `Release` ~0.8-1.07 s into a group.
--
-- The numbers come from measuring every group's text keys in the shipped
-- animations (time from that group's `Start` to its `Release`, and to its
-- `Stop`):
--
--   animations/xbase_anim/xquickcast.kf   release 1.03-1.10 s, stop 2.10-2.17 s
--   animations/xbase_anim/quickcast.nif   release 0.80-1.03 s, stop 1.90-2.33 s
--
-- so 1.15 s and 2.4 s sit after every one of them and the authored key always
-- drives the cast. The player script has no such timers at all (its release is
-- purely the text key), which is why the gesture felt right for the player and
-- ~0.2 s early on actors.
M.RELEASE_FALLBACK = 1.15
M.FINISH_FALLBACK  = 2.4

--- Seconds to wait before releasing / finishing a cast played at `speed`.
--- Both are scaled by the playback speed, like the animation itself.
function M.castTimings(speed)
    if type(speed) ~= 'number' or speed <= 0 then speed = 1.0 end
    return M.RELEASE_FALLBACK / speed, M.FINISH_FALLBACK / speed
end

--- The blast radius a launch of `spell` really has: the largest `area` among
--- its Target-range effects, or 0 for a bolt that only hits what it hits.
---
--- Spell Framework Plus takes the radius from the launch's own `area` field
--- when the sender provides one and only derives it from the record when the
--- field is absent — so a sender that passed `area = 0` (or a cast table that
--- has no `area` key at all) silently turned every area spell into a single
--- target bolt, and a sender that passed nothing got the record's area and
--- was surprised by a blast it did not expect. Every OSSC launch resolves it
--- here instead, from the effect list it is about to send, so the field always
--- says what the record says.
---
--- The rule itself lives in ossc_spell_area.lua, which the GLOBAL script also
--- requires: `castSpellAtTarget` there (OSSC_Casters / the
--- OSSC_CastSpellAtTarget event) is a fourth sender with the same question, and
--- this module cannot be loaded from that context (it needs openmw.nearby).
function M.impactArea(spell)
    return spellArea.impactArea(spell)
end

--- True when the cast explodes somewhere: any effect with an area of its own.
---
--- OpenMW's `CastSpell::explodeSpell` runs once per effect whose own `mArea` is
--- above zero, at whatever range that effect carries -- a Self nova, a Touch
--- blast, a Target bolt's blast -- and the blast is drawn by the engine (SFP
--- mirrors it in `detonateSpellAtPos`, which spawns the effect's own
--- `areaStatic` exactly as `explodeSpell` does). OSSC must therefore keep its
--- hands off such a cast: taking it over sets `suppressImpactVfx`, which deletes
--- that spawn and replaces it with a HIT static -- the reason a blast was
--- showing the wrong effect entirely.
---
--- Note this is deliberately not `impactArea`, which answers a different
--- question ("how wide is the bolt's blast?") and only looks at Target-range
--- effects: a Touch or Self area spell has no such effect and would slip
--- through.
function M.explodes(spell)
    return spellArea.explodes(spell)
end

local function canMoveByZ(actor)
    if types.Actor.isSwimming(actor) then return true end
    local levitate = types.Actor.activeEffects(actor):getEffect(core.magic.EFFECT_TYPE.Levitate)
    return levitate ~= nil and levitate.magnitude > 0
end

local function isActorLike(obj)
    return obj ~= nil and (obj.type == types.NPC or obj.type == types.Creature)
end

-- World|HeightMap|Door, exactly the mask the engine's own actor-to-actor LOS
-- ray uses. `nearby.COLLISION_TYPE` is missing on old builds: then the ray
-- tests everything and M.losClear tolerates actor hits itself.
local COLLISION = nearby.COLLISION_TYPE
local LOS_COLLISION_TYPES
if COLLISION and COLLISION.World and COLLISION.Door and COLLISION.HeightMap then
    LOS_COLLISION_TYPES = COLLISION.World + COLLISION.Door + COLLISION.HeightMap
end

--- Vanilla line of sight between two actors: eye to eye, world geometry only.
--- Another actor standing between the two never blocks it, and grazing the
--- target's own body at the far end does not either.
function M.losClear(fromPos, toPos, caster, target)
    local res = nearby.castRay(fromPos, toPos, { ignore = caster, collisionType = LOS_COLLISION_TYPES })
    if not res or not res.hit then return true end
    local obj = res.hitObject
    if obj == nil or obj == caster or obj == target then return true end
    if isActorLike(obj) then return true end
    return false
end

-- ── Bystanders on the line of fire ────────────────────────────────────────
-- Vanilla parity (`NPCProjectilesPassThroughBystanders`, default on): a bolt
-- is launched at ONE actor — the one the Combat AI chose — and vanilla never
-- lets anybody else stop it. OSSC therefore states exactly that and nothing
-- more: `userData.passThroughBystanders` + `userData.targetObject`, and Spell
-- Framework Plus drops EVERY actor that is not the named mark from the bolt's
-- collision rays (SF+ README §25b). All actors besides the chosen target are
-- passed through — beside it, in front of it, sharing its record id — and only
-- the mark receives the spell.
--
-- There is deliberately no scan, no radius and no record-id list here. A
-- heuristic that has to guess which actor is "in the way" is what made the
-- setting look dead: a bystander beside the target (past the aim point along
-- the line), one sharing the target's record id (a scan must refuse those, or
-- it would exclude the mark itself) and one the ray walk never reached all
-- produced an empty list, so the launch carried nothing and behaved exactly as
-- if the setting were off.
--
-- With the setting off nothing is sent at all: the first living actor the bolt
-- meets takes the spell, which is the engine's own behaviour.
M.BYSTANDER_MAX       = 4
M.BYSTANDER_STEP      = 2
M.BYSTANDER_TOLERANCE = 60

--- Is `obj` an actor that may be passed THROUGH on the way to `target`?
---
--- Only the line-of-sight walk uses this answer: an actor standing in the line
--- of fire must not hide the target behind it, so the eye ray is restarted past
--- it. The caster and the intended target never qualify; nor does an actor
--- sharing the target's record id (that is the actor the bolt is aimed at, as
--- far as the engine's records go). Dead actors are not an obstruction either.
function M.isPassableBystander(caster, obj, target)
    if obj == nil or obj == caster or obj == target then return false end
    local objType = obj.type
    if objType ~= types.NPC and objType ~= types.Creature then return false end
    if target and obj.recordId ~= nil and obj.recordId == target.recordId then
        return false
    end
    return not types.Actor.isDead(obj)
end

--- Hand Spell Framework Plus the launch's mark, which is what makes the bolt
--- pass through every OTHER actor (the setting, default on).
---
--- `targetObj` is the actor this cast was aimed at — for an actor that is
--- exactly the target the Combat AI chose (`I.AI.getActiveTarget` /
--- `getTargets('Combat')`, the only pool OSSC ever casts at), for the player
--- the actor under the crosshair. Naming it is the whole rule: SF+ keeps the
--- bolt on that one actor and treats everybody else on the way as absent, so
--- no distance, radius or line-of-fire tolerance can leave a bystander out.
---
--- Returns the given table unchanged when there is nothing to ask for — no
--- mark (a cast at a bare position has no bystanders, only a first thing it
--- meets) or the caster itself. Otherwise a copy: callers pass shared
--- constants such as CAST_USER_DATA and they must not be mutated per cast.
function M.requestBystanderPassThrough(userData, caster, targetObj)
    if targetObj == nil or targetObj.isValid == nil or not targetObj:isValid() then
        return userData
    end
    -- Any Actor is a valid mark, the Player included: an actor's hostile cast
    -- at the player is the most common launch that needs this.
    if not types.Actor.objectIsInstance(targetObj) then return userData end
    if targetObj == caster then return userData end
    local out = {}
    for key, value in pairs(userData or {}) do out[key] = value end
    out.passThroughBystanders = true
    out.targetObject          = targetObj
    return out
end

--- Vanilla getHitContact clone: the living actor within touch reach, inside the
--- horizontal/vertical combat tolerance cone in front of `caster`, with line of
--- sight from the eye point. Returns nil when nobody is touchable.
---
--- opts:
---   dirXY     - unit horizontal facing (vector3, z ignored). Defaults to the
---               caster's body yaw (the engine ignores body pitch here).
---   pitchSin  - sine of the vertical look angle (0 = level, which is what the
---               engine uses for every non-player actor).
---   eyePos    - override for the eye point; defaults to the vanilla eye level.
---   candidates- list of actors to consider; defaults to nearby.actors.
---   only      - if set, only this actor is tested (returns it or nil).
function M.findTouchContact(caster, opts)
    opts = opts or {}
    local reach = M.touchReach()
    local angleXY = M.GMST.fCombatAngleXY / 90.0
    local angleZ  = M.GMST.fCombatAngleZ / 90.0

    local actorPos = caster.position
    local eyePos = opts.eyePos or (actorPos + util.vector3(0, 0, M.eyeHeightOf(caster)))
    local dirXY = opts.dirXY
    if not dirXY then
        local f = caster.rotation * util.vector3(0, 1, 0)
        dirXY = util.vector3(f.x, f.y, 0)
    end
    if dirXY:length() > 0 then dirXY = dirXY:normalize() end
    local verticalAngle = opts.pitchSin or 0
    local selfHalfZ, selfHalfY = halfSizeOf(caster)
    local freeZ = canMoveByZ(caster)

    local candidates = opts.only and { opts.only } or (opts.candidates or nearby.actors or {})
    local best, minDist = nil, math.huge
    for _, target in ipairs(candidates) do
        if target ~= caster and target:isValid() and not types.Actor.isDead(target) then
            local targetPos = target.position
            local targetHalfZ, targetHalfY = halfSizeOf(target)
            -- Vanilla getDistanceToBounds (Combat::getDistanceToBounds).
            local dist = (targetPos - actorPos):length() - selfHalfY - targetHalfY
            if dist < 0 then dist = 0 end
            -- Vanilla isInMeleeReach: the same reach bounds the height gap.
            local heightDiff = math.abs(actorPos.z - targetPos.z)
            if dist < minDist and dist < reach and heightDiff < reach then
                local dx, dy = targetPos.x - actorPos.x, targetPos.y - actorPos.y
                local lenXY = math.sqrt(dx * dx + dy * dy)
                if lenXY > 0 then
                    local tx, ty = dx / lenXY, dy / lenXY
                    -- Behind the caster first (dot product)...
                    if tx * dirXY.x + ty * dirXY.y > 0 then
                        -- ...then the perp dot product as the hit-angle sine.
                        local perp = math.abs(tx * dirXY.y - ty * dirXY.x)
                        if perp <= angleXY then
                            local zOk = true
                            if not freeZ then
                                local feet = targetPos - eyePos
                                local head = feet + util.vector3(0, 0, targetHalfZ * 2.0)
                                local fl, hl = feet:length(), head:length()
                                local feetZ = fl > 0 and (feet.z / fl) or 0
                                local headZ = hl > 0 and (head.z / hl) or 0
                                if (verticalAngle - headZ > angleZ) or (verticalAngle - feetZ < -angleZ) then
                                    zOk = false
                                end
                            end
                            if zOk and M.losClear(
                                eyePos,
                                targetPos + util.vector3(0, 0, targetHalfZ * 0.9),
                                caster, target) then
                                minDist, best = dist, target
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

--- True when `target` is a legal Touch target for `caster` by the vanilla
--- touch formula alone (getHitContact: reach, cone, height and line of sight).
---
--- The interactive iMaxActivateDist cap is NOT part of this: the engine only
--- applies it to the player's crosshair target (World::getFocusObject →
--- World::castSpell) — see M.withinActivateDistance. An AI caster has no
--- crosshair, and a load order with a longer fCombatDistance must not be
--- silently clipped for actors.
function M.isTouchTargetInReach(caster, target, opts)
    if not target or not target:isValid() then return false end
    opts = opts or {}
    return M.findTouchContact(caster, {
        eyePos = opts.eyePos, dirXY = opts.dirXY, pitchSin = opts.pitchSin, only = target,
    }) == target
end

-- ── Vanilla activate-distance cap (the player's crosshair target) ─────────
-- World::getFocusObject casts the crosshair ray with iMaxActivateDist as its
-- budget and rejects a focus object further away than that — unless the object
-- allows telekinesis. Actors never do (Class::allowTelekinesis), so a touch
-- target that came from the crosshair is capped at iMaxActivateDist, while a
-- static object may be reached further with Telekinesis.
local function telekinesisReach(caster)
    if not caster then return 0 end
    local tk = types.Actor.activeEffects(caster):getEffect(core.magic.EFFECT_TYPE.Telekinesis)
    if not tk then return 0 end
    return (tk.magnitude or 0) * 22
end

--- Is `aimPos` within the vanilla activate distance of the player's eye?
---
--- opts:
---   camDist           third-person camera distance (the engine's ray starts at
---                     the camera but its budget is measured from the player,
---                     so the same slack has to be added back).
---   allowTelekinesis  true only for objects that allow it (never actors).
---   caster            the player, for the Telekinesis magnitude.
function M.withinActivateDistance(eyePos, aimPos, opts)
    if not eyePos or not aimPos then return false end
    opts = opts or {}
    local maxDist = M.GMST.iMaxActivateDist + (opts.camDist or 0)
    if opts.allowTelekinesis then maxDist = maxDist + telekinesisReach(opts.caster) end
    return (aimPos - eyePos):length() <= maxDist
end

--- True when an actor under the player's crosshair is a legal Touch target.
--- Vanilla accepts it on the activate distance alone: the reach/cone test is
--- only the getHitContact fallback for when the crosshair ray missed, which is
--- why a target a hand's width past fCombatDistance still lands in vanilla.
function M.isCrosshairTouchTarget(caster, target, eyePos, opts)
    if not target or not target:isValid() then return false end
    opts = opts or {}
    local aim = M.actorAimPoint(target) or target.position
    return M.withinActivateDistance(eyePos, aim, {
        camDist          = opts.camDist,
        caster           = caster,
        -- Only non-actors allow telekinesis in the engine.
        allowTelekinesis = not isActorLike(target),
    })
end

-- ── Quick-cast stance gate ─────────────────────────────────────────────────
-- A quick-cast may start from Weapon stance or from relaxed hands, and never
-- from Spell stance. `STANCE.Spell` is the engine's own magic posture: the
-- spell it readied from IS the cast, and layering OSSC's blended quick-cast
-- animation over it produced two gestures fighting for the same arms (the
-- quickcast group blended on top of the engine's spellcast gesture) for a spell
-- the player never fired with the quick-cast key. Vanilla's own cast owns that
-- stance, so OSSC stands down and starts no animation at all; the first cast
-- after leaving Spell stance works exactly as before.
--
-- A `nil` stance (an engine without `types.Actor.STANCE`, or a caller that does
-- not read it) never blocks: the gate is about a stance that is known.
M.SPELL_STANCE = 2  -- types.Actor.STANCE.Spell; spelled out so a caller that
                    -- only has the numeric enum still matches
function M.blocksForSpellStance(stance)
    if stance == nil then return false end
    local spell = types.Actor.STANCE and types.Actor.STANCE.Spell or M.SPELL_STANCE
    return stance == spell
end

--- The OPT-IN exception: allow quick-casting while the engine's Spell stance is
--- up. Off by default (`AllowQuickCastInSpellStance` = false), which is the
--- behaviour described above: no quick-cast, no animation, ever, from Spell
--- stance.
---
--- Turned on, a caster in Spell stance may quick-cast, with the two things that
--- made the default necessary accounted for:
---
---   * `quickcastStanceAllowed` then answers true, so the player, NPC and
---     creature casters all start their blended gesture from the posture;
---   * the engine still owns the stance, so its equip / unequip / VFX
---     suppression (the `SuppressSpellStance` window) must NOT put the stance
---     down under a cast that is starting — the caller drops the suppression for
---     the cast instead. That is the player script's
---     `Stance.releaseSpellStanceForCast()`; actors never suppression-write.
---
--- The argument is the setting's value, read by the caller from its own
--- settings section (the player, NPC and item scripts each have one), so this
--- module stays free of storage.
function M.quickcastStanceAllowed(stance, allowInSpellStance)
    if allowInSpellStance == true then return true end
    if M.blocksForSpellStance(stance) then return false, 'spellStance' end
    return true
end

-- ── Cast veto hooks (modder API) ───────────────────────────────────────────
-- Another mod often has a rule of its own about what the player may cast: a
-- Sane Magic cap, a school restriction, a levitation weight limit. Until now
-- there was nowhere to put it. `addCastHandler` fires from OSSC_OnSpellCast,
-- which is sent AFTER MagExp_CastRequest — the spell is already airborne — so
-- a handler can only report, never refuse. And the vanilla path a mod like that
-- gates on (`self.controls.use == 1 and stance == Spell`) never runs at all for
-- a quick-cast, which is exactly why scrolls and enchanted items could not be
-- stopped.
--
-- A veto is consulted BEFORE anything happens: no animation, no magicka, no
-- fatigue, no item charge, no sound, no launch. Every OSSC caster asks it —
-- the player (hotkey, controller trigger, quickkeys 1-9, hotbar tiles, the
-- OSSC_QuickCast event and castSpellAtTarget) and the NPC / creature casters
-- (spells and enchanted items).
--
--   I.OSSC.addCastVeto(function(cast)
--       if cast.kind == 'scroll' and not I.SaneMagic.canUse(cast.effects) then
--           return false, 'your skill is too low for this scroll'
--       end
--       return true
--   end)
--
-- The handler receives the cast that is about to start:
--   spellId  record id of the spell or enchantment being launched
--   kind     'spell' | 'scroll' | 'item'   (scroll = a CastOnce enchantment)
--   source   'hotkey' | 'quickkey' | 'external' | 'npc' | 'npcItem'
--   effects  the record's effect list (nil for an effect-less record)
--   cost     magicka cost for a spell, 0 for an item
--   charge   the enchantment charge an item cast will spend, when known
--   item     the item's record id for an item / scroll cast
--   isItem / isScroll   booleans, so a handler need not re-derive them
--   caster   the acting object (the player, or the NPC / creature)
-- `false` refuses the cast; the optional second return value is a reason (for
-- the log) and the third is a message shown to the player. Returning anything
-- else — including nil — allows it, so an unrelated handler can never block a
-- cast by accident.
local castVetoHandlers = {}

local enchRecords = core.magic.enchantments.records
local ENCHTYPE = core.magic.ENCHANTMENT_TYPE or {}

--- Build the table handed to a veto handler. `spell` is an OSSC cast model
--- ({ id, effects, cost, item?, enchantment? }); `opts.source` / `opts.charge`
--- / `opts.caster` describe where the request came from.
function M.castPayload(spell, opts)
    opts = opts or {}
    local spellId = spell and spell.id or nil
    local ench = spell and (spell.enchantment
        or (spellId and enchRecords and enchRecords[spellId])) or nil
    local isItem = spell ~= nil and spell.item ~= nil
    local kind = 'spell'
    if isItem then
        -- A CastOnce enchantment is a scroll (one use, item destroyed); any
        -- other castable enchantment is a reusable item. Same split the item
        -- routing in ossc_player.lua uses. `spell.isScroll` wins when the
        -- item caster already resolved it (it reads the book record too, which
        -- a bare enchantment type cannot see).
        local isScroll = spell.isScroll
        if isScroll == nil then
            isScroll = ench ~= nil and ench.type == ENCHTYPE.CastOnce
        end
        kind = isScroll and 'scroll' or 'item'
    end
    return {
        spellId  = spellId,
        kind     = kind,
        source   = opts.source or 'unknown',
        effects  = spell and spell.effects or nil,
        cost     = tonumber(spell and spell.cost) or 0,
        charge   = opts.charge,
        item     = isItem and (opts.itemRecordId
            or (spell.item and spell.item.recordId)) or nil,
        isItem   = isItem,
        isScroll = kind == 'scroll',
        caster   = opts.caster,
    }
end

--- Register a veto. Returns a token for `removeCastVeto`.
function M.addCastVeto(fn)
    if type(fn) ~= 'function' then
        return nil, 'addCastVeto expects a function'
    end
    local entry = { fn = fn, active = true }
    castVetoHandlers[#castVetoHandlers + 1] = entry
    return entry
end

function M.removeCastVeto(token)
    if token == nil then return false end
    if token.active ~= nil then
        token.active = false
        return true
    end
    return false
end

--- True while at least one veto is registered, so callers can skip building a
--- payload (allocation) when nobody is listening.
function M.hasCastVeto()
    for i = 1, #castVetoHandlers do
        if castVetoHandlers[i].active then return true end
    end
    return false
end

--- Ask every registered veto. Returns allowed, reason, message. Only an
--- explicit `false` refuses: a handler that returns nothing changes nothing.
function M.checkCastVeto(payload)
    for i = #castVetoHandlers, 1, -1 do
        local entry = castVetoHandlers[i]
        if entry.active then
            local allowed, reason, message = entry.fn(payload)
            if allowed == false then
                return false, reason, message
            end
        end
    end
    return true
end

--- The one place a refused cast is reported, so every route logs it the same
--- way and the player gets the same optional feedback.
---
--- `opts.fizzle` plays the vanilla 'Spell Failure' sound instead of refusing
--- silently (the Cast Veto Feedback setting). `opts.showMessage` shows the
--- veto's own message when it supplied one.
---
--- A refusal is remembered for VETO_RETRY_DELAY so an NPC caster — which
--- re-evaluates several times a second — is not asked the same question again
--- (and does not fizzle the same failure sound again) every poll: see
--- M.vetoRecentlyRefused, which the caster poll consults.
M.VETO_RETRY_DELAY = 2.0
local vetoRefusedAt = {}

local function actorKey(actor)
    if not actor then return '?' end
    return tostring(actor.id or actor.recordId or tostring(actor))
end

--- True when this caster was just refused a cast; the caller skips an
--- evaluation instead of re-running the veto (and re-fizzling) every poll.
function M.vetoRecentlyRefused(actor, now)
    local at = vetoRefusedAt[actorKey(actor)]
    if not at then return false end
    if (now or core.getSimulationTime()) - at > M.VETO_RETRY_DELAY then
        vetoRefusedAt[actorKey(actor)] = nil
        return false
    end
    return true
end

function M.reportVetoedCast(actor, payload, reason, message, opts)
    opts = opts or {}
    local text = string.format('cast vetoed by a mod: %s (%s, %s)',
        tostring(payload and payload.spellId),
        tostring(payload and payload.kind),
        tostring(reason or 'no reason given'))
    vetoRefusedAt[actorKey(actor)] = core.getSimulationTime()
    if opts.log then opts.log(text) end
    if message and opts.showMessage and type(message) == 'string' and message ~= '' then
        opts.showMessage(message)
    end
    if opts.fizzle and actor and core.sound and core.sound.playSound3d then
        core.sound.playSound3d('Spell Failure', actor, { volume = 1.0 })
    end
    return false, text
end

-- ── Shield suppression during a quick-cast ────────────────────────────────
-- Blocking with a shield would swallow a quick-cast, so a cast may take the
-- shield out of the left hand — and to keep the actor looking unchanged the
-- shield's own mesh is re-attached to the left-hand bone as a "ghost" VFX.
--
-- That ghost only makes sense for a cast that frees a WEAPON grip. A cast with
-- the fists up (nothing in the right hand, i.e. hand-to-hand) has no weapon
-- swing to suppress, so hiding the shield there only produces a shield mesh
-- floating next to a punching arm: hand-to-hand casts keep the shield on and
-- never spawn the ghost. A two-handed weapon / bow / crossbow takes the shield
-- off completely (there is no free hand to hold it), so no ghost either.
--
-- opts:
--   rightWeapon     the item in the right hand, or nil (nil = fists)
--   excludedWeapon  true for a two-handed weapon / bow / crossbow
--   shield          the shield item in the left hand, or nil
--   setting         the BlockShieldDuringQuickcast setting
function M.isHandToHand(rightWeapon)
    return rightWeapon == nil
end

function M.shouldGhostShield(opts)
    if type(opts) ~= 'table' then return false end
    if opts.setting ~= true then return false end
    if M.isHandToHand(opts.rightWeapon) then return false end
    if opts.excludedWeapon then return false end
    return opts.shield ~= nil
end

-- ── Cast animation blending ─────────────────────────────────────────────────
-- Per-bone-group priorities + blend mask for an OSSC cast. openmw.animation
-- .playBlended seeds unlisted groups with PRIORITY.Default (0), so every bone
-- in the blend mask is listed:
--   * LeftArm (+ RightArm + Torso) = PRIORITY.Hit (6): beats Weapon-stance
--     idles so a two-hander's grip cannot pin the casting arm, but stays below
--     PRIORITY.Weapon (7) so a real weapon attack that starts mid-cast wins.
--   * Callers that set preserveAttack = true can keep RightArm + Torso out
--     during a 1H / H2H / thrown attack, so the cast cannot freeze the swing.
--     By default, relaxed stance also uses LeftArm-only; callers can set
--     leftArmOnlyWhenRelaxed = false to blend both arms and Torso in that
--     stance. 'eqcastr' (grimoire right-hand cast) overrides the relaxed rule
--     so it can use RightArm, unless preserving an attack.
--   * LowerBody = PRIORITY.WeaponLowerBody (1), below Movement (5), and is
--     included in the mask by default.
--   * args.lowerBody = false omits LowerBody ENTIRELY (no priority entry, not
--     in the mask) for callers that need the active locomotion/root-motion
--     animation to remain completely unclaimed. NPC/creature casts use this:
--     they are upper-body-only, exactly like the original actor blend.
--   * args.preserveAttack is the player script's 1H / H2H / thrown rule. The
--     actor script only applies it when its attack override is switched off;
--     with the override on (the default for actors) the cast claims the arms.
--
-- * args.attackOverride makes the cast OUTRANK weapon attacks: the claimed
--   arm/torso groups are played at PRIORITY.Block (8), one step above
--   PRIORITY.Weapon (7), instead of PRIORITY.Hit (6). OpenMW pauses every
--   lower-priority animation on a contested bone group, so the cast actually
--   shows while an attack animation is running. That is what an NPC needs when
--   another AI mod (Mercy CAO) keeps swinging: at PRIORITY.Hit the attack wins
--   RightArm/Torso and the quickcast is invisible even though its VFX and
--   payload still happen. The player script never sets this — a swing the
--   player started must keep its arm.
--
-- args: { speed, animGroup, stance, preserveAttack, lowerBody,
--         leftArmOnlyWhenRelaxed, attackOverride, weaponTransition }
function M.buildCastBlendOptions(args)
    local BONE, PRIO, BMASK = anim.BONE_GROUP, anim.PRIORITY, anim.BLEND_MASK
    local includeLowerBody = args.lowerBody ~= false
    -- Above PRIORITY.Weapon (7): PRIORITY.Block is the next defined value.
    local castPriority = PRIO.Hit
    if args.attackOverride == true then
        castPriority = PRIO.Block or (PRIO.Weapon + 1)
    end
    local priority = {
        [BONE.LeftArm]   = castPriority,
    }
    if includeLowerBody then priority[BONE.LowerBody] = PRIO.WeaponLowerBody end
    local blendMask = BMASK.LeftArm
    if includeLowerBody then blendMask = blendMask + BMASK.LowerBody end
    local relaxed = args.stance == nil or args.stance == types.Actor.STANCE.Nothing
    if args.animGroup == 'eqcastr' then relaxed = false end
    local leftArmOnlyWhenRelaxed = args.leftArmOnlyWhenRelaxed ~= false
    -- An overriding cast always claims the whole upper body: yielding the
    -- weapon arm to an attack is exactly what made it invisible.
    -- `weaponTransition` (a ready / unready play of the actor's own weapon is
    -- in flight) forces the casting hand alone, at the override priority: the
    -- gesture keeps playing on LeftArm while the transition finishes on
    -- RightArm + Torso. An overriding cast otherwise claims the whole upper
    -- body, and that is exactly what used to freeze a ready / unready.
    local leftArmOnly = args.attackOverride ~= true
        and (args.preserveAttack == true
             or (relaxed and leftArmOnlyWhenRelaxed))
    if args.weaponTransition == true then
        leftArmOnly = true
    end
    if not leftArmOnly then
        priority[BONE.RightArm] = castPriority
        priority[BONE.Torso]    = castPriority
        blendMask = blendMask + BMASK.RightArm + BMASK.Torso
    end
    return {
        priority  = priority,
        startKey  = 'start',
        stopKey   = 'stop',
        blendMask = blendMask,
        speed     = args.speed or 1.0,
    }, leftArmOnly
end

return M
