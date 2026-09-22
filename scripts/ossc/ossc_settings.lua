---@omw-context player
-- ============================================================================
-- OSSC: Oblivion-Style Spell Casting — settings registration (PLAYER script).
--
-- Registers the OSSC_QuickCast input action and every settings page/group,
-- then mirrors the player settings groups into global storage (see the
-- "Settings mirror" section at the bottom) so the global and actor scripts
-- can read them.
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
--
-- OSSC's settings groups are PLAYER settings, and player storage is only
-- readable from player/menu scripts (storage.playerSection). The global
-- script and the NPC/creature actor scripts could therefore never see menu
-- values — e.g. disabling quickcast for creatures had no effect.
-- Mirror every relevant group into GLOBAL storage (same section names) via
-- the OSSC_SyncSettings event: on load, and whenever a setting changes.
--
-- SettingsOSSC_Keys is included so EnablePlayerSwirls / EnableHandSwirls /
-- EnableCastGlow also reach NPC and eligible-creature scripts (they cannot
-- read player storage).
-- ============================================================================
local MIRRORED_GROUPS = {
    'SettingsOSSC_General',
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

-- storage passes the changed section's name as the first argument, so one
-- callback serves every mirrored group.
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
    name        = 'Oblivion-Style Spell Casting v4.3a',
    description = 'Settings for the OSSC Mod\n\nSpecial thanks to Dubiousnpc for his fantastic work on OSSC animations'
})

-- ── Group 1: General ──────────────────────────────────────────────────

I.Settings.registerGroup({
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
            default     = 'none',
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

-- The penalty values, their display order and the multiplier each one means all
-- live in scripts/ossc/ossc_penalty.lua, shared with the player script.
local Penalty = require('scripts.ossc.ossc_penalty')
local penaltySelectItems = Penalty.items

-- Same arrangement for the skill progression modes; see
-- scripts/ossc/ossc_skillmodes.lua.
local SkillModes = require('scripts.ossc.ossc_skillmodes')
local skillModeSelectItems = SkillModes.items

-- Older releases stored the penalty settings as numbers / display strings;
-- map them onto the select values once so the renderer can show them.
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

-- The skill-based penalty used to be a separate checkbox next to each select
-- ("… — Skill Based"), overriding whatever flat percentage was picked. It is
-- now the last item of the select itself. Fold a ticked checkbox into the
-- select once, then drop the checkbox key: it is no longer registered, and
-- leaving it behind would re-apply 'skill_based' on every load after the
-- player has gone back to a flat percentage.
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

-- The Shield Casting Penalty used to be Off / Reduced / Full with its own
-- skill-based checkbox; it is now one select of strengths (Off / 10%..100% /
-- Skill based). 'reduced' is 50%, 'full' is 100%; the checkbox folds in the
-- same way as the two above.
do
    local v = generalStorage:get('ShieldCastingPenalty')
    if v ~= nil and not Penalty.shield.valid[tostring(v)] then
        generalStorage:set('ShieldCastingPenalty', Penalty.shield.normalize(v))
    end
end
migrateSkillBasedCheckbox('ShieldCastingPenalty', 'ShieldCastingPenaltySkillBased')

-- The effect-penalty exclusion used to cover regular spells as well as scrolls
-- (QuickCastEffectPenaltyScrollsSpellsExempt). Only scrolls are meant to be
-- excluded — a scroll is consumed by the cast, so a penalised one is lost for a
-- weakened effect, whereas a spell can simply be cast again — so the toggle now
-- says exactly that. Carry the old choice over once and drop the old key.
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

-- 'ncg+se' and 'ncg+se (auto)' were dropped as separate choices: both ran the
-- same external handler chain as 'skillevo'. Rewrite a stored value the current
-- menu no longer offers so the renderer can show it and the player script reads
-- the mode that was actually meant.
do
    local v = generalStorage:get('SkillProgressionMode')
    if v ~= nil and not SkillModes.valid[tostring(v)] then
        generalStorage:set('SkillProgressionMode', SkillModes.normalize(v))
    end
end

I.Settings.registerGroup({
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
            max         = 10.0,
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
            name        = 'Enable SpeedyMagick Animation Speed Scaling',
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
            name        = 'Block Quick Cast During Fighting Animations (2 Handed)',
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
            default     = true
        },
        {
            key         = 'SkillProgressionMode',
            name        = 'Skill Progression Mode',
            description =
                'OSSC : Legacy mode. Uses OSSC flat XP formula.\n\n' ..
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
            name        = 'Skill Experience Ratio (OSSC legacy skill progression mode only)',
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

-- ── Group 5: NPC Quick-Casting ─────────────────────────────────────────
I.Settings.registerGroup({
    key              = 'SettingsOSSC_NPC',
    page             = 'OSSCPage',
    l10n             = 'OSSC',
    name             = 'NPC & Creature Quick-Casting',
    description      = 'Configure Oblivion-Style quick-casting for combat NPCs and eligible creatures. \nChanges do NOT apply to entities currently in combat.',
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
            name        = 'Melee / Touch Distance (units)',
            description = 'Distance at or below which quick-casting probability reaches maximum.',
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
            default     = 700,
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
            key         = 'NPCQuickCastCooldownMin',
            name        = 'Minimum Cooldown (seconds)',
            description = 'Minimum delay between quick-casts by the same NPC.',
            renderer    = 'number',
            default     = 3.5,
            min         = 1.0,
            max         = 60.0,
        },
        {
            key         = 'NPCQuickCastCooldownMax',
            name        = 'Maximum Cooldown (seconds)',
            description = 'Maximum delay between consecutive quick-casts by the same NPC.',
            renderer    = 'number',
            default     = 8.5,
            min         = 1.5,
            max         = 60.0,
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

I.Settings.registerGroup({
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
I.Settings.registerGroup({
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
