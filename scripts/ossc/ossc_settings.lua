---@omw-context player
-- ============================================================================
-- OSSC settings registration (PLAYER script)
-- Registers input action and settings pages, then mirrors groups to global storage.
-- ============================================================================
local I       = require('openmw.interfaces')
local input   = require('openmw.input')
local storage = require('openmw.storage')
local core    = require('openmw.core')
local async   = require('openmw.async')

local function debugLog(msg)
    local section = storage.playerSection('SettingsOSSC_General')
    if not section or not section:get('DebugMode') then return end
    print("[OSSC Settings] " .. tostring(msg))
end

debugLog("--- OSSC SETTINGS INITIALIZATION START ---")

input.registerAction {
    key          = 'OSSC_QuickCast',
    type         = input.ACTION_TYPE.Boolean,
    l10n         = 'OSSC',
    defaultValue = false,
}

-- ============================================================================
-- Settings mirror
-- Player storage is player/menu-only; copy groups to global storage via OSSC_SyncSettings on load and change.
-- ============================================================================
local MIRRORED_GROUPS = {
    'SettingsOSSC_General',
    -- The decision settings (NPCAI*, once their own group) live in
    -- SettingsOSSC_NPC now and are mirrored with it; the old group is only
    -- still touched below to erase its retired keys.
    'SettingsOSSC_NPC',
    'SettingsOSSC_Animations',
    'SettingsOSSC_AnimSpeeds',
    'SettingsOSSC_Keys',
}

local syncEvent = { group = nil, values = nil }

local function syncGroup(group)
    local section = storage.playerSection(group)
    if not section then return end
    syncEvent.group = group
    syncEvent.values = section:asTable()
    core.sendGlobalEvent('OSSC_SyncSettings', syncEvent)
end

local function syncAllGroups()
    for _, group in ipairs(MIRRORED_GROUPS) do
        syncGroup(group)
    end
end

-- Callback receives the section name.
local onMirroredGroupChanged = async:callback(syncGroup)

for _, group in ipairs(MIRRORED_GROUPS) do
    local section = storage.playerSection(group)
    if section then section:subscribe(onMirroredGroupChanged) end
end

local script = {
    engineHandlers = {
        onInit = syncAllGroups,
        onLoad = syncAllGroups,
    },
}

if not I.Settings or not I.Settings.registerPage then
    print("--- OSSC SETTINGS INITIALIZATION FINISHED (no settings interface) ---")
    return script
end

I.Settings.registerPage({
    key         = 'OSSCPage',
    l10n        = 'OSSC',
    name        = 'Oblivion-Style Spell Casting v4.4',
    description = 'Settings for the OSSC Mod\n\nSpecial thanks to Dubiousnpc for his fantastic work on OSSC animations and also all the people that helped in the development by reporting bugs or sending fixes!'
})

-- ── Group 1: General ──────────────────────────────────────────────────

-- The number renderer reads its bounds from `argument`, not from the setting
-- table. Normalize legacy top-level min/max values before every registration.
local function registerGroup(group)
    for _, setting in ipairs(group.settings or {}) do
        if setting.renderer == 'number' and (setting.min ~= nil or setting.max ~= nil) then
            setting.argument = setting.argument or {}
            if setting.argument.min == nil then setting.argument.min = setting.min end
            if setting.argument.max == nil then setting.argument.max = setting.max end
        end
    end
    I.Settings.registerGroup(group)
end

registerGroup({
    key              = 'SettingsOSSC_Keys',
    page             = 'OSSCPage',
    l10n             = 'OSSC',
    name             = 'General',
    permanentStorage = true,
    order            = 1,
    settings         = {
        {
            key         = 'QuickCastBinding',
            renderer    = 'inputBinding',
            default     = 'OSSC_QuickCast_default',
            name        = 'Quick Cast (Keyboard / Gamepad Buttons)',
            description = 'Bind a keyboard key or gamepad button here.\n\nTo CLEAR the binding: click it and press Escape.\n\nNote: L2/R2 triggers cannot be bound here — use the trigger options below instead.',
            argument    = { type = 'action', key = 'OSSC_QuickCast' },
        },
        {
            key         = 'QuickCastTrigger',
            name        = 'Quick Cast - Gamepad Trigger (Left/Right)',
            renderer    = 'select',
            default     = 'Disabled',
            argument    = {
                disabled = false,
                l10n     = 'OSSC',
                items    = { 'Disabled', 'L2/LT', 'R2/RT' },
            },
        },
        {
            key         = 'QuickCastTriggerThreshold',
            name        = 'Trigger Activation Threshold (L2/R2 setting only)',
            description = 'How far to pull the trigger to count as a press (0.1 = very light, 1.0 = full pull).',
            renderer    = 'number',
            default     = 0.60,
            min         = 0.10,
            max         = 1.00,
        },
        {
            key         = 'EnablePlayerSwirls',
            name        = 'Enable Actors VFX/Particles',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'EnableHandSwirls',
            name        = 'Enable Hand VFX (element ball)',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'EnableCastGlow',
            name        = 'Enable Cast VFX around hand (for modders)',
            renderer    = 'checkbox',
            default     = false
        },
    }
})

-- ── Group 2: Gameplay ─────────────────────────────────────────────────
local generalStorage     = storage.playerSection('SettingsOSSC_General')

-- Penalty values live in ossc_penalty.lua.
local Penalty = require('scripts.ossc.ossc_penalty')
local penaltySelectItems = Penalty.items

-- Skill modes live in ossc_skillmodes.lua.
local SkillModes = require('scripts.ossc.ossc_skillmodes')
local skillModeSelectItems = SkillModes.items

-- Legacy penalty values -> select values.
local PENALTY_ALIASES = {
    disabled = 'off', ossc_penalty_off = 'off',
    ['reduce 25%'] = 'reduce_25', ['25%'] = 'reduce_25', ['-25%'] = 'reduce_25', ossc_penalty_25 = 'reduce_25',
    ['reduce 50%'] = 'reduce_50', ['50%'] = 'reduce_50', ['-50%'] = 'reduce_50', ossc_penalty_50 = 'reduce_50',
}
local PENALTY_BY_NUMBER = { [0] = 'off', [1] = 'reduce_25', [2] = 'reduce_50' }

local function migratePenaltyKey(key)
    local v = generalStorage:get(key)
    if v == nil then return end
    if Penalty.valid[tostring(v)] then return end
    local migrated
    if Penalty.isSkillBased(v) then
        migrated = Penalty.SKILL_BASED
    else
        migrated = PENALTY_BY_NUMBER[tonumber(v)]
            or PENALTY_ALIASES[tostring(v):lower()]
            or 'off'
    end
    generalStorage:set(key, migrated)
end
migratePenaltyKey('QuickCastChancePenalty')
migratePenaltyKey('QuickCastEffectPenalty')

-- Fold the legacy skill-based checkbox into the select once, then drop it (else it re-applies every load).
local function migrateSkillBasedCheckbox(selectKey, checkboxKey)
    local ticked = generalStorage:get(checkboxKey)
    if ticked == nil then return end
    if ticked == true then
        generalStorage:set(selectKey, Penalty.SKILL_BASED)
    end
    generalStorage:set(checkboxKey, nil)
end
migrateSkillBasedCheckbox('QuickCastChancePenalty', 'QuickCastChancePenaltySkillBased')
migrateSkillBasedCheckbox('QuickCastEffectPenalty', 'QuickCastEffectPenaltySkillBased')

-- Legacy shield penalty: 'reduced' = 50%, 'full' = 100%; checkbox folds in as above.
do
    local v = generalStorage:get('ShieldCastingPenalty')
    if v ~= nil and not Penalty.shield.valid[tostring(v)] then
        generalStorage:set('ShieldCastingPenalty', Penalty.shield.normalize(v))
    end
end
migrateSkillBasedCheckbox('ShieldCastingPenalty', 'ShieldCastingPenaltySkillBased')

-- Migrate QuickCastEffectPenaltyScrollsSpellsExempt to scrolls-only once.
do
    local OLD_KEY, NEW_KEY = 'QuickCastEffectPenaltyScrollsSpellsExempt', 'QuickCastEffectPenaltyScrollsExempt'
    local old = generalStorage:get(OLD_KEY)
    if old ~= nil then
        if generalStorage:get(NEW_KEY) == nil then
            generalStorage:set(NEW_KEY, old == true)
        end
        generalStorage:set(OLD_KEY, nil)
    end
end

-- Rewrite dropped 'ncg+se' modes to 'skillevo'.
do
    local v = generalStorage:get('SkillProgressionMode')
    if v ~= nil and not SkillModes.valid[tostring(v)] then
        generalStorage:set('SkillProgressionMode', SkillModes.normalize(v))
    end
end

-- Retired settings are erased before mirroring so legacy values cannot keep
-- travelling to actor scripts after their menu controls are gone. Target
-- selection stays fixed to engine combat targets only. The old AI preset only
-- wrote cadence keys that the NPC runtime never read; the M3 policy selectors
-- were also unread. Remove those stale values without changing current M2
-- behavior. Combo Chains is no longer a setting either: Strict Sequences is
-- the only behaviour, so the old key (which used to migrate TagChains to
-- StrictSequences) is erased outright.
do
    local aiStorage = storage.playerSection('SettingsOSSC_NPC_AI')
    for _, key in ipairs({
        'NPCAITargetChoice', 'NPCAITargetPriority', 'NPCAITargetOrder',
        'NPCAIHostileCandidates', 'NPCAIScanInterval',
        'NPCAIPreset', 'NPCAIDecisionMode', 'NPCAITargetKnowledge',
        'NPCAIMatchupAwareness', 'NPCAISnapshotTTL',
        'NPCAIShortlistCap', 'NPCAIAllyRefresh',
        -- Replaced by NPCAIWeaknessMinMagnitude; seconds are not percentages.
        'NPCAIWeaknessMinDuration',
    }) do
        if aiStorage:get(key) ~= nil then aiStorage:set(key, nil) end
    end
    if aiStorage:get('NPCAICombos') ~= nil then
        aiStorage:set('NPCAICombos', nil)
    end
    -- Timings that became constants, and the decision setting that was merged
    -- into NPCQuickCastHealThreshold: their controls are gone, so erase the
    -- stored values — a stale value must not survive a load and resurface.
    local npcSection = storage.playerSection('SettingsOSSC_NPC')
    for _, key in ipairs({
        'NPCMercyQuickcastWindow', 'NPCQuickCastEquipReadiness',
        'NPCVanillaCastUnequipTimeout', 'NPCVanillaCastAllowanceReadiness',
        'NPCPauseResumeGrace',
    }) do
        if npcSection and npcSection:get(key) ~= nil then
            npcSection:set(key, nil)
        end
    end
    if aiStorage:get('NPCAIHealCriticalFloor') ~= nil then
        aiStorage:set('NPCAIHealCriticalFloor', nil)
    end
    if npcSection and npcSection:get('NPCAIHealCriticalFloor') ~= nil then
        npcSection:set('NPCAIHealCriticalFloor', nil)
    end
    if generalStorage:get('QuickCastTargetLeading') ~= nil then
        generalStorage:set('QuickCastTargetLeading', nil)
    end
    local npcStorage = storage.playerSection('SettingsOSSC_NPC')
    if npcStorage:get('NPCMercyCAOMode') ~= nil then
        npcStorage:set('NPCMercyCAOMode', nil)
    end
end

registerGroup({
    key              = 'SettingsOSSC_General',
    page             = 'OSSCPage',
    l10n             = 'OSSC',
    name             = 'Gameplay',
    permanentStorage = true,
    order            = 2,
    settings         = {
        {
            key         = 'DebugMode',
            name        = 'Toggle Debug Mode. Affects performance.',
            renderer    = 'checkbox',
            default     = false
        },
        {
            key         = 'UseFatigue',
            name        = 'Use Fatigue when casting (MCP Formula)',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'UseFatigueScale',
            name        = 'Fatigue Usage Scale Multiplier (if enabled)',
            renderer    = 'number',
            default     = 5.0,
            min         = 0.0,
            max         = 50.0,
        },

        {
            key         = 'QuickCastChancePenalty',
            name        = 'Quick Cast Chance Penalty (Off / Flat % / Skill Based)',
            description = 'Skill based is linear scale - 0 skill: 50% penalty <-> 100+ skill: no penalty',
            default     = 'off',
            renderer    = 'select',
            argument    = {
                disabled = false,
                l10n     = 'OSSC',
                items    = penaltySelectItems,
            },
        },
        {
            key         = 'QuickCastEffectPenalty',
            name        = 'Quick Cast Effect Penalty (Off / Flat % / Skill Based)',
            description = 'Skill based is linear scale - 0 skill: 50% penalty <-> 100+ skill: no penalty',
            default     = 'off',
            renderer    = 'select',
            argument    = {
                disabled = false,
                l10n     = 'OSSC',
                items    = penaltySelectItems,
            },
        },
        {
            key         = 'QuickCastEffectPenaltyScrollsExempt',
            name        = 'Quick Cast Effect Penalty — Exclude Scrolls',
            description = 'Exclude scrolls from the effect penalty if it is enabled. Powers are always excluded.',
            renderer    = 'checkbox',
            default     = true,
        },
        {
            key         = 'AllowPowerCasting',
            name        = 'Allow Quick-Casting Powers (separate cooldown) For Gamepads',
            description = 'Enables Powers casting with OSSC. Hacky solution until we get access to Powers API.',
            renderer    = 'checkbox',
            default     = true,
        },
        {
            key         = 'EnableSpeedyMagick',
            name        = 'Enable SpeedyMagick Animation Speed Scaling/Compatibility',
            renderer    = 'checkbox',
            default     = false
        },
        {
            key         = 'CastOnQuickkeys',
            name        = 'Enable Quick Cast Spells from Hotkeys (1-9)',
            description = 'USE ONLY WITH ENABLED\n[Enable Block / Suppress Spell Stance]',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'AllowQuickCastInSpellStance',
            name        = 'Allow Quick-Cast In Spell Stance',
            description = 'Quickcasts are blocked in spell stance for every actor. if disabled.',
            renderer    = 'checkbox',
            default     = false,
        },
        {
            key         = 'SuppressSpellStance',
            name        = 'Enable Block / Suppress Spell Stance',
            description = 'Prevents entering vanilla spell stance when spell quick-keys are pressed.',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'ShieldCastingPenalty',
            name        = 'Penalty for quickcasting with a shield (Off / % / Skill+Strength Based)',
            description = 'A cast is never slowed below 0.55x.',
            default     = 'off',
            renderer    = 'select',
            argument    = {
                disabled = false,
                l10n     = 'OSSC',
                items    = Penalty.shield.items,
            },
        },
        {
            key         = 'BlockDuringAttack',
            name        = 'Enable Block Quick Cast During Attack (Spellstrike Compatibility)',
            description = 'Allows sharing keybinds with Spellstrike. Prevents OSSC Quick Cast from triggering while actively raising a weapon or attacking.',
            renderer    = 'checkbox',
            default     = false
        },
        {
            key         = 'BlockDuringCombatAnims',
            name        = 'Block Quick Cast During Attack Animations (2 Handed)',
            description = 'Prevents quick-casting when both hands are occupied. Applies to all eligible actors.',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'BlockWeaponDuringQuickcast',
            name        = 'Block 2H / Ranged Weapon Attacks While Quick-Casting',
            description = 'Applies to all eligible actors.',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'BlockShieldDuringQuickcast',
            name        = 'Disable Shield Blocking During Quick-Casting',
            description = 'Applies to all eligible actors.',
            renderer    = 'checkbox',
            default     = false
        },
        {
            key         = 'BlockDuringNGardeParry',
            name        = 'Block Quick Cast During NGarde Parry',
            description = 'Applies to all eligible actors.',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'BlockTargetSpellsWhileSwimming',
            name        = 'Block Target Spell Quick Casts While Swimming',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'CastVetoFeedback',
            name        = 'Sane Magic Mod sound setting',
            description = 'Choose if the failure from Sane Magic will be Vanilla-style or silent.',
            renderer    = 'select',
            argument    = { l10n = 'OSSC', items = { 'Vanilla', 'Silent' } },
            default     = 'Vanilla',
        },
        {
            key         = 'AllowAttackingWhileCasting',
            name        = 'Allow Attacking While Quick-Casting',
            description = 'Enables more dynamic combat.',
            renderer    = 'checkbox',
            default     = true
        },
        {
            key         = 'PureMultiMarkCompat',
            name        = 'Enable Pure LUA Multi Mark Mod Compatibility',
            renderer    = 'checkbox',
            default     = false
        },
        {
            key         = 'SkillProgressionMode',
            name        = 'Skill Progression Mode',
            description =
                'OSSC : Vanilla skill-use gains, class bonuses and skill-level requirements.\n\n' ..
                'NCG : Natural Character Growth. Engine handles progress; NCG reacts on level-up.\n' ..
                'SKILLEVO : Skill Evolution. SE intercepts skillUsed and runs its full handler chain. SE detects whether MBSP is enabled on its own, so this covers what the old NCG+SE choices did.\n\n' ..
                'SUS : Skill Uses Scaled. Patches SUS spell pointer before calling skillUsed.\n' ..
                'MBSP : Standalone MBSP mod. Intercepts skillUsed, applies cost-scaled XP formula.\n' ..
                'NONE : award no skill experience at all, leaving spellcasting progression entirely to another mod.\n' ..
                'The Skill Experience Ratio setting below is only active in ossc mode.',
            default     = 'ossc',
            renderer    = 'select',
            argument    = {
                disabled = false,
                l10n     = 'OSSC',
                items    = skillModeSelectItems,
            },
        },
            {
            key         = 'SkillExperience',
            name        = 'Skill Experience Ratio (OSSC mode only)',
            description = 'Multiplier for the loaded skill record gain: 1 = vanilla parity, 0 = no experience, 2 = double. Not a percentage of a skill level. Explicit awardSkillProgress gains are not multiplied.',
            renderer    = 'number',
            default     = 1.0,
            min         = 0,
            max         = 100
        },
        {
            key         = 'MagickaRefund',
            name        = 'MBSP Magicka Refund',
            description = '1:1 clone of the MBSP standalone "Refund" mode.',
            renderer    = 'checkbox',
            default     = false
        },
        {
            key         = 'MagickaRefundStart',
            name        = 'MBSP Magicka Refund - Skill Requirement',
            renderer    = 'number',
            default     = 35,
            min         = 1,
            max         = 200
        },
        {
            key         = 'MagickaRefundMult',
            name        = 'MBSP Magicka Refund - Magicka Cost Scaling (%)',
            description = 'How much a spell costs is multiplied by this percentage every [Level Scaling] levels.',
            renderer    = 'number',
            default     = 50,
            min         = 1,
            max         = 200
        },
        {
            key         = 'MagickaRefundLevelScaling',
            name        = 'MBSP Magicka Refund - Level Scaling',
            description = 'How many skill levels are required for the spell cost to be multiplied by the Magicka Cost Scaling setting. Default 100 (MBSP standalone default).',
            renderer    = 'number',
            default     = 100,
            min         = 1,
            max         = 500
        },
    }
})

-- ── Group 3: NPC & Creature Quick-Casting ─────────────────────────────
-- The decision settings (thresholds, reactions, combos, exclusions, ally
-- casting, debug logging) live here too — one page for everything an NPC or
-- creature does with a quick-cast. They keep their NPCAI* storage keys, so
-- existing saves and the settings mirror read back unchanged.
registerGroup({
    key              = 'SettingsOSSC_NPC',
    page             = 'OSSCPage',
    l10n             = 'OSSC',
    name             = 'NPC & Creature Quick-Casting',
    description      = 'Configure Oblivion-Style quick-casting for combat NPCs and eligible creatures. \nChanges apply live.',
    permanentStorage = true,
    order            = 3,
    settings         = {
        {
            key         = 'NPCQuickCastEnabled',
            name        = 'Enable NPC Quick-Casting',
            renderer    = 'checkbox',
            default     = true,
        },
        {
            key         = 'NPCQuickCastCreatures',
            name        = 'Enable Creature Quick-Casting',
            renderer    = 'checkbox',
            default     = true,
        },
        {
            key         = 'NPCQuickCastNonBipedCreatures',
            name        = 'Enable Non-Biped Creature Quick-Casting',
            renderer    = 'checkbox',
            default     = true,
        },
        {
            key         = 'NPCQuickCastDebugLog',
            name        = 'NPC Quick-Cast Debug Logging (affects performance)',
            renderer    = 'checkbox',
            default     = false,
        },
        {
            key         = 'NPCQuickCastAllowPowers',
            name        = 'Allow NPCs Quick-Casting Powers',
            renderer    = 'checkbox',
            default     = false,
        },
        {
            key         = 'NPCQuickCastRandomAnims',
            name        = 'Randomize NPC Cast Animation sets',
            renderer    = 'checkbox',
            default     = true,
        },
        {
            key         = 'NPCQuickCastPollInterval',
            name        = 'Combat Polling Interval (seconds)',
            description = 'How often the AI evaluates tactical quick-casting during combat.',
            renderer    = 'number',
            default     = 1.0,
            min         = 0.1,
            max         = 60.0,
        },
        {
            key         = 'NPCQuickCastBaseChance',
            name        = 'Base Quick-Cast Probability (%)',
            description = 'The maximum probability (at close/melee range) that an NPC will choose to quick-cast.',
            renderer    = 'number',
            default     = 100,
            min         = 0,
            max         = 100,
        },
        {
            key         = 'NPCQuickCastMinDistance',
            name        = 'Full Chance Distance (units)',
            description = 'Distance at or below which quick-casting probability reaches maximum. Touch spells are not tied to this: NPCs and creatures may only touch-cast within the same vanilla touch reach as the player.',
            renderer    = 'number',
            default     = 500,
            min         = 50,
            max         = 600,
        },
        {
            key         = 'NPCQuickCastMaxDistance',
            name        = 'Maximum Cast Distance (units)',
            description = 'Distance at or beyond which quick-casting probability is 0%.',
            renderer    = 'number',
            default     = 2200,
            min         = 300,
            max         = 3500,
        },
        {
            key         = 'NPCQuickCastHealThreshold',
            name        = 'Spells Healing Threshold (% of Health)',
            description = 'Actors health percentage below which healing spells are prioritized.',
            renderer    = 'number',
            default     = 40,
            min         = 10,
            max         = 80,
        },
        {
            key         = 'NPCQuickCastTouchChance',
            name        = 'In Touch Reach: Touch Spell Weight (0-100%)',
            description = 'Favor of Touch spells after the actor has cast all missing Self buffs, when the target is within vanilla touch reach.',
            renderer    = 'number',
            default     = 80,
            min         = 0,
            max         = 100,
        },
        {
            key         = 'NPCQuickCastTouchTargetChance',
            name        = 'In Touch Reach: Target Spell Weight (0-100%)',
            description = 'Favor of Target spells when the enemy is already within touch reach. 0 disables point-blank projectiles unless nothing else is available.',
            renderer    = 'number',
            default     = 20,
            min         = 0,
            max         = 100,
        },
        {
            key         = 'NPCQuickCastCooldownMin',
            name        = 'Minimum Quickcast Cooldown (seconds)',
            description = 'Minimum delay between quick-casts by the same NPC.',
            renderer    = 'number',
            default     = 2.2,
            min         = 1.0,
            max         = 60.0,
        },
        {
            key         = 'NPCQuickCastCooldownMax',
            name        = 'Maximum Quickcast Cooldown (seconds)',
            description = 'Maximum delay between consecutive quick-casts by the same NPC. Does not apply to Self buffs — they are cast on a fixed 2.2-second rhythm.',
            renderer    = 'number',
            default     = 4,
            min         = 1.5,
            max         = 60.0,
        },
        {
            key         = 'NPCMercyVanillaCastWindow',
            name        = 'Mercy CAO: Vanilla Cast Window (seconds)',
            description = 'Only applies with Mercy CAO installed.',
            renderer    = 'number',
            default     = 5.0,
            min         = 0,
            max         = 30.0,
        },
        {
            key         = 'NPCMercyQuickcastWindowCooldown',
            name        = 'Mercy CAO: Quick-cast Window Cooldown (seconds)',
            description = 'Only applies with Mercy CAO installed.',
            renderer    = 'number',
            default     = 5.0,
            min         = 0.5,
            max         = 30.0,
        },
        {
            key         = 'NPCVanillaCastsAllowedMin',
            name        = 'Vanilla Casts Allowed After AI Takeover — Minimum',
            description = 'Only applies with Mercy CAO installed. Decide how much minimum casts Mercy in its cast window will be allowed to do by OSSC.',
            renderer    = 'number',
            default     = 1,
            min         = 0,
            max         = 10,
        },
        {
            key         = 'NPCVanillaCastsAllowedMax',
            name        = 'Vanilla Casts Allowed After AI Takeover — Maximum',
            description = 'Only applies with Mercy CAO installed. Decide how much maximum casts Mercy in its cast window will be allowed to do by OSSC.\nSet both numbers to same value and it will not randomise it.',
            renderer    = 'number',
            default     = 2,
            min         = 0,
            max         = 10,
        },
        {
            key         = 'NPCVanillaCastAllowanceTimeout',
            name        = 'Vanilla Cast Allowance Timeout (seconds)',
            description = 'Only applies with Mercy CAO installed. How long the Mercy window should be allowed without it casting a spell, after timeout OSSC takes over.',
            renderer    = 'number',
            default     = 5.0,
            min         = 0,
            max         = 60.0,
        },
        {
            key         = 'NPCProjectilesPassThroughBystanders',
            name        = 'Projectiles Pass Through Unintended Targets',
            description = 'On by default for vanilla parity.',
            renderer    = 'checkbox',
            default     = true,
        },
        {
            key         = 'NPCAIWeaknessMinMagnitude',
            name        = 'Minimum Weakness Magnitude (%)',
            description = 'Minimum Weakness Magnitude % for an actor to consider quickcasting it in a combo chain. 0 disables the check.',
            renderer    = 'number',
            default     = 15,
            argument    = { min = 0, max = 100, integer = true },
        },
        {
            key         = 'NPCAIBeneficialBuffMinDuration',
            name        = 'Minimum Beneficial Buff Duration (seconds)',
            description = 'Minimum Buff spell duration for an actor to consider quickcasting it. 0 disables the check.',
            renderer    = 'number',
            default     = 15,
            argument    = { min = 0, max = 600, integer = true },
        },
        {
            key         = 'NPCAIReactions',
            name        = 'Reactions',
            description = 'Low Health: below the heal threshold the actor casts a known escape spell (Invisibility or Chameleon) if it has one, ahead of its other spells and regardless of the quick-cast cooldown or hit chance. \nBroad: the same as low health, plus a known protective Self spell (Sanctuary, Shield, Reflect, Spell Absorption, invisibility or chameleon) whenever an incoming hit lands.\n Off disables both.',
            renderer    = 'select',
            argument    = { l10n = 'OSSC', items = { 'Off', 'LowHealth', 'Broad' } },
            default     = 'LowHealth',
        },
        {
            key         = 'NPCAIAllyCasting',
            name        = 'Ally Casting',
            description = 'UNTESTED. USE FAIR CARE MOD.',
            renderer    = 'select',
            argument    = { l10n = 'OSSC', items = { 'Off', 'Cheap', 'Moderate', 'Rich' } },
            default     = 'Off',
        },
        {
            key         = 'NPCAIBuffRecastCooldown',
            name        = 'Same Buff Recast Cooldown (seconds)',
            description = 'Minimum time before an NPC or creature can quick-cast the same buff spell again (prevents overcasting shorter buffs). 0 disables the lock.',
            renderer    = 'number',
            default     = 30,
            argument    = { min = 0, max = 600, integer = true },
        },
        {
            key         = 'NPCAIMagickaReserve',
            name        = 'Magicka Reserve (%)',
            description = 'Actors that know a heal or restore fatigue spell keep this share of max magicka as headroom (offensive spells stop below it). 0 disables.',
            renderer    = 'number',
            default     = 25,
            argument    = { min = 0, max = 90, integer = true },
        },
        {
            key         = 'NPCAIDeclinedSpells',
            name        = 'Declined Spells (comma-separated ids)',
            description = 'Additional Spell record ids actors must never quick-cast.',
            renderer    = 'textLine',
            default     = '',
        },
        {
            key         = 'NPCAIDecisionTrace',
            name        = 'NPC Spell Decision Debug Logging',
            renderer    = 'checkbox',
            default     = false,
        },
    }
})
-- ── Group 3: Cast Animations ──────────────────────────────────────────
local ANIM_GROUPS = {
    'quickcast', 'quickbuff',
    'qcconj',  'qctouch',
    'qcalt', 'qcill',
    'qcsnap',
    'qcdrain',
    'qcskrow',
}

local function animEntry(key, name, description, default)
    return {
        key      = key,
        name     = name,
        description = description,
        default  = default,
        renderer = 'select',
        argument = { disabled = false, l10n = 'OSSC', items = ANIM_GROUPS },
    }
end

registerGroup({
    key              = 'SettingsOSSC_Animations',
    page             = 'OSSCPage',
    l10n             = 'OSSC',
    name             = 'Cast Animations',
    description      = 'Choose which animation plays for each school, cast range and camera perspective.\nEnchanted items use the same school-based selection as regular spells.',
    permanentStorage = true,
    order            = 4,
    settings         = {
        {
            key         = 'SnapSoundVolume',
            name        = 'Snap Sound Volume',
            description = 'Volume of the snap sound played whenever the qcsnap animation is used (0.0 = silent, 1.0 = full).',
            renderer    = 'number',
            default     = 0.45,
            min         = 0.0,
            max         = 1.0,
        },

        animEntry('Anim_Alteration_Self_1st',    'Alteration – Self (1st person)',    'Animation for Alteration self-range spells in first person.',    'qcsnap'),
        animEntry('Anim_Alteration_Self_3rd',    'Alteration – Self (3rd person)',    'Animation for Alteration self-range spells in third person.',    'qcsnap'),
        animEntry('Anim_Alteration_Touch_1st',   'Alteration – Touch (1st person)',   'Animation for Alteration touch-range spells in first person.',   'qctouch'),
        animEntry('Anim_Alteration_Touch_3rd',   'Alteration – Touch (3rd person)',   'Animation for Alteration touch-range spells in third person.',   'qctouch'),
        animEntry('Anim_Alteration_Target_1st',  'Alteration – Target (1st person)',  'Animation for Alteration target-range spells in first person.',  'qcalt'),
        animEntry('Anim_Alteration_Target_3rd',  'Alteration – Target (3rd person)',  'Animation for Alteration target-range spells in third person.',  'qcalt'),

        animEntry('Anim_Conjuration_Self_1st',   'Conjuration – Self (1st person)',   'Animation for Conjuration self-range spells in first person.',   'quickbuff'),
        animEntry('Anim_Conjuration_Self_3rd',   'Conjuration – Self (3rd person)',   'Animation for Conjuration self-range spells in third person.',   'quickbuff'),
        animEntry('Anim_Conjuration_Touch_1st',  'Conjuration – Touch (1st person)',  'Animation for Conjuration touch-range spells in first person.',  'qctouch'),
        animEntry('Anim_Conjuration_Touch_3rd',  'Conjuration – Touch (3rd person)',  'Animation for Conjuration touch-range spells in third person.',  'qctouch'),
        animEntry('Anim_Conjuration_Target_1st', 'Conjuration – Target (1st person)', 'Animation for Conjuration target-range spells in first person.', 'quickcast'),
        animEntry('Anim_Conjuration_Target_3rd', 'Conjuration – Target (3rd person)', 'Animation for Conjuration target-range spells in third person.', 'quickcast'),

        animEntry('Anim_Destruction_Self_1st',   'Destruction – Self (1st person)',   'Animation for Destruction self-range spells in first person.',   'quickbuff'),
        animEntry('Anim_Destruction_Self_3rd',   'Destruction – Self (3rd person)',   'Animation for Destruction self-range spells in third person.',   'quickbuff'),
        animEntry('Anim_Destruction_Touch_1st',  'Destruction – Touch (1st person)',  'Animation for Destruction touch-range spells in first person.',  'qcdrain'),
        animEntry('Anim_Destruction_Touch_3rd',  'Destruction – Touch (3rd person)',  'Animation for Destruction touch-range spells in third person.',  'qcdrain'),
        animEntry('Anim_Destruction_Target_1st', 'Destruction – Target (1st person)', 'Animation for Destruction target-range spells in first person.', 'quickcast'),
        animEntry('Anim_Destruction_Target_3rd', 'Destruction – Target (3rd person)', 'Animation for Destruction target-range spells in third person.', 'quickcast'),

        animEntry('Anim_Illusion_Self_1st',      'Illusion – Self (1st person)',      'Animation for Illusion self-range spells in first person.',      'qcill'),
        animEntry('Anim_Illusion_Self_3rd',      'Illusion – Self (3rd person)',      'Animation for Illusion self-range spells in third person.',      'qcill'),
        animEntry('Anim_Illusion_Touch_1st',     'Illusion – Touch (1st person)',     'Animation for Illusion touch-range spells in first person.',     'qcill'),
        animEntry('Anim_Illusion_Touch_3rd',     'Illusion – Touch (3rd person)',     'Animation for Illusion touch-range spells in third person.',     'qcill'),
        animEntry('Anim_Illusion_Target_1st',    'Illusion – Target (1st person)',    'Animation for Illusion target-range spells in first person.',    'quickcast'),
        animEntry('Anim_Illusion_Target_3rd',    'Illusion – Target (3rd person)',    'Animation for Illusion target-range spells in third person.',    'quickcast'),

        animEntry('Anim_Mysticism_Self_1st',     'Mysticism – Self (1st person)',     'Animation for Mysticism self-range spells in first person.',     'qcsnap'),
        animEntry('Anim_Mysticism_Self_3rd',     'Mysticism – Self (3rd person)',     'Animation for Mysticism self-range spells in third person.',     'qcsnap'),
        animEntry('Anim_Mysticism_Touch_1st',    'Mysticism – Touch (1st person)',    'Animation for Mysticism touch-range spells in first person.',    'qctouch'),
        animEntry('Anim_Mysticism_Touch_3rd',    'Mysticism – Touch (3rd person)',    'Animation for Mysticism touch-range spells in third person.',    'qctouch'),
        animEntry('Anim_Mysticism_Target_1st',   'Mysticism – Target (1st person)',   'Animation for Mysticism target-range spells in first person.',   'quickcast'),
        animEntry('Anim_Mysticism_Target_3rd',   'Mysticism – Target (3rd person)',   'Animation for Mysticism target-range spells in third person.',   'quickcast'),

        animEntry('Anim_Restoration_Self_1st',   'Restoration – Self (1st person)',   'Animation for Restoration self-range spells in first person.',   'quickbuff'),
        animEntry('Anim_Restoration_Self_3rd',   'Restoration – Self (3rd person)',   'Animation for Restoration self-range spells in third person.',   'quickbuff'),
        animEntry('Anim_Restoration_Touch_1st',  'Restoration – Touch (1st person)',  'Animation for Restoration touch-range spells in first person.',  'qcdrain'),
        animEntry('Anim_Restoration_Touch_3rd',  'Restoration – Touch (3rd person)',  'Animation for Restoration touch-range spells in third person.',  'qcdrain'),
        animEntry('Anim_Restoration_Target_1st', 'Restoration – Target (1st person)', 'Animation for Restoration target-range spells in first person.', 'quickcast'),
        animEntry('Anim_Restoration_Target_3rd', 'Restoration – Target (3rd person)', 'Animation for Restoration target-range spells in third person.', 'quickcast'),
    }
})

-- ── Group 4: Animation Speeds ─────────────────────────────────────────
registerGroup({
    key              = 'SettingsOSSC_AnimSpeeds',
    page             = 'OSSCPage',
    l10n             = 'OSSC',
    name             = 'Animation Speeds (for developers)',
    description      = 'Do not change unless you know what you are doing.',
    permanentStorage = true,
    order            = 5,
    settings         = {
        { key = 'AnimSpeed_Quickcast', name = 'Quick Cast Speed',   description = 'Speed for quickcast (Target) animation.',          renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Quickbuff', name = 'Quick Buff Speed',   description = 'Speed for quickbuff (Self) animation.',            renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Qcconj',    name = 'Conjuration Speed',  description = 'Speed for qcconj animation.',                     renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Qctouch',   name = 'Touch Speed',        description = 'Speed for qctouch animation.',                    renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Qcalt',     name = 'Alteration Speed',   description = 'Speed for qcalt (Alteration Target) animation.',   renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Qcill',     name = 'Illusion Speed',     description = 'Speed for qcill animation.',                      renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Qcsnap',    name = 'Snap Speed',         description = 'Speed for qcsnap animation.',                     renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Qcdrain',   name = 'Drain Speed',        description = 'Speed for qcdrain animation.',                    renderer = 'number', default = 1.00 },
        { key = 'AnimSpeed_Qcskrow',   name = 'Skrow Speed',        description = 'Speed for qcskrow animation.',                    renderer = 'number', default = 1.00 },
        { key = 'AnimSpeedScale',      name = 'Global Cast Scale',  description = 'Global multiplier applied on top of all speeds.',  renderer = 'number', default = 1.00 },
        {
            key         = 'SafetyUnlockTimer',
            name        = 'Safety Unlock Timer',
            description = 'Maximum time (seconds) the cast stays locked as a fallback if the animation never fires its stop key.',
            renderer    = 'number',
            default     = 1.00,
            min         = 0.1,
            max         = 5.0,
        },
    }
})

print("--- OSSC SETTINGS INITIALIZATION FINISHED ---")
return script
