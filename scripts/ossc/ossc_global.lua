---@omw-context global
-- ============================================================
-- OSSC: Oblivion-Style Spell Casting - global script
-- Item/charge consumption and actor script attachment.
-- ============================================================
local core    = require('openmw.core')
local types   = require('openmw.types')
local storage = require('openmw.storage')
local vfs     = require('openmw.vfs')
local I       = require('openmw.interfaces')
local util    = require('openmw.util')
local world   = require('openmw.world')
-- Placement of a spell's hit statics (see the module: vanilla draws them
-- at the impact point, SF+ attaches them at the actor's feet).
local impactVfx = require('scripts.ossc.ossc_impact_vfx')
-- The blast rules every caster shares (ossc_cast_rules re-exports the
-- same two functions) and the one measurement of an actor's middle.
-- Both need only global packages, which is why they can be loaded here.
local spellArea  = require('scripts.ossc.ossc_spell_area')
local bodyAnchor = require('scripts.ossc.ossc_body_anchor')

local SCRIPT_NPC      = 'scripts/ossc/ossc_npc.lua'
local SCRIPT_CREATURE = 'scripts/ossc/ossc_creature.lua'
local SCRIPT_ITEMS    = 'scripts/ossc/ossc_actor_items.lua'

-- Settings mirror: player storage is unreadable here; read the global copy sent via OSSC_SyncSettings.
local SYNCED_SETTING_GROUPS = {
    ['SettingsOSSC_General']     = true,
    -- SettingsOSSC_NPC_AI is gone: the decision settings are part of the
    -- SettingsOSSC_NPC group now.
    ['SettingsOSSC_NPC']         = true,
    ['SettingsOSSC_Animations']  = true,
    ['SettingsOSSC_AnimSpeeds']  = true,
    ['SettingsOSSC_Keys']        = true,
}
local NO_VALUES = {}

local generalSettings = storage.globalSection('SettingsOSSC_General')
local npcSettings     = storage.globalSection('SettingsOSSC_NPC')

local function settingOr(section, key, default)
    local value = section:get(key)
    if value == nil then return default end
    return value
end

local function debugModeEnabled()
    return generalSettings:get('DebugMode') == true
end

-- ── Spell classification ──
-- require of a missing file throws: probe the VFS and fall back to the built-in classifier.
local CASTER_UTILS_FILE   = 'scripts/ossc/ossc_caster_utils.lua'
local CASTER_UTILS_MODULE = 'scripts.ossc.ossc_caster_utils'

local function builtinIsCastableSpellRecord(record, allowPowers)
    if not record then return false end
    if record.type == core.magic.SPELL_TYPE.Spell then return true end
    return allowPowers == true and record.type == core.magic.SPELL_TYPE.Power
end

local function builtinHasCastableSpell(actor, allowPowers)
    local knownSpells = types.Actor.spells(actor)
    if not knownSpells then return false end
    local spellRecords = core.magic.spells.records
    local function spellIdFromEntry(key, value)
        if type(value) == 'string' then return value end
        -- No pcall: a raising `id` read is an engine-binding error and must
        -- surface instead of making the actor look spell-less.
        if type(value) == 'table' or type(value) == 'userdata' then
            local id = value.id
            if type(id) == 'string' then return id end
        end
        if type(key) == 'string' then return key end
        return nil
    end
    for key, knownSpell in pairs(knownSpells) do
        local spellId = spellIdFromEntry(key, knownSpell)
        if spellId and builtinIsCastableSpellRecord(spellRecords[spellId], allowPowers) then return true end
    end
    return false
end

local casterUtils
if vfs.fileExists(CASTER_UTILS_FILE) then
    casterUtils = require(CASTER_UTILS_MODULE)
else
    print('[OSSC] ' .. CASTER_UTILS_FILE .. ' unavailable (module not found: ' .. CASTER_UTILS_MODULE
        .. '); using the built-in spell classifier. Update/reinstall OSSC.')
    casterUtils = {
        isCastableSpellRecord = builtinIsCastableSpellRecord,
        hasCastableSpell = builtinHasCastableSpell,
    }
end

-- Built-in NPC-settings fallback; defaults mirror ossc_settings.lua.
local builtinNPCSettingsDefaults = {
    NPCQuickCastEnabled           = true,
    NPCQuickCastCreatures         = true,
    NPCQuickCastNonBipedCreatures = true,
    NPCQuickCastDebugLog          = false,
    NPCQuickCastAllowPowers       = false,
    NPCQuickCastRandomAnims       = true,
    NPCQuickCastPollInterval      = 1.0,
    NPCQuickCastBaseChance        = 100,
    NPCQuickCastMinDistance       = 500,
    NPCQuickCastMaxDistance       = 700,
    NPCQuickCastHealThreshold     = 40,
    NPCQuickCastTouchChance       = 60,
    NPCQuickCastTouchTargetChance = 10,
    NPCQuickCastCooldownMin       = 3.5,
    NPCQuickCastCooldownMax       = 8.5,
    NPCMercyVanillaCastWindow      = 5.0,
    NPCMercyQuickcastWindow        = true,
    NPCMercyQuickcastWindowCooldown = 2.0,
    NPCQuickCastEquipReadiness      = 1.5,
    NPCVanillaCastUnequipTimeout    = 5.0,
    NPCVanillaCastsAllowedMin       = 1,
    NPCVanillaCastsAllowedMax       = 2,
    NPCVanillaCastAllowanceTimeout  = 6.0,
    NPCVanillaCastAllowanceReadiness = 1.5,
    NPCProjectilesPassThroughBystanders = true,
    NPCPauseResumeGrace            = 2.0,
}
local function builtinReadNPCSettings(section)
    local values = {}
    for key, default in pairs(builtinNPCSettingsDefaults) do
        local value = section and section:get(key)
        if value == nil then value = default end
        values[key] = value
    end
    return values
end
local readNPCSettings = type(casterUtils.readNPCSettings) == 'function'
    and casterUtils.readNPCSettings or builtinReadNPCSettings

-- ── Eligibility ────────────────────────────────────────────────────────────
local function hasCastOnUseItem(actor)
    local inventory = types.Actor.inventory(actor)
    if not inventory then return false end
    local ENCHANTMENT_TYPE = core.magic.ENCHANTMENT_TYPE
    local enchantmentRecords = core.magic.enchantments.records
    for _, item in ipairs(inventory:getAll()) do
        local objectType = item.type
        local record = objectType and objectType.record and objectType.record(item)
        local enchantId = record and record.enchant
        if enchantId and enchantId ~= '' then
            local enchantment = enchantmentRecords[enchantId]
            if enchantment and (enchantment.type == ENCHANTMENT_TYPE.CastOnUse
                or enchantment.type == ENCHANTMENT_TYPE.CastOnce) then
                return true
            end
        end
    end
    return false
end

local function isBipedCreature(actor)
    local record = types.Creature.record(actor)
    return record ~= nil and record.isBiped == true
end

-- Caster scripts hide castable spells while attached: spell presence is an eligibility check only, never combat discovery.
local function isCasterEligible(actor, alreadyManaged)
    if actor.type == types.Player or types.Actor.isDead(actor) then return false end
    if not settingOr(npcSettings, 'NPCQuickCastEnabled', true) then return false end

    if actor.type == types.Creature then
        if not settingOr(npcSettings, 'NPCQuickCastCreatures', true) then return false end
        -- Non-biped creatures have their own toggle.
        if not settingOr(npcSettings, 'NPCQuickCastNonBipedCreatures', true) and not isBipedCreature(actor) then
            return false
        end
    elseif actor.type ~= types.NPC then
        return false
    end

    -- Attached caster hides its spells; stay eligible across later combat events.
    if alreadyManaged then return true end

    local allowPowers = settingOr(npcSettings, 'NPCQuickCastAllowPowers', false)
    if casterUtils.hasCastableSpell(actor, allowPowers) then return true end
    return hasCastOnUseItem(actor)
end

-- Non-biped creatures qualify only via a castable Spell (or Power if enabled) in Actor.spells; Abilities never do.
-- Already-managed actors stay eligible (their spells are hidden).
local function isEligibleCreatureBody(actor, alreadyManaged)
    if isBipedCreature(actor) then return true end
    if not settingOr(npcSettings, 'NPCQuickCastNonBipedCreatures', true) then return false end
    if alreadyManaged then return true end
    return casterUtils.hasCastableSpell(actor, settingOr(npcSettings, 'NPCQuickCastAllowPowers', false))
end

-- ── Script attach / detach ─────────────────────────────────────────────────
local function attachScript(actor, path)
    if actor:hasScript(path) then return end
    actor:addScript(path)
    if debugModeEnabled() then
        print(string.format('[OSSC Global] Attached %s to %s', path, tostring(actor.recordId)))
    end
end

local function detachScript(actor, path)
    if not actor:hasScript(path) then return end
    actor:removeScript(path)
    if debugModeEnabled() then
        print(string.format('[OSSC Global] Removed %s from %s', path, tostring(actor.recordId)))
    end
end

-- ── Spell Framework Plus hit VFX on a non-player target ────────────────────
-- SFP renders a spell's per-effect hit static by sending an `AddVfx` event to
-- the TARGET's own local script, which is a CUSTOM script: it is only attached
-- on demand, and only a GLOBAL script may attach one. SFP's launch path attaches
-- its own handler to the CASTER, never to the target, and for a plain
-- (non-persistent) effect it does not attach it at all — which is why an
-- actor's quick-cast at the Player looked right (the Player has the handler in
-- SFP's player script) while the player's quick-cast at an actor showed no VFX
-- on impact at all: the event went to an actor with nothing to interpret it.
--
-- OSSC's caster scripts therefore hand their intended target here, before the
-- launch, and this side attaches a handler. It attaches OSSC's own
-- (scripts/ossc/ossc_actor_hit_vfx.lua) rather than SFP's, because SFP's anchors
-- the effect to the actor's node — the ground at its FEET — while a hit has to
-- bloom on the body the bolt was aimed at. The interface check keeps the whole
-- thing inert when SFP is not installed (only SFP's own global script registers
-- I.MagExp, and only its manifest registers the scripts that read these events).
local ACTOR_HIT_VFX_SCRIPT  = 'scripts/ossc/ossc_actor_hit_vfx.lua'
local SFP_ACTOR_VFX_SCRIPT  = 'scripts/OMW_MagExp/magexp_actor_vfx.lua'

-- Whether the engine knows the OSSC handler at all: nil until asked, then true
-- or false for the rest of the session.
--
-- `addScript` RAISES "Unknown script: <path>" for a path that is not in the
-- scripts configuration, and that configuration only comes from an
-- `.omwscripts` file read at startup (components/lua/configuration.cpp,
-- parseOMWScripts). There is no way to ask first: `Object:hasScript` returns
-- false both for a known-but-unattached script and for a path nobody
-- registered, so the only way to learn the answer is to try once.
--
-- Hence one guarded attempt, cached, and — crucially — REPORTED instead of
-- swallowed: a target whose handler cannot be attached is left with something
-- that can draw hit VFX (SFP's own handler) and the player is told, in plain
-- words, which file is out of date. That beats an exception on every hit, which
-- is what an unguarded `addScript` used to produce.
local hitVfxScriptRegistered = nil

-- The one failure worth recovering from is the engine not knowing the path at
-- all. Anything else (an invalid object, a real engine refusal) is a bug and is
-- re-raised untouched instead of being misreported as a stale install.
local function isUnknownScriptError(err)
    return type(err) == 'string' and err:find('Unknown script', 1, true) ~= nil
end

local function ensureHitVfxHandler(actor)
    if not (actor and actor.isValid and actor:isValid()) then return false end
    local actorType = actor.type
    if actorType ~= types.NPC and actorType ~= types.Creature then return false end
    if types.Actor.isDead(actor) then return false end
    if not (I and I.MagExp) then return false end

    if hitVfxScriptRegistered == nil then
        local ok, err = pcall(attachScript, actor, ACTOR_HIT_VFX_SCRIPT)
        if not ok and not isUnknownScriptError(err) then error(err, 0) end
        hitVfxScriptRegistered = ok
        if not ok then
            print('[OSSC Global] ' .. ACTOR_HIT_VFX_SCRIPT .. ' is not registered with the engine, so'
                .. ' hit VFX cannot be anchored to the body. The engine registers CUSTOM scripts when'
                .. ' it starts, from the .omwscripts content file: the running install of'
                .. ' "Oblivion Style Spell Casting OSSC.omwscripts" is older than the scripts and does'
                .. ' not list "CUSTOM: ' .. ACTOR_HIT_VFX_SCRIPT .. '". Update that file (it ships'
                .. ' with these scripts) and restart the game. Impact statics are unaffected — OSSC'
                .. ' draws those itself at the hit point — but a looping/persistent effect (shield'
                .. ' and friends) stays at the actor\'s feet until the file is updated.')
        end
    elseif hitVfxScriptRegistered then
        attachScript(actor, ACTOR_HIT_VFX_SCRIPT)
    end

    if hitVfxScriptRegistered then
        -- One interpreter per actor: OSSC's copy reads the same AddVfx /
        -- RemoveVfx protocol but lifts the effect to the body, so SFP's
        -- feet-anchored copy is removed (leaving both would add every
        -- non-looping hit effect twice). Only reached once OSSC's handler is
        -- known to be attachable — the old order removed SFP's first and then
        -- died on the addScript, leaving the actor with no handler at all.
        detachScript(actor, SFP_ACTOR_VFX_SCRIPT)
    else
        -- Fallback: keep hit VFX working at all (SFP's placement) instead of
        -- leaving the actor unable to interpret the events.
        attachScript(actor, SFP_ACTOR_VFX_SCRIPT)
    end
    return hitVfxScriptRegistered
end

-- Which local script on `actor` interprets Spell Framework Plus' per-effect
-- `AddVfx`, or nil when it has none yet. OSSC's copy and SFP's own are the
-- same pass-through (`anim.addVfx(self, model, options)`), so either is a
-- valid target for a hit static; what must never happen is BOTH being
-- attached, which is why ensureHitVfxHandler removes SFP's when it adds
-- OSSC's.
local function hitVfxHandlerOf(actor)
    if actor:hasScript(ACTOR_HIT_VFX_SCRIPT) then return ACTOR_HIT_VFX_SCRIPT end
    if actor:hasScript(SFP_ACTOR_VFX_SCRIPT) then return SFP_ACTOR_VFX_SCRIPT end
    return nil
end

-- ── Caster pause route ──
-- The actor's local script owns the pause; this forwards requests and mirrors them.
-- A pause request attaches the caster script on demand. Keyed by actor.id, not object.
local actorPauseRequests = {}   -- [actor.id] = { actor = actor, reasons = { [reason] = true } }

local function casterScriptFor(actor)
    if not (actor and actor.isValid and actor:isValid()) then return nil end
    if actor.type == types.Creature then return SCRIPT_CREATURE end
    if actor.type == types.NPC then return SCRIPT_NPC end
    return nil
end

-- Forward a pause request to the actor's caster script. False when OSSC does not manage the actor.
local function setActorPaused(actor, paused, reason)
    local path = casterScriptFor(actor)
    if not path then return false end
    if type(reason) ~= 'string' or reason == '' then reason = nil end

    if not actor:hasScript(path) then
        if not isCasterEligible(actor, false) then return false end
        attachScript(actor, path)
    end

    local journal = actorPauseRequests[actor.id]
    if paused then
        if not journal then
            journal = { actor = actor, reasons = {} }
            actorPauseRequests[actor.id] = journal
        end
        journal.reasons[reason or 'external'] = true
    elseif journal then
        if reason == nil then
            actorPauseRequests[actor.id] = nil
        else
            journal.reasons[reason] = nil
            if next(journal.reasons) == nil then actorPauseRequests[actor.id] = nil end
        end
    end

    actor:sendEvent('OSSC_SetCasterPaused', { paused = paused, reason = reason })
    if debugModeEnabled() then
        print(string.format('[OSSC Global] %s caster %s (reason %s)',
            paused and 'paused' or 'resumed', tostring(actor.recordId), tostring(reason or 'all')))
    end
    return true
end

-- ── Public API: spell filter + on-demand casts (I.OSSC_Casters) ────────────
-- Two things other mods (and OSSC's own scripts) need to be able to tell OSSC:
--
--   1. "never pick this spell for me" — a spell the mod does not want OSSC to
--      choose on its own.  This is a *spell-picking* veto, not a cast veto: the
--      actor still knows the spell, still casts it when something asks for it
--      explicitly (a hotkey, or castSpellAtTarget below), it is only skipped
--      when OSSC is the one choosing (ossc_npc's categorizeSpells).  Keeping a
--      spell out of OSSC's rotation is how a mod says "I drive this one".
--   2. "cast this spell at this target, now" — a single cast request OSSC
--      turns into a real, fully-animated cast through the same Spell Framework
--      Plus pipeline OSSC's own quick-casts use (MagExp_CastRequest).
--
-- The filter lives here (the global script) because it has to be visible to
-- every actor script: the list is mirrored into each managed caster, pushed
-- again whenever it changes, and handed to any script that asks for it.
-- Persisted in global storage so it survives a save/load, and so a mod that
-- registers its vetoes once at load does not have to re-register after a
-- reload.  Keys are record ids (case-insensitive, stored lowercased).
local SPELL_FILTER_KEY = 'IgnoredSpells'
local spellFilterSection = storage.globalSection('OSSC_SpellFilter')

local ignoredSpells = {}        -- [lowercased record id] = true
local ignoredSpellIds = {}      -- list form, kept in sync for the broadcasts
local ignoredSpellVersion = 0
local ignoredSpellsLoaded = false

local function normalizeSpellKey(spellId)
    if type(spellId) ~= 'string' then return nil end
    local key = spellId:lower()
    if key == '' then return nil end
    return key
end

local function ignoredSpellList()
    local list = {}
    for spellId in pairs(ignoredSpells) do list[#list + 1] = spellId end
    table.sort(list)
    return list
end

local function loadIgnoredSpells()
    if ignoredSpellsLoaded then return end
    ignoredSpellsLoaded = true
    local stored = spellFilterSection:get(SPELL_FILTER_KEY)
    if stored == nil then return end
    -- OpenMW storage returns serialized arrays as userdata proxies, not Lua
    -- tables. ipairs works with the proxy's indexed access metamethod.
    for _, spellId in ipairs(stored) do
        local key = normalizeSpellKey(spellId)
        if key then ignoredSpells[key] = true end
    end
    ignoredSpellIds = ignoredSpellList()
end

-- Declared here, assigned after combatActors.
local broadcastIgnoredSpells

local function isSpellIgnored(spellId)
    loadIgnoredSpells()
    local key = normalizeSpellKey(spellId)
    if not key then return false end
    return ignoredSpells[key] == true
end

local function setSpellIgnored(spellId, ignored)
    loadIgnoredSpells()
    local key = normalizeSpellKey(spellId)
    if not key then
        return false, 'spellId must be a record id string'
    end
    local wanted = ignored ~= false
    if wanted == (ignoredSpells[key] == true) then return true, false end
    ignoredSpells[key] = wanted or nil
    ignoredSpellIds = ignoredSpellList()
    ignoredSpellVersion = ignoredSpellVersion + 1
    spellFilterSection:set(SPELL_FILTER_KEY, ignoredSpellIds)
    broadcastIgnoredSpells()
    return true, true
end

local function setIgnoredSpells(list)
    if type(list) ~= 'table' then return false, 'a list of spell record ids is required' end
    ignoredSpellsLoaded = true
    ignoredSpells = {}
    for _, spellId in ipairs(list) do
        local key = normalizeSpellKey(spellId)
        if key then ignoredSpells[key] = true end
    end
    ignoredSpellIds = ignoredSpellList()
    ignoredSpellVersion = ignoredSpellVersion + 1
    spellFilterSection:set(SPELL_FILTER_KEY, ignoredSpellIds)
    broadcastIgnoredSpells()
    return true, true
end

-- ── On-demand casts ──
-- castSpellAtTarget({ caster, spellId, target?, effectScale?, isFree?, userData? }) via MagExp_CastRequest.
-- Player casts are routed to the player script.
local function isTargetObject(value)
    local kind = type(value)
    if kind ~= 'userdata' and kind ~= 'table' then return false end
    return value.position ~= nil and value.isValid ~= nil
end

local function resolveAimPoint(target)
    if target == nil then return nil, nil end
    if isTargetObject(target) then
        if not (target.isValid and target:isValid()) then return nil, nil end
        -- The middle of the body, measured the way every OSSC caster measures it
        -- (ossc_body_anchor: the box CENTRE, clamped into the torso band). It
        -- used to be a flat +60, which is not any actor's middle: a short
        -- creature was aimed over its head and a tall one under the chest.
        return bodyAnchor.point(target) or target.position, target
    end
    if target.x ~= nil and target.y ~= nil and target.z ~= nil then
        return target, nil
    end
    return nil, nil
end

-- Self-sent request for an actor with no OSSC script; isFree defaults false so SFP charges at launch.
local function sendCastRequest(caster, record, args)
    local startPos = args.startPos or caster.position or util.vector3(0, 0, 0)
    local aimPoint, hitObject = resolveAimPoint(args.target)
    if not hitObject and args.hitObject and isTargetObject(args.hitObject) then
        hitObject = args.hitObject
    end
    local direction = args.direction
    if not direction and aimPoint then
        direction = (aimPoint - startPos):normalize()
    end
    if not direction then
        direction = caster.rotation * util.vector3(0, 1, 0)
    end
    local userData = { OSSC = true, External = true }
    if type(args.userData) == 'table' then
        for key, value in pairs(args.userData) do userData[key] = value end
    end
    -- The bolt will land on `hitObject`: it has to be able to show SFP's hit
    -- VFX (see ensureHitVfxHandler). Cheap and idempotent.
    if hitObject then ensureHitVfxHandler(hitObject) end
    local range = record.effects and record.effects[1] and record.effects[1].range
    -- The launch's `area` IS the bolt's blast radius as far as SFP is concerned
    -- (`area = 0` is a plain bolt, not "read the record"), so it is resolved from
    -- the record's TARGET-range effects — the same rule the player's and the
    -- actor's quick-casts use. Reading `effects[1].area` was wrong for every
    -- spell whose first effect is not the exploding one (the usual layout: a
    -- Self or Touch rider in front of the blast), and those casts reached SFP
    -- with `area = 0` and never exploded.
    local area = args.area
    if area == nil then
        area = spellArea.impactArea(record)
    end
    if range == core.magic.RANGE.Self then
        hitObject = caster
        aimPoint = nil
    end
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker       = caster,
        caster         = caster,
        spellId        = args.spellId,
        startPos       = startPos,
        direction      = direction,
        area           = area,
        isFree         = args.isFree == true,
        item           = args.item,
        itemRecordId   = args.item and args.item.recordId or nil,
        hitObject      = hitObject,
        hitPos         = args.hitPos or aimPoint,
        spawnOffset    = args.spawnOffset,
        isGodMode      = false,
        effectScale    = args.effectScale or 1.0,
        showAllCastVfx = args.showAllCastVfx ~= false,
        userData       = userData,
    })
    return true
end

local function castSpellAtTarget(args)
    if type(args) ~= 'table' then
        return false, 'a request table is required'
    end
    local caster = args.caster
    if not (caster and caster.isValid and caster:isValid()) then
        return false, 'caster must be a valid game object'
    end
    if not types.Actor.objectIsInstance(caster) then
        return false, 'caster must be an actor'
    end
    if types.Actor.isDead(caster) then
        return false, 'caster is dead'
    end
    if type(args.spellId) ~= 'string' or args.spellId == '' then
        return false, 'spellId must be a record id string'
    end
    local record = core.magic.spells.records[args.spellId]
    if not record then
        return false, 'unknown spell record: ' .. tostring(args.spellId)
    end
    -- The player's own OSSC script knows the quick-cast penalty settings (and
    -- refuses a cast while the game is not accepting input); hand the request
    -- to it rather than building a second, differently-penalised cast here.
    if types.Player.objectIsInstance(caster) then
        -- Local interfaces are not visible to a global script. Route through
        -- the player's actor event handler so its settings and penalties are
        -- applied by the owning player script.
        caster:sendEvent('OSSC_ExternalCastRequest', args)
        return true
    end
    return sendCastRequest(caster, record, args)
end

local OSSC_CastersInterface = {
    version = 1,
    -- Pause/unpause; reasons are independent. unpause(actor) with no reason releases all.
    pause     = function(actor, reason) return setActorPaused(actor, true, reason) end,
    unpause   = function(actor, reason) return setActorPaused(actor, false, reason) end,
    setPaused = function(actor, paused, reason)
        return setActorPaused(actor, paused == true, reason)
    end,
    -- True when this route holds a pause (mirror only; actor script is authoritative).
    isPaused = function(actor) return actor ~= nil and actorPauseRequests[actor.id] ~= nil end,
    -- Caster script an actor would use; check hasScript before relying on the interface.
    casterScript = casterScriptFor,

    -- ── Spell filter ──
    ignoreSpell        = function(spellId) return setSpellIgnored(spellId, true) end,
    unignoreSpell      = function(spellId) return setSpellIgnored(spellId, false) end,
    setSpellIgnored    = function(spellId, ignored) return setSpellIgnored(spellId, ignored) end,
    isSpellIgnored     = isSpellIgnored,
    getIgnoredSpells   = function() loadIgnoredSpells(); return ignoredSpellList() end,
    setIgnoredSpells   = setIgnoredSpells,
    clearIgnoredSpells = function() return setIgnoredSpells({}) end,

    -- ── An on-demand cast for any actor (see the block above) ──────────────
    castSpellAtTarget  = castSpellAtTarget,

    -- ── Settings read-out ──────────────────────────────────────────────────
    --- The distance (game units) at or below which an NPC/creature's
    --- quick-cast probability is at its maximum — the "100% chance distance"
    --- of the NPC settings (Base Quick-Cast Probability defaults to 100%).
    --- This is the live `NPCQuickCastMinDistance` value the attached caster
    --- scripts roll against: at or below it every evaluation uses the full
    --- base chance, above it the chance falls linearly to 0 at
    --- `NPCQuickCastMaxDistance`.  Exposed so other mods can forward the
    --- player's configured distance into their own range logic instead of
    --- hardcoding the 500 default.
    getQuickCastFullChanceDistance = function()
        -- Same clamp the actor scripts apply in refreshSettings: the menu
        -- allows a Full Chance Distance larger than the Maximum Cast Distance,
        -- and the roll then uses the Maximum as the end of the full-chance
        -- band. Reporting the raw value here made this read-out disagree with
        -- what the casters actually roll against.
        local minDist = tonumber(settingOr(npcSettings, 'NPCQuickCastMinDistance', 500)) or 500
        local maxDist = tonumber(settingOr(npcSettings, 'NPCQuickCastMaxDistance', 700)) or 700
        if minDist > maxDist then minDist = maxDist end
        return minDist
    end,

    --- Every NPC/creature quick-cast setting (the SettingsOSSC_NPC group) as
    --- a live snapshot table: each registered key maps to its current value,
    --- falling back to the registered default while unset (e.g. before the
    --- settings mirror's first sync).  The keys are NPCQuickCastEnabled,
    --- NPCQuickCastCreatures, NPCQuickCastNonBipedCreatures,
    --- NPCQuickCastDebugLog, NPCQuickCastAllowPowers, NPCQuickCastRandomAnims,
    --- NPCQuickCastPollInterval, NPCQuickCastBaseChance,
    --- NPCQuickCastMinDistance, NPCQuickCastMaxDistance,
    --- NPCQuickCastHealThreshold, NPCQuickCastTouchChance,
    --- NPCQuickCastTouchTargetChance, NPCQuickCastCooldownMin,
    --- NPCQuickCastCooldownMax, NPCMercyVanillaCastWindow,
    --- NPCMercyQuickcastWindow, NPCMercyQuickcastWindowCooldown,
    --- NPCMercyQuickcastWindowCooldown,
    --- NPCQuickCastEquipReadiness,
    --- NPCVanillaCastUnequipTimeout, NPCVanillaCastsAllowedMin,
    --- NPCVanillaCastsAllowedMax, NPCVanillaCastAllowanceTimeout,
    --- NPCVanillaCastAllowanceReadiness,
    --- NPCProjectilesPassThroughBystanders and NPCPauseResumeGrace.
    --- The result is a fresh copy — safe to keep or
    --- mutate.  getQuickCastFullChanceDistance() above is the convenience
    --- read-out of NPCQuickCastMinDistance.
    getNPCSettings = function()
        return readNPCSettings(npcSettings)
    end,
}

-- OSSC must only exist on actors currently reported by OpenMW's combat-music
-- tracker. Do not infer combat from spell lists: that both attaches scripts to
-- idle actors and fails when an actor has no castable spell.
-- Object handles received through different events need not be the same Lua
-- userdata. Even when a == b, table keys do not use __eq. Key ALL lifecycle
-- state by actor.id; otherwise an old onActorActive(false) entry can ask the
-- janitor to suspend a fighting actor, and its detach acks never find it.
local combatActors = {} -- [actor.id] = { actor, wanted, rawInCombat }

--- Hand the current spell filter to everything that picks spells: every actor
--- OSSC manages, and the player (whose script keeps a mirror so I.OSSC can
--- answer isSpellIgnored without a round trip).  A script that is not attached
--- simply has no handler, which is why this is broadcast rather than acked.
broadcastIgnoredSpells = function()
    local payload = { version = ignoredSpellVersion, ids = ignoredSpellList() }
    for _, state in pairs(combatActors) do
        local actor = state.actor
        if actor and actor.isValid and actor:isValid() then
            actor:sendEvent('OSSC_SetIgnoredSpells', payload)
        end
    end
    for _, player in ipairs(world.players) do
        if player and player:isValid() then
            player:sendEvent('OSSC_SetIgnoredSpells', payload)
        end
    end
end
-- rawInCombat preserves the last combat signal even when settings reject the
-- actor. wanted is the gated attachment state; the janitor compares the raw
-- signal with current settings so toggles work without another combat event.

-- ── Safe detach protocol ───────────────────────────────────────────────────
-- Removing an actor script while its unsavable cast timers are still pending
-- makes the engine log "callTimer failed: Script doesn't exist" / "map::at":
-- a timer's callback lives inside the script that created it, so a guard
-- inside the callback can never run once the script is gone. Instead:
--   1. we broadcast OSSC_CombatEnded (scripts restore spells, cancel casts);
--   2. each attached script acks with OSSC_ReadyToDetach once every timer it
--      created has certainly fired (it re-waits if a cast is still running);
--   3. we remove the scripts only after every attached script has acked (and
--      combat has not resumed meanwhile);
--   4. the janitor in onUpdate force-removes scripts that never ack (e.g. a
--      script that failed to load) once DETACH_TIMEOUT has passed — bounded by
--      the NPC script's 0.1x minimum cast speed, so real cast timers have
--      always drained by then.
local pendingDetach = {}
local DETACH_TIMEOUT   = 30.0
local JANITOR_INTERVAL = 5.0
local janitorElapsed   = 0.0

local function detachScriptsNow(actor, paths)
    if not actor:isValid() then return end
    for _, path in ipairs(paths) do
        detachScript(actor, path)
    end
end

local function requestDetach(actor, paths)
    -- Supersedes any previous detach request.
    actor:sendEvent('OSSC_CombatEnded')
    pendingDetach[actor.id] = {
        actor = actor,
        scripts = paths,
        acked = {},
        deadline = core.getSimulationTime() + DETACH_TIMEOUT,
    }
end

local function onReadyToDetach(data)
    local actor = data and data.actor
    if not actor or not actor:isValid() then return end
    local entry = pendingDetach[actor.id]
    if not entry then return end
    if data.script then entry.acked[tostring(data.script)] = true end
    for _, path in ipairs(entry.scripts) do
        if not entry.acked[path] then return end                -- still waiting
    end
    pendingDetach[actor.id] = nil
    if combatActors[actor.id] and combatActors[actor.id].wanted then return end
    detachScriptsNow(actor, entry.scripts)
end

local function setCombatScripts(actor, inCombat)
    if not actor or not actor:isValid() or actor.type == types.Player then return end

    -- Capture the raw combat signal before any gating below: the janitor
    -- compares it against live eligibility, so settings/body rejects must
    -- never erase it. Death, unlike a settings reject, really ends combat.
    local rawInCombat = inCombat == true and not types.Actor.isDead(actor)

    -- A dead actor is never in combat: force the detach path so its scripts
    -- are removed promptly instead of idling on a corpse until the cell
    -- unloads (the combat-music tracker can keep reporting a corpse's
    -- targets for a while; the eligibility check below also rejects the
    -- dead, so their casts are impossible anyway).
    if types.Actor.isDead(actor) then inCombat = false end

    local casterScript = actor.type == types.Creature and SCRIPT_CREATURE or SCRIPT_NPC
    local alreadyManaged = actor:hasScript(casterScript)
    if inCombat and actor.type == types.Creature and not isEligibleCreatureBody(actor, alreadyManaged) then
        inCombat = false
    end
    -- Replace the previous handle's state, rather than leaving an older
    -- activation/target-change entry for the janitor to act on later.
    local state = { actor = actor, rawInCombat = rawInCombat, wanted = inCombat == true }
    combatActors[actor.id] = state

    if inCombat and isCasterEligible(actor, alreadyManaged) then
        -- Combat resumed: cancel any pending detach and tell already-attached
        -- scripts that they may cast again.
        pendingDetach[actor.id] = nil
        local attachedAny = actor:hasScript(SCRIPT_ITEMS) or alreadyManaged
        -- The item script snapshots creature eligibility at startup. Attach it
        -- before the caster script, whose onInit deliberately removes castable
        -- spells from the engine-facing list while OSSC owns spell selection.
        attachScript(actor, SCRIPT_ITEMS)
        attachScript(actor, casterScript)
        if attachedAny then actor:sendEvent('OSSC_CombatResumed') end
        return
    end

    -- Settings may have been changed while the actor was fighting; treat that
    -- exactly like leaving combat so temporary spell-list changes are undone.
    state.wanted = false

    local attached = nil
    if actor:hasScript(SCRIPT_ITEMS) then attached = { SCRIPT_ITEMS } end
    if alreadyManaged then
        if attached then
            attached[2] = casterScript
        else
            attached = { casterScript }
        end
    end
    if not attached then
        pendingDetach[actor.id] = nil
        return
    end
    requestDetach(actor, attached)
end

local function hasLiveCombatTarget(targets)
    if type(targets) ~= 'table' then return false end
    for _, target in ipairs(targets) do
        if target and target:isValid() and not types.Actor.isDead(target) then return true end
    end
    return false
end

-- NGarde's player script forwards its own combat-target-changed signal as the
-- global event ngarde_combatTargetChanged (it is derived from the same engine
-- event but uses NGarde's fencer/creature classification). When NGarde is
-- installed it is the authoritative combat tracker, so OSSC defers attachment
-- to that signal (see onNGardeCombatTargetChanged) and ignores its own copy of
-- the raw engine event to avoid double-handling / detach races.
local function isNgardePresent()
    return I.NGardeGlobal ~= nil
end

-- OpenMW's omw.music actor script sends this event to the player whenever an
-- actor's AI combat-target list changes. The player script forwards it to this
-- global script because object events are delivered to the receiving object,
-- while this script owns attachment/removal of actor scripts.
local function onCombatTargetsChanged(data)
    if not data or not data.actor then return end
    -- NGarde drives combat detection when present; only react to the raw
    -- engine event here as a fallback so the two signals never race.
    if isNgardePresent() then return end
    setCombatScripts(data.actor, hasLiveCombatTarget(data.targets))
end

-- When NGarde is installed, use its ngarde_combatTargetChanged global event
-- (carrying the same actor/targets fields, plus the fencer flag) as the
-- authoritative trigger to attach/detach OSSC's actor scripts.
local function onNGardeCombatTargetChanged(data)
    if not data or not data.actor then return end
    setCombatScripts(data.actor, hasLiveCombatTarget(data.targets))
end

-- A cell activation must never attach OSSC speculatively. The next
-- OMWMusicCombatTargetsChanged event is authoritative and will attach it if
-- the actor is actually fighting someone. This handler also cleans up scripts
-- left behind by an older OSSC version or a save made during combat. It is
-- safe to detach aggressively here: a freshly activated actor's scripts were
-- just re-loaded, so their unsavable cast timers no longer exist.
local function onActorActive(actor)
    setCombatScripts(actor, false)
end

-- Janitor: force-detach requests that never acked, and drop bookkeeping for
-- actors that left the world so pendingDetach/combatActors cannot grow
-- without bound.
local function runJanitor()
    local now = core.getSimulationTime()
    for id, entry in pairs(pendingDetach) do
        local actor = entry.actor
        if not actor:isValid() then
            pendingDetach[id] = nil
        elseif now >= entry.deadline then
            pendingDetach[id] = nil
            local state = combatActors[id]
            if not (state and state.wanted) then detachScriptsNow(actor, entry.scripts) end
        end
    end
    for id, journal in pairs(actorPauseRequests) do
        local actor = journal.actor
        if not (actor and actor.isValid and actor:isValid()) then
            actorPauseRequests[id] = nil
        end
    end
    for id, state in pairs(combatActors) do
        local actor = state.actor
        if not actor:isValid() then
            combatActors[id] = nil
        elseif state.wanted and types.Actor.isDead(actor) then
            -- Death ends combat: run the normal safe-detach protocol so the
            -- dead actor's scripts ack (dead actors can never cast again)
            -- and are removed instead of running for the rest of the session.
            setCombatScripts(actor, false)
        end
    end
    -- Toggle-flip safety net: the attach/detach path above only runs on
    -- combat events, so flipping a menu toggle mid-combat (NPC master,
    -- creature master, non-biped) would otherwise leave stale scripts attached
    -- (or miss a re-attach) until the next event. Re-drive any actor whose
    -- attachment state disagrees with its current eligibility. Actors with a
    -- detach already in flight are skipped — their ack/timeout path owns them
    -- — and the steady state is a silent no-op, so this never spams events.
    for id, state in pairs(combatActors) do
        local actor = state.actor
        if not actor:isValid() or (actor.type ~= types.NPC and actor.type ~= types.Creature) then
            combatActors[id] = nil
        elseif pendingDetach[id] == nil and not types.Actor.isDead(actor) then
            local casterScript = actor.type == types.Creature and SCRIPT_CREATURE or SCRIPT_NPC
            local alreadyManaged = actor:hasScript(casterScript)
            local attached = alreadyManaged or actor:hasScript(SCRIPT_ITEMS)
            local shouldAttach = state.rawInCombat == true
                and isCasterEligible(actor, alreadyManaged)
                and (actor.type ~= types.Creature or isEligibleCreatureBody(actor, alreadyManaged))
            if shouldAttach ~= attached then
                setCombatScripts(actor, state.rawInCombat == true)
            end
        end
    end
end

local function onUpdate(dt)
    janitorElapsed = janitorElapsed + dt
    if janitorElapsed < JANITOR_INTERVAL then return end
    janitorElapsed = 0.0
    runJanitor()
end

-- ── Events ─────────────────────────────────────────────────────────────────
local function onSyncSettings(data)
    if not (data and data.group) then return end
    if not SYNCED_SETTING_GROUPS[data.group] then return end
    storage.globalSection(data.group):reset(data.values or NO_VALUES)
end

-- Fallback PMM multi-mark Recall teleport (when PMM's global script is absent).
local teleportOptions = { rotation = nil }

local function onPMMTeleport(data)
    if not (data and data[1] and data[2]) then return end
    local actor    = data[1]
    local location = data[2]
    if not actor:isValid() or not location.position then return end
    teleportOptions.rotation = location.rotation
    -- Empty cell name = default exterior.
    actor:teleport(location.cell or '', location.position, teleportOptions)
end

-- One successful quickcast consumes exactly one scroll stack item.
local function onConsumeScroll(data)
    if not (data and data.actor and data.item) then return end
    local inventory = types.Actor.inventory(data.actor)
    if not inventory then return end
    local item = inventory:find(data.item.recordId)
    if item then item:remove(1) end
end

-- [ENCHANT FORMULA] Same formula used by the player-side OSSC item handling.
local function getEffectiveCost(baseCost, actor)
    local skill = 0
    if actor.type == types.NPC or actor.type == types.Player then
        skill = types.NPC.stats.skills.enchant(actor).modified or 0
    end
    return math.max(1, math.floor(0.01 * (110 - skill) * baseCost))
end

-- Enchanted-item charge consumption (same Enchant formula as the player).
local function onConsumeCharge(data)
    if not (data and data.item and data.cost and data.actor) then
        print('[OSSC] ConsumeCharge: Missing data')
        return
    end
    if not data.item:isValid() or not data.actor:isValid() then return end
    local itemData = types.Item.itemData(data.item)
    if not itemData then return end
    local effectiveCost = getEffectiveCost(data.cost, data.actor)
    local oldCharge = itemData.enchantmentCharge or 0
    itemData.enchantmentCharge = math.max(0, oldCharge - effectiveCost)
    print(string.format('[OSSC] Consumed %d charge from %s (%d -> %d)',
        effectiveCost, tostring(data.item.recordId), oldCharge, itemData.enchantmentCharge))
end

return {
    -- Global pause route; local scripts use I.OSSC_Caster.
    interfaceName = 'OSSC_Casters',
    interface = OSSC_CastersInterface,
    engineHandlers = {
        onActorActive = onActorActive,
        onUpdate = onUpdate,
    },
    eventHandlers = {
        OSSC_CombatTargetsChanged = onCombatTargetsChanged,
        -- NGarde's combat-target-changed global event (see onNGardeCombatTargetChanged).
        ngarde_combatTargetChanged = onNGardeCombatTargetChanged,
        -- Player-settings mirror.
        OSSC_SyncSettings = onSyncSettings,
        -- Safe-detach ack.
        OSSC_ReadyToDetach = onReadyToDetach,
        OSSC_PMMTeleport = onPMMTeleport,
        OSSC_ConsumeScroll = onConsumeScroll,
        OSSC_ConsumeCharge = onConsumeCharge,
        -- ── I.OSSC_Casters events ──
        OSSC_RequestIgnoredSpells = function(data)
            local actor = data and data.actor
            if not (actor and actor.isValid and actor:isValid()) then return end
            actor:sendEvent('OSSC_SetIgnoredSpells', {
                version = ignoredSpellVersion,
                ids = ignoredSpellList(),
            })
        end,
        -- Forwarded from I.OSSC.setSpellIgnored.
        OSSC_SetSpellIgnored = function(data)
            if type(data) ~= 'table' then return end
            setSpellIgnored(data.spellId, data.ignored ~= false)
        end,
        -- Event form of castSpellAtTarget.
        OSSC_CastSpellAtTarget = function(data)
            castSpellAtTarget(data)
        end,
        -- A caster quick-cast is about to hit `actor`: make sure it can render
        -- Spell Framework Plus' hit VFX (see ensureHitVfxHandler).
        OSSC_EnsureHitVfx = function(data)
            ensureHitVfxHandler(data and data.actor)
        end,

        --- Spell Framework Plus broadcasts every magic hit. OSSC listens for the
        --- ones it asked for (userData.osscImpactVfx, see ossc_impact_vfx.lua)
        --- and draws their statics the way the PLAYER's own hit is drawn: handed
        --- to the struck actor's own AddVfx handler, which the global side
        --- attached before the launch. An impact with no actor to parent the
        --- static to is spawned in the world at the point the bolt hit, which is
        --- vanilla's `explodeSpell`.
        MagExp_OnMagicHit = function(info)
            if type(info) ~= 'table' or type(info.userData) ~= 'table' then return end
            local models = info.userData.osscImpactVfx
            if type(models) ~= 'table' then return end
            -- ── The two visuals, split the way the engine splits them ──
            --   * a hit ON AN ACTOR is `CastSpell::playEffects`, which attaches
            --     that effect's HIT static to the actor's animation;
            --   * an EXPLOSION is `explodeSpell`, which spawns each exploding
            --     effect's AREA static at the point the spell landed (SF+'s
            --     `detonateSpellAtPos`).
            --
            -- So an exploding cast is drawn here on a BODY (its hit static,
            -- next to the explosion blooming at the same point) and nowhere
            -- else: on the ground or on an object the explosion is the whole
            -- visual, and a second static there is the "area spell shows
            -- hitVfx instead of areaVfx" report.
            --
            -- A blast VICTIM is never drawn here: `isAoE` means the explosion
            -- reached this actor as collateral, and a victim's flash is
            -- ATTACHED ON THE VICTIM BY SF+ ITSELF -- `applySpellToActor` runs
            -- once per victim with `isAoe == true` and sends the `AddVfx` for
            -- every effect that reached it, exactly as `explodeSpell` ->
            -- `inflict(..., exploded=true)` -> `playEffects` does in the engine
            -- (a listener's `suppressImpactVfx` only ever covers the impact its
            -- own hit event reports, never the collateral). Drawing the models
            -- here as well would double every blast victim's flash, so the
            -- early return stays -- it is what keeps ONE drawer per body.
            if info.isAoE == true then return end
            local target = info.target
            -- Does this cast explode anywhere? The event's own radius answers
            -- it for a bolt (a launch carries the effect area it resolved); a
            -- Touch/Self event carries its primary effect's area as well, and
            -- the record is the fallback for a listener that filled neither.
            local castExplodes = (tonumber(info.area) or 0) > 0
            if not castExplodes and type(info.spellId) == 'string' then
                local enchantments = core.magic.enchantments
                    and core.magic.enchantments.records or nil
                local record = core.magic.spells.records[info.spellId]
                    or (enchantments and enchantments[info.spellId]) or nil
                castExplodes = record ~= nil and spellArea.explodes(record) == true
            end
            -- ── An actor is drawn the way the PLAYER is drawn ──
            -- The static goes to the struck actor's own AddVfx handler, which
            -- makes the same `anim.addVfx(self, model, options)` call SFP's
            -- player script makes — the placement every report has compared
            -- against ("it lands properly on the player") — so the flash is
            -- parented to the actor and moves with the body.
            --
            -- The one thing that must not be copied verbatim is the effect's
            -- HEIGHT. OpenMW's `Animation::addEffect` shifts a boneless effect
            -- by `height - 128` for everything except an NPC, so the Player's
            -- flash is moved down onto the body by the engine while an NPC's
            -- is left at the 128-unit reference height the statics are authored
            -- at — the "spawned way higher than the model" report. That
            -- correction is applied in the actor's handler
            -- (ossc_actor_hit_vfx.lua, ossc_body_anchor.attachedOffset), with
            -- the engine's own sign, so nothing here invents a height.
            --
            -- Only a hit the actor cannot interpret falls through to the
            -- world-space static below: a target whose handler could not be
            -- attached (see ensureHitVfxHandler), an actor that is no longer
            -- valid, and every impact that is not on an actor at all — the
            -- ground, a door, a crate — which vanilla also draws in the world
            -- (explodeSpell -> spawnEffect) at the point the bolt hit.
            local attached = false
            if target ~= nil and target.isValid and target:isValid() and target.enabled
                and (target.type == types.NPC or target.type == types.Creature)
                and hitVfxHandlerOf(target) ~= nil then
                for i = 1, #models do
                    local entry = models[i]
                    if type(entry) == 'table' and type(entry.model) == 'string'
                        and entry.model ~= '' then
                        target:sendEvent('AddVfx', {
                            model   = entry.model,
                            options = { mwMagicVfx = true },
                        })
                    end
                end
                attached = true
            end
            local pos = nil
            if not attached then
                -- No handler yet: attach one so the NEXT hit is drawn on the
                -- body, and draw THIS one where it landed — vanilla's
                -- `explodeSpell` placement, the only thing left to do when
                -- nothing on the actor can interpret the event yet (an
                -- attached script only starts a frame later).
                -- ...but NOT for an exploding cast that has no BODY to sit on:
                -- a terrain or object impact of an area spell is drawn by the
                -- explosion alone.
                local onBody = target ~= nil and target.isValid ~= nil
                    and target:isValid() == true
                    and (target.type == types.NPC or target.type == types.Creature
                         or target.type == types.Player)
                if onBody then
                    ensureHitVfxHandler(target)
                elseif castExplodes then
                    return
                end
                pos = impactVfx.positionFor(info.hitPos, target)
                if pos == nil then return end
                impactVfx.spawn(models, pos)
            end
            if debugModeEnabled() then
                print(string.format('[OSSC Global] Impact VFX: %d static(s) %s',
                    #models, attached and ('added on ' .. tostring(target.recordId))
                        or ('spawned at ' .. tostring(pos))))
            end
        end,
    },
}
