---@omw-context global
-- ============================================================
-- OSSC: Oblivion-Style Spell Casting
-- ossc_global.lua (GLOBAL script)
-- Handles authoritative item/charge consumption & actor script attachment.
-- ============================================================
local core    = require('openmw.core')
local types   = require('openmw.types')
local storage = require('openmw.storage')
local vfs     = require('openmw.vfs')
local I       = require('openmw.interfaces')
local util    = require('openmw.util')
local world   = require('openmw.world')

local SCRIPT_NPC      = 'scripts/ossc/ossc_npc.lua'
local SCRIPT_CREATURE = 'scripts/ossc/ossc_creature.lua'
local SCRIPT_ITEMS    = 'scripts/ossc/ossc_actor_items.lua'

-- Settings sync: OSSC's settings groups are PLAYER settings (registered from
-- the player script's settings page). Global scripts and local actor scripts
-- cannot read player storage — storage.playerSection is only available to
-- player/menu scripts — so reading the menu values here always returned the
-- hardcoded defaults (e.g. NPCQuickCastCreatures could never be turned off).
-- The player script therefore mirrors every relevant group into GLOBAL storage
-- (same section names) via the OSSC_SyncSettings event, on load and whenever a
-- setting changes. Actor scripts and this script then read the mirror through
-- globalSection(), which is visible everywhere. SettingsOSSC_Keys is included
-- so EnablePlayerSwirls / EnableHandSwirls / EnableCastGlow also gate NPC and
-- eligible-creature cast VFX (those scripts cannot read player storage).
local SYNCED_SETTING_GROUPS = {
    ['SettingsOSSC_General']     = true,
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

-- ── Spell classification ───────────────────────────────────────────────────
-- Shared with the actor scripts through scripts/ossc/ossc_caster_utils.lua.
-- That helper is newer than the rest of the mod, and a partial/older install
-- (or an OpenMW session whose file index was built before the file appeared,
-- e.g. after an in-game `reloadlua`) must not stop the GLOBAL script from
-- starting: `require` of a missing data file throws. Check the VFS first and
-- fall back to an equivalent built-in classifier with a warning.
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
    for _, knownSpell in pairs(knownSpells) do
        local spellId = knownSpell
        if type(knownSpell) ~= 'string' then spellId = knownSpell.id end
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

-- Built-in NPC-settings reader: the schema lives in ossc_caster_utils.lua, but
-- a partial/older install (or a pre-update file index, e.g. after an in-game
-- `reloadlua`) may lack it — the defaults below mirror ossc_settings.lua so
-- I.OSSC_Casters.getNPCSettings keeps answering even then.
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
    NPCQuickCastCooldownMin       = 3.5,
    NPCQuickCastCooldownMax       = 8.5,
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

-- A caster script deliberately removes regular castable spells from the
-- engine-facing spell list while it is active. Spell presence is therefore
-- only an eligibility check when a combat event asks us to attach a script;
-- it is never used to discover combatants.
local function isCasterEligible(actor, alreadyManaged)
    if actor.type == types.Player or types.Actor.isDead(actor) then return false end
    if not settingOr(npcSettings, 'NPCQuickCastEnabled', true) then return false end

    if actor.type == types.Creature then
        if not settingOr(npcSettings, 'NPCQuickCastCreatures', true) then return false end
        -- Non-biped creatures have their own toggle so quick-casting can be
        -- restricted to biped creatures without disabling biped casters.
        if not settingOr(npcSettings, 'NPCQuickCastNonBipedCreatures', true) and not isBipedCreature(actor) then
            return false
        end
    elseif actor.type ~= types.NPC then
        return false
    end

    -- Once attached, the caster script intentionally hides regular spells
    -- from Actor.spells so vanilla AI cannot cast them in parallel. Keep that
    -- already-verified actor eligible across later combat-target-change events
    -- instead of mistaking OSSC's own temporary removal for "has no spells".
    if alreadyManaged then return true end

    local allowPowers = settingOr(npcSettings, 'NPCQuickCastAllowPowers', false)
    if casterUtils.hasCastableSpell(actor, allowPowers) then return true end
    return hasCastOnUseItem(actor)
end

-- Biped creatures remain eligible as before. For a non-biped creature,
-- inspect its live Actor spell list instead of guessing from its model: at
-- least one regular Spell (or a Power when that setting is enabled) makes it
-- eligible, and only while the dedicated non-biped toggle
-- (NPCQuickCastNonBipedCreatures) is enabled. Abilities, diseases and other
-- passive spell-list entries do not. This automatically covers mod-added
-- spellcasters too. An already-managed actor remains provisionally eligible
-- because its caster script hides those spells while attached
-- (isCasterEligible still applies the enabled/dead/type settings before
-- accepting it).
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

-- ── Caster pause route ─────────────────────────────────────────────────────
-- A pause is owned by the actor's own local script (I.OSSC_Caster in
-- ossc_npc.lua / ossc_creature.lua): it is the only scope that can stop the
-- cast, hand the engine's spell list back and keep the animation state honest.
-- A global script cannot reach a local interface, so this is the request route
-- plus a best-effort mirror of what was requested through it.
--
-- The request also attaches the caster script to an actor that does not have
-- it.  That is deliberate and it is not "guessing combat": a mod asking for a
-- pause is an explicit request, and a pause that only worked while the actor
-- was already fighting would be useless for scripted scenes.  The janitor only
-- manages actors it saw combat events for, so an on-demand attach is not
-- detached behind the caller's back - but leaving and re-entering a cell
-- (onActorActive) still resets it, like every other OSSC attach.
-- Keyed by actor id, not by the object: two Lua references to the same actor
-- are two different table keys, and a pause asked through one of them has to be
-- visible through the other.
local actorPauseRequests = {}   -- [actor.id] = { actor = actor, reasons = { [reason] = true } }

local function casterScriptFor(actor)
    if not (actor and actor.isValid and actor:isValid()) then return nil end
    if actor.type == types.Creature then return SCRIPT_CREATURE end
    if actor.type == types.NPC then return SCRIPT_NPC end
    return nil
end

--- Forward one pause/unpause request to the actor's own caster script.  The
--- actor keeps the authoritative state; this only remembers what was requested
--- through this route.  Returns false when OSSC does not manage the actor.
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
    if type(stored) ~= 'table' then return end
    for _, spellId in ipairs(stored) do
        local key = normalizeSpellKey(spellId)
        if key then ignoredSpells[key] = true end
    end
    ignoredSpellIds = ignoredSpellList()
end

-- Defined after combatActors (the broadcast walks the managed actors), so the
-- variable is declared here and assigned below; every closure below captures
-- this one slot and sees the assignment by the time it can be called.
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

-- ── On-demand casts ───────────────────────────────────────────────────────
-- `castSpellAtTarget` takes the caster as an argument, so a mod can order a
-- cast for any actor it can see - the player included:
--
--   I.OSSC_Casters.castSpellAtTarget({
--       caster    = actor,            -- required, an actor (NPC/creature/player)
--       spellId   = 'my_spell',       -- required, a spell record id
--       target    = otherActor,       -- optional: actor, or a util.vector3
--       effectScale = 0.5,            -- optional: quick-cast penalty (default 1)
--       isFree    = true,             -- optional: the mod already paid the cost
--       userData  = { MyMod = true }, -- optional: forwarded to MagExp
--   })
--
-- Only the request is made here; the cast itself runs through Spell Framework
-- Plus (MagExp_CastRequest), exactly like OSSC's own quick-casts, so every
-- downstream effect-penalty mechanic applies.  The player's own OSSC script is
-- preferred when it is installed: it knows the player's quick-cast penalty
-- settings and the stance/aim details, so the cast matches a hotkey cast.
local function isTargetObject(value)
    local kind = type(value)
    if kind ~= 'userdata' and kind ~= 'table' then return false end
    return value.position ~= nil and value.isValid ~= nil
end

local function resolveAimPoint(target)
    if target == nil then return nil, nil end
    if isTargetObject(target) then
        if not (target.isValid and target:isValid()) then return nil, nil end
        return target.position + util.vector3(0, 0, 60), target
    end
    if target.x ~= nil and target.y ~= nil and target.z ~= nil then
        return target, nil
    end
    return nil, nil
end

--- The copy of a request the global script sends itself, for an actor that has
--- no OSSC script of its own.  `isFree = false` unless the caller says
--- otherwise: Spell Framework Plus then charges the caster at launch, which is
--- the only place an item charge can be spent anyway.
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
    local range = record.effects and record.effects[1] and record.effects[1].range
    local area = args.area
    if area == nil then
        area = record.effects and record.effects[1] and record.effects[1].area or 0
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
    if types.Player.objectIsInstance(caster) and I.OSSC
        and type(I.OSSC.castSpellAtTarget) == 'function' then
        return I.OSSC.castSpellAtTarget(args)
    end
    return sendCastRequest(caster, record, args)
end

local OSSC_CastersInterface = {
    version = 1,
    --- Pause/unpause a managed NPC/creature caster.  `reason` lets two mods
    --- pause independently: unpausing one reason does not resume the actor for
    --- the other.  `unpause(actor)` with no reason releases every pause.
    pause     = function(actor, reason) return setActorPaused(actor, true, reason) end,
    unpause   = function(actor, reason) return setActorPaused(actor, false, reason) end,
    setPaused = function(actor, paused, reason)
        return setActorPaused(actor, paused == true, reason)
    end,
    --- True when this route currently holds a pause for the actor.  The
    --- authoritative state lives in the actor's own script (I.OSSC_Caster);
    --- this is the request mirror a global script can see.
    isPaused = function(actor) return actor ~= nil and actorPauseRequests[actor.id] ~= nil end,
    --- The caster script an actor would use, so a mod can tell whether OSSC
    --- manages it at all (and check hasScript before relying on the interface).
    casterScript = casterScriptFor,

    -- ── Spell filter (see the block above) ─────────────────────────────────
    -- A spell in this list is never *picked* by OSSC; an explicit hotkey cast
    -- or I.OSSC_Casters.castSpellAtTarget still works.  Ids are stored
    -- lowercased and survive a save/load.
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
        return settingOr(npcSettings, 'NPCQuickCastMinDistance', 500)
    end,

    --- Every NPC/creature quick-cast setting (the SettingsOSSC_NPC group) as
    --- a live snapshot table: each registered key maps to its current value,
    --- falling back to the registered default while unset (e.g. before the
    --- settings mirror's first sync).  The keys are NPCQuickCastEnabled,
    --- NPCQuickCastCreatures, NPCQuickCastNonBipedCreatures,
    --- NPCQuickCastDebugLog, NPCQuickCastAllowPowers, NPCQuickCastRandomAnims,
    --- NPCQuickCastPollInterval, NPCQuickCastBaseChance,
    --- NPCQuickCastMinDistance, NPCQuickCastMaxDistance,
    --- NPCQuickCastHealThreshold, NPCQuickCastCooldownMin and
    --- NPCQuickCastCooldownMax.  The result is a fresh copy — safe to keep or
    --- mutate.  getQuickCastFullChanceDistance() above is the convenience
    --- read-out of NPCQuickCastMinDistance.
    getNPCSettings = function()
        return readNPCSettings(npcSettings)
    end,
}

-- OSSC must only exist on actors currently reported by OpenMW's combat-music
-- tracker. Do not infer combat from spell lists: that both attaches scripts to
-- idle actors and fails when an actor has no castable spell.
local combatActors = {}

--- Hand the current spell filter to everything that picks spells: every actor
--- OSSC manages, and the player (whose script keeps a mirror so I.OSSC can
--- answer isSpellIgnored without a round trip).  A script that is not attached
--- simply has no handler, which is why this is broadcast rather than acked.
broadcastIgnoredSpells = function()
    local payload = { version = ignoredSpellVersion, ids = ignoredSpellList() }
    for actor in pairs(combatActors) do
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
-- Raw last combat signal per actor (true = a combat event reported a live
-- target), preserved even when the eligibility gates below reject the actor.
-- combatActors doubles as "attachment wanted" state and is forced false on the
-- detach path, so it cannot answer "is this actor still fighting?" — the
-- janitor needs the raw signal to re-drive attach/detach when a menu toggle
-- flips mid-combat (see runJanitor). Only combat events, cell activation
-- (no combat info — clears it) and death (ends combat — clears it) write it.
local rawCombatActors = {}

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
    pendingDetach[actor] = {
        scripts = paths,
        acked = {},
        deadline = core.getSimulationTime() + DETACH_TIMEOUT,
    }
end

local function onReadyToDetach(data)
    local actor = data and data.actor
    if not actor or not actor:isValid() then return end
    local entry = pendingDetach[actor]
    if not entry then return end
    if data.script then entry.acked[tostring(data.script)] = true end
    for _, path in ipairs(entry.scripts) do
        if not entry.acked[path] then return end                -- still waiting
    end
    pendingDetach[actor] = nil
    if combatActors[actor] == true then return end
    detachScriptsNow(actor, entry.scripts)
end

local function setCombatScripts(actor, inCombat)
    if not actor or not actor:isValid() or actor.type == types.Player then return end

    -- Capture the raw combat signal before any gating below: the janitor
    -- compares it against live eligibility, so eligibility rejects (dead,
    -- creature body) must never erase it.
    local rawInCombat = inCombat == true

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
    -- NOTE: only the raw event truth feeds rawCombatActors here. The detach
    -- path below forces combatActors[actor] = false for eligibility rejects
    -- too, but must NOT clear the raw signal: the actor is still fighting, and
    -- the janitor re-attaches it if the toggle is flipped back on.
    rawCombatActors[actor] = rawInCombat
    combatActors[actor] = inCombat == true

    if inCombat and isCasterEligible(actor, alreadyManaged) then
        -- Combat resumed: cancel any pending detach and tell already-attached
        -- scripts that they may cast again.
        pendingDetach[actor] = nil
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
    combatActors[actor] = false

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
        pendingDetach[actor] = nil
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
    for actor, entry in pairs(pendingDetach) do
        if not actor:isValid() then
            pendingDetach[actor] = nil
        elseif now >= entry.deadline then
            pendingDetach[actor] = nil
            if combatActors[actor] ~= true then detachScriptsNow(actor, entry.scripts) end
        end
    end
    for id, journal in pairs(actorPauseRequests) do
        local actor = journal.actor
        if not (actor and actor.isValid and actor:isValid()) then
            actorPauseRequests[id] = nil
        end
    end
    for actor, inCombat in pairs(combatActors) do
        if not actor:isValid() then
            combatActors[actor] = nil
        elseif inCombat and types.Actor.isDead(actor) then
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
    for actor, rawInCombat in pairs(rawCombatActors) do
        if not actor:isValid() then
            rawCombatActors[actor] = nil
        elseif actor.type ~= types.NPC and actor.type ~= types.Creature then
            rawCombatActors[actor] = nil
        elseif pendingDetach[actor] == nil and not types.Actor.isDead(actor) then
            local casterScript = actor.type == types.Creature and SCRIPT_CREATURE or SCRIPT_NPC
            local alreadyManaged = actor:hasScript(casterScript)
            local attached = alreadyManaged or actor:hasScript(SCRIPT_ITEMS)
            local shouldAttach = rawInCombat == true
                and isCasterEligible(actor, alreadyManaged)
                and (actor.type ~= types.Creature or isEligibleCreatureBody(actor, alreadyManaged))
            if shouldAttach ~= attached then
                setCombatScripts(actor, rawInCombat == true)
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

-- Fallback teleport handler for PMM multi-mark Recall. PMM's own global
-- script handles 'PMM_loadLoc'; this duplicate handler ensures the recall
-- works even when PMM's global script is absent or disabled.
local teleportOptions = { rotation = nil }

local function onPMMTeleport(data)
    if not (data and data[1] and data[2]) then return end
    local actor    = data[1]
    local location = data[2]
    if not actor:isValid() or not location.position then return end
    teleportOptions.rotation = location.rotation
    -- An empty cell name selects the default exterior worldspace; the
    -- position picks the grid cell.
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

-- One successful enchanted-item quickcast consumes charges using the same
-- Enchant-skill formula as OSSC's player implementation.
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
    -- Global route to the caster pause: a global script cannot see the actor's
    -- local interface, so it pauses with `I.OSSC_Casters.pause(actor, reason)`.
    -- Local scripts on the actor use I.OSSC_Caster instead (see ossc_npc.lua).
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
        -- Player-settings mirror (sent by ossc_settings.lua on load and on
        -- every settings change). Makes the NPC/creature menu options actually
        -- reach the global and actor scripts.
        OSSC_SyncSettings = onSyncSettings,
        -- Actor script reports that all of its cast timers have drained and it
        -- is safe to remove it (see the safe-detach protocol above).
        OSSC_ReadyToDetach = onReadyToDetach,
        -- A mod may also send the pause straight to the actor:
        --   actor:sendEvent('OSSC_SetCasterPaused', { paused = true, reason = 'my-mod' })
        -- It reaches the same handler the global route uses.
        OSSC_PMMTeleport = onPMMTeleport,
        OSSC_ConsumeScroll = onConsumeScroll,
        OSSC_ConsumeCharge = onConsumeCharge,
        -- ── I.OSSC_Casters: spell filter + on-demand casts ─────────────────
        -- A caster script asks for the current spell filter when it attaches
        -- (or after a load); the answer goes only to the asking actor.
        OSSC_RequestIgnoredSpells = function(data)
            local actor = data and data.actor
            if not (actor and actor.isValid and actor:isValid()) then return end
            actor:sendEvent('OSSC_SetIgnoredSpells', {
                version = ignoredSpellVersion,
                ids = ignoredSpellList(),
            })
        end,
        -- The player script forwards I.OSSC.setSpellIgnored here (the list is
        -- owned by this script, so one mod's veto is visible to every caster).
        OSSC_SetSpellIgnored = function(data)
            if type(data) ~= 'table' then return end
            setSpellIgnored(data.spellId, data.ignored ~= false)
        end,
        -- Mods without access to the global interface can use the event form:
        --   core.sendGlobalEvent('OSSC_CastSpellAtTarget', { caster=..., spellId=..., target=... })
        OSSC_CastSpellAtTarget = function(data)
            castSpellAtTarget(data)
        end,
    },
}
