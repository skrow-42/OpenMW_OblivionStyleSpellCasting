# Oblivion-Style Spell Casting (OSSC) v4.24

**Oblivion-Style Spell Casting** (OSSC) brings modern spellcasting mechanics to OpenMW. It allows you to cast your currently selected spell (and enchanted item spells) using a hotkey or quickkey without needing to switch to spell stance, similar to TES IV: Oblivion.

---

## 1. Requirements

To run OSSC, the following must be enabled:
**Spell Framework Plus**
**minimum OpenMW 0.51RC1+**.
IMPORTANT
In the OpenMW Launcher, [Additional Animation Sources] must be enabled/ticked and is mandatory for OSSC to work.

---

## 2. Installation
1. Install OSSC.
2. Ensure OSSC is enabled in your OpenMW mod list.
3. Ensure **Spell Framework Plus** is enabled — it is the copy bundled in
   `SPELLFRAMEWORKPLUS/`, the one these builds are tested against.
4. Enjoy

---

## 3. Load Order
Load OSSC after 'Harder Better Faster Stronger/HBFS' mod. Otherwise aiming formula for touch spells will not work as intended.

---

## 4. Usage & Keybindings

- **Cast Key:** Press your assigned key to cast the currently selected spell. This system exists next to vanilla casting, not replacing it.
- **Rebinding:**  
  `ESC → Options → Scripts → Oblivion-Style Spell Casting`  
  Click **Quick Cast** and press any key/button to bind.
IMPORTANT: Do not set the quick cast button to the same button as spell stance. It DOESN'T overwrite it.
- **Quick Select Hotkeys:** You can also turn on in the settings possibility to be able to quickcast from hotbar. OSSC settings are very configurable, make sure to thoroughly check them.
---

## 5. Settings
Settings are found in:
`ESC → Options → Scripts → Oblivion-Style Spell Casting`

### General
- **Quick Cast binding** DO NOT SET THIS BUTTON TO YOUR READY SPELL STANCE - IT DOESN'T OVERWRITE IT
- **Enable Player VFX/Particles** (player swirl)
- **Enable Hand VFX (element ball)** (hand swirl)
- **Enable Cast VFX around hand** (school cast static glow burst on the hand)
- **Debug Mode** (prints OSSC logs in console)

### Gameplay
- **Use Fatigue** (optional fatigue usage on casting) — applies to the player **and** to NPC / eligible-creature quick-casts: when on, an actor's spell cast drains fatigue with the same MCP formula (magicka cost × (fFatigueSpellBase + encumbrance% × fFatigueSpellMult) × the scale multiplier)
- **Quick Cast Chance Penalty** (optional failure chance multiplier) — set to anything other than **Off** it also applies to NPC / eligible-creature quick-casts: their release is rolled against the same success chance as the player's (the vanilla cast-chance formula × the penalty, on the actor's own skill; creatures have no magic school skills, so their base is 100% and a skill-based penalty resolves at skill 0). A failed actor cast keeps its magicka/fatigue consumed and fizzles with the vanilla failure sound. While **Off**, actor quick-casts land unconditionally, as before
- **Quick Cast Effect Penalty** (optional magnitude / duration multiplier, in 5% steps, with a skill-based variant) — a penalised cast also reduces what the engine spawns for it: a summoned creature arrives with its health / magicka / fatigue, attributes, NPC skills and equipped weapon / armor scaled to the same percentage, and a bound item is swapped for a reduced copy — damage / armor values and the enchantment it carries included — that is taken back when the spell ends. The swap is applied by the actor's own local script (writing another actor's equipment is not allowed from a global script) and the full-strength original is discarded only once the actor confirms it
- **Quick Cast Effect Penalty — Exclude Spells & Scrolls** (off by default) — excludes regular spells and scrolls from the effect penalty, leaving only enchanted items penalised. **Powers are always excluded from the effect penalty**, regardless of this setting.
- **Block Target Spell Quick Casts While Swimming** (default on) — vanilla parity: a quick-cast with Target-range effects attempted while the caster is swimming plays out and consumes the magicka, but the spell always fizzles at the release (vanilla failure sound, no message); Self and Touch casts still work

### Snap Sound
- **Snap Sound Volume (0.0–1.0)**  
  Controls the volume of the snap sound used by the `qcsnap` animation group.  
  Sound timing is driven by the animation so it stays consistent and doesn’t retrigger during spam.
  Setting to 0.0 mutes the sound.

### NPC & Creature Quick-Casting
- **Enable NPC Quick-Casting** (master toggle for humanoid NPCs; applies live — disabling it also stops NPCs that are currently in combat, and their spells are handed back to the engine AI)
- **Enable Creature Quick-Casting** (master creature toggle for biped creatures; does not apply to creatures already in combat)
- **Enable Non-Biped Creature Quick-Casting** (allows spell-having non-biped creatures to quick-cast too — timer-driven casts with body VFX only, since their skeletons carry neither the quickcast animation groups nor hand bones; turn it off to restrict creature quick-casting to bipeds — running casts stop and the scripts detach automatically)
- **Allow Quick-Casting Powers** (Powers only count toward creature eligibility when enabled)

Healing spells (restoration / Restore Health) are quick-cast **self-only**: NPCs and creatures heal themselves with self-range healing spells, and never quick-cast a touch- or target-range healing spell at their target (which would heal the player, e.g. with Fair Care's touch-heal spells).

### Cast Animations (Core feature)
Choose the animation group used for each:
- **School:** Alteration, Conjuration, Destruction, Illusion, Mysticism, Restoration
- **Cast Type:** Self / Touch / Target
- **Perspective:** 1st person / 3rd person

### Animation Speeds (Advanced)
- Per-animation-group speed multipliers
- Global speed scale
- **Safety Unlock Timer**  
  Maximum time before OSSC force-unlocks if an animation fails to send its stop key (default: 1.00s).  
  This is a fallback; normally unlocking is done by the animation stop key.

---

## 6. Animation Groups
OSSC expects the configured animation groups to exist in your animation set. Common groups used by OSSC include:
- `quickcast`, `quickbuff`, `qcconj`, `qctouch`, `qcalt`, `qcalts`, `qcill`, `qcsnap`, `qcdrain`, `qcskrow`

Each group should contain appropriate text keys used by the script (typically `start`, `release`, `stop`).  
If an animation is missing required keys, the safety timers are used as a fallback.

---

## 7. Technical Details
OSSC is designed to be lightweight. It handles:
- Input gating
- Spell/enchanted item selection resolution
- Animation selection + blended playback
- VFX + sound timing
- Cast success logic (optional fatigue + chance penalty) — the **Use Fatigue** and **Quick Cast Chance Penalty** gameplay settings apply to the player *and* to managed NPCs / eligible creatures when enabled: an actor's spell cast pays the same MCP fatigue formula at the release, and with the chance penalty on (anything other than Off) the actor's cast is rolled against the same success chance as the player's — the vanilla cast-chance formula (transcribed from Spell Framework Plus' helper: lowest-margin effect school ×2, minus cost, plus cast bonus + 0.2×Willpower + 0.1×Luck, times the fatigue term) multiplied by the penalty scale on the actor's own skill. Powers are sure casts, creatures get a 100% base (the engine never fails a creature's cast) with skill-based penalties resolving at skill 0, and a failed actor cast keeps magicka + fatigue consumed and fizzles with the vanilla failure sound. With the chance penalty Off, actor casts land unconditionally as before
- Combat-only actor scripts: NPC and eligible-creature scripts are attached only after a live combat target is reported (OpenMW's `OMWMusicCombatTargetsChanged` event), and are detached when that target list becomes empty. When **NGarde** is installed, its own combat-target-changed global event (`ngarde_combatTargetChanged`) is the authoritative combat signal instead, but casting eligibility stays OSSC's own biped/spell/toggle gates — NGarde's `fencer` flag (a parry-loadout classification) never gates spellcasting, so mage NPCs and spell-having beasts keep their quick-casts under NGarde.
- **Creature eligibility:** Biped creatures quick-cast with the full NPC/humanoid animation + hand-VFX implementation. Non-biped creatures with at least one regular Spell (Powers only when **Allow Quick-Casting Powers** is on; passive Abilities never count) are eligible while **Enable Non-Biped Creature Quick-Casting** is on: their casts are timer-driven with cast sound + body swirl only — no cast animation is attempted and no hand-anchored VFX (element ball, hand glow, shield ghost) is spawned, because those skeletons have neither the animation groups nor the `Bip01 L Hand` bone. Flipping any creature toggle mid-combat stops new casts immediately and detaches the scripts through the normal safe-detach protocol.
- **NGarde parry block:** With **Block Quick Cast During NGarde Parry** on (default), exclusion works in both input orders: an active/winding guard blocks cast startup, and a cast already in progress sets NGarde's external parry-control state so a weapon guard cannot be raised over it. The state is released on every cast completion/interruption/load path.
- **Swimming gate (vanilla parity):** With **Block Target Spell Quick Casts While Swimming** on (default), a quick-cast whose effects include a Target range and that is released while the caster is swimming always fails, exactly like vanilla: the cast gesture plays, the magicka paid at animation start stays consumed, and the spell fizzles at the release moment with the vanilla "Spell Failure" sound — no projectile, no message, no skill XP, no power cooldown. "Swimming" uses the engine's own test (`types.Actor.isSwimming` — water level above `fSwimHeightScale`, ≈ 0.9 of the actor's height), so it only applies when the whole body is in the water: wading with just feet wet never triggers the rule. Self and Touch spells remain fully castable while swimming. Applies to the player; NPCs and eligible creatures still refuse these casts outright before any cost is paid. The bundled Spell Framework Plus keeps enforcing the same rule at the launch layer (`SettingsMagExp_General.BlockTargetSpellsWhileSwimming`, default on), so any Target spell that reaches `launchSpell` from a swimming caster is refused there too.
- **Free movement and safe attack abort (2H weapons on NPCs / eligible creatures):** NPC/creature quick-cast animations use an upper-body-only blend and never claim LowerBody, leaving the locomotion animation and its root motion active even while a two-handed weapon is equipped. While the quick-cast owns the hands, heavy-weapon attack plays (two-handed melee, bows, crossbows) are vetoed before they start (`options.skip` in the animation-controller hook) instead of being cancelled mid-swing, and every abort releases the engine attack input (`self.controls.use = NoAttack`) so the engine's character controller can leave its wind-up state on its own. A bare `anim.cancel()` on an AI-driven attack used to strand the upper-body state machine in its wind-up forever — the AI then never released the attack input and the actor never swung again, it could only quick-cast "from time to time". Equip/unequip plays are never vetoed (the engine needs their *equip attach* text key to re-attach the weapon), one-handed and hand-to-hand attacks still blend over the cast, and a self-heal frees actors already dead-locked by an older OSSC build in the same session.

Then it delegates spell launching and impact logic to **Spell Framework Plus** for compatibility with other mods using the same framework.

- **Friendlier Fire compatibility:** OSSC's spells are applied from Lua by Spell Framework Plus, which bypasses the engine's `ApplyMagicEffects` path that Friendlier Fire normally watches. OSSC therefore detects friendly fire itself — using Follower Detection Util's follower list and the same test Friendlier Fire uses — and skips harmful quick-casts aimed at followers or summons (and followers no longer quick-cast harmful spells at the player or each other). Friendlier Fire's spell settings are honoured read-only; it's a no-op without FDU/Friendlier Fire. The bundled Spell Framework Plus copy performs the same check before applying any Lua-cast spell, so projectile walk-ins and AoE are covered too.

### Interface for other mods

`I.OSSC` publishes a small API so hotbar / cast mods do not have to guess what a
`QuickKey1-9` press meant:

| Call | Purpose |
| --- | --- |
| `triggerQuickCast(opts?)` | Run a quick cast (`opts` with an `item` or a `spell`, or none for the currently selected magic). |
| `isCasting()` | True while a cast animation is in flight. |
| `addCastHandler(fn)` | `fn(data)` is called for every cast OSSC resolves. QuickSelect Ultimate uses this to keep the hotbar on screen for a moment after a quick cast. |
| `cancelPendingQuickkey(slot?)` | Paged hotbar mods: this press was **not** a cast request (row switch, empty slot, hand-to-hand tile) — drop the pending cast. |
| `notifyQuickkeyActivation(slot)` | Paged hotbar mods: this press activated real hotbar slot `slot` (row 2 key 3 = 13), or `nil` when nothing was activated. |
| `awardSkillProgress(skillId, opts?)` | Award spellcasting skill experience to the player. Works whatever the **Skill Progression Mode** setting says — this is the way in when it is set to `none`. See below. |
| `castSpellAtTarget(opts)` | Cast a spell on the player **now**, without waiting for a hotkey or the cast animation: `opts` is `{ spellId = 'x', target?, effectScale?, isFree?, userData? }`. Returns `true`, or `false` plus a reason. See below. |
| `ignoreSpell(spellId)` / `unignoreSpell(spellId)` | Never let OSSC *pick* this spell on its own (hotkeys and `castSpellAtTarget` still cast it). `setSpellIgnored(spellId, ignored)` and `isSpellIgnored(spellId)` are the explicit pair. See below. |
| `getQuickCastFullChanceDistance()` | The distance (game units) at or below which NPC/creature quick-cast probability is at its maximum — the "100% probability" distance of the NPC settings (`NPCQuickCastMinDistance`, default 500). Also on `I.OSSC_Casters` (global) and `I.OSSC_Caster` (same actor). See below. |
| `getNPCSettings()` | Every NPC/creature quick-cast setting (the whole `SettingsOSSC_NPC` group) as a live snapshot table — unset keys answer with their registered defaults. Also on `I.OSSC_Casters` (global) and `I.OSSC_Caster` (same actor). See below. |

#### Launching a spell from your mod

Every spell OSSC fires is launched through the bundled **Spell Framework
Plus**, so another mod has two routes — both are always available while OSSC
is installed, since SFP ships inside it:

1. **Through OSSC — `castSpellAtTarget`** (next section). Use it when the
   cast should be treated as an OSSC quick-cast: OSSC's validation (player
   alive, not mid-cast, magicka on hand) and the player's quick-cast effect
   penalty settings apply, and OSSC owns skill progression for the launch.
   It plays no cast animation — the caller drives its own cast sequence.
2. **Directly via Spell Framework Plus** — the API OSSC itself delegates to
   for the actual launch. Use it when you own the launch: full movement /
   collision / piercing / bounce control, VFX / sound / light overrides,
   curved `motionPath` flight, `itemRequirements`, caller-scoped target
   exclusions, and no OSSC bookkeeping at all.

Minimum examples:

```lua
local I = require('openmw.interfaces')

-- Route A — player (player script):
I.OSSC.castSpellAtTarget({ spellId = 'my_fireball', target = actor })

-- Route A — any actor (global script):
I.OSSC_Casters.castSpellAtTarget({ caster = actor, spellId = 'my_fireball' })

-- Route B — global script (full parameter set below the reference):
local proj = I.MagExp.launchSpell({
    attacker  = caster,
    spellId   = 'my_spell',
    startPos  = pos,             -- util.vector3
    direction = dir,             -- util.vector3
    -- ...plus speed, bounceEnabled, piercing, vfxRecId, boltLightId,
    -- motionPath, userData.ignoreActorRecordIds, itemRequirements, ...
})

-- Route B — player/local script:
core.sendGlobalEvent('MagExp_CastRequest', {
    attacker = self, spellId = 'my_spell', startPos = pos, direction = dir,
})
```

Full `launchSpell` parameter reference and in-flight control:
`SPELLFRAMEWORKPLUS/README.md` — §3 (player/local events), §4 (all launch
parameters), §5–§8 (live modification, bounce, piercing, forces), §11–§12
(impact and effect-lifecycle events), §18 (non-actor sources, lockable /
universal effects), §24 (curved motion paths), §25 (caller-scoped target
exclusions), §26 (world-pause behavior). For instant application without a
projectile, SFP also exposes `applySpellToActor` (direct hit on an actor)
and `detonateSpellAtPos` (AoE blast).

Notes that apply to both routes:

- The launch still passes SFP's launch-time guards — the swimming gate for
  Target-range spells, the magicka resource guard (unless `isFree = true`),
  stacking limits, and (in this bundle) the world-pause rules — so a direct
  launch behaves the same as an OSSC quick-cast of the same spell.
- Launches routed through OSSC are marked `userData = { OSSC = true,
  External = true, ...your fields }`, and SFP then skips its own
  skill-progression award for that launch — OSSC owns progression per its
  **Skill Progression Mode** setting. A direct Route B launch without that
  marker gets SFP's own skill-progression behavior instead.
- Non-player casters through Route A: the cost is charged at launch by SFP
  (unless you pass `isFree = true`) and the spell lands at full strength by
  default — `effectScale` defaults to `1.0`, the player's quick-cast penalty
  settings apply to the player only.

#### Casting a spell on demand

`castSpellAtTarget` turns one request into a real launch through the same
Spell Framework Plus pipeline OSSC's own quick-casts use — magicka is paid, the
effect penalty applies, and the target is aimed at. It plays no animation,
because the caller is expected to drive its own cast sequence:

```lua
I.OSSC.castSpellAtTarget({ spellId = 'my_fireball' })             -- straight ahead
I.OSSC.castSpellAtTarget({ spellId = 'my_heal', target = actor }) -- at an actor
I.OSSC.castSpellAtTarget({
    spellId = 'my_fireball', target = util.vector3(x, y, z),       -- at a spot
    effectScale = 0.5,                                             -- quick-cast penalty
    isFree = true,                                                 -- you paid the cost
    userData = { MyMod = true },                                   -- forwarded to MagExp
})
```

The player's own script is the one that answers, so the player's penalty
settings and validation apply. A global script gets the actor-aware version:

| Route | Use it from | Call |
| --- | --- | --- |
| `I.OSSC_Casters` | any global script | `castSpellAtTarget({ caster = actor, spellId = 'x', target?, effectScale?, isFree?, userData? })` |
| `I.OSSC_Caster` | a local script **on the actor itself** | the same call, with the actor implied |

For the player, `I.OSSC_Casters.castSpellAtTarget` simply hands the request to
`I.OSSC`, so a mod that supports both does not have to special-case the player.
`isFree` follows OSSC's launch path: omitted means OSSC pays the cost and marks
the launch prepaid, `true` means you already paid, `false` leaves the charge to
Spell Framework Plus' launch-time guard. The actor-aware global route also
accepts the raw launch fields `startPos`, `direction`, `hitObject`, `hitPos`,
`area`, `spawnOffset` and `item` (an enchanted-item source), which it forwards
to the SFP request.

#### Keeping a spell out of OSSC's rotation

`ignoreSpell('my_spell')` (or `setIgnoredSpells{ ... }` for a whole list) tells
OSSC **not to choose** that spell when it picks one itself — a scripted NPC's
spell selection and the automatic quick-cast picker skip it. The actor still
knows the spell, and a hotkey press or another mod's explicit cast still works:
this is a picking veto, not a ban. Vetoes are record ids (case-insensitive),
live in OSSC's global storage, and survive a save/load, so a mod that registers
them once in its own `onInit` keeps them.

| Route | Call |
| --- | --- |
| `I.OSSC_Casters` (anywhere) | `ignoreSpell(spellId)`, `unignoreSpell(spellId)`, `setSpellIgnored(spellId, ignored)`, `isSpellIgnored(spellId)`, `getIgnoredSpells()`, `setIgnoredSpells{ ids }`, `clearIgnoredSpells()` |
| `I.OSSC` (player script) | the same spell-filter calls |

`I.OSSC_Casters` owns the list, so it is visible to every actor OSSC manages —
register there (or through `I.OSSC`, which forwards) if the veto should apply
to NPCs and creatures, not only to the player.

Typical mod-author usage — keep a spell out of OSSC's rotation and cast it
yourself, only on your own demand:

```lua
-- your mod's GLOBAL script, once (e.g. in onInit):
local I = require('openmw.interfaces')

I.OSSC_Casters.ignoreSpell('my_ritual_spell') -- OSSC will never pick it

-- later, whenever your mod decides to cast it:
I.OSSC_Casters.castSpellAtTarget({
    caster  = someActor,        -- any actor; for the player this forwards to I.OSSC
    spellId = 'my_ritual_spell',
    target  = someOtherActor,   -- optional; omit to aim straight ahead
})
```

Explicit casts are exempt from the veto, so this pair gives exactly "never
quick-cast by OSSC, castable on demand by my mod" — the same holds for a
player who deliberately binds the spell to a QuickKey: that press still casts.

#### Driving skill progression yourself

**Skill Progression Mode → `none`** means OSSC awards no spellcasting experience
at all, because another mod owns progression. For that mod:

- **`OSSC_SkillProgressSkipped`** — a global event fired for every cast OSSC
  silenced, carrying `{ actor, skillId, spellId, cost, isEnchant }`, so you know
  when to award. It fires only in the `none` mode.
- **`I.OSSC.awardSkillProgress(skillId, opts?)`** — apply the gain you computed,
  from any player script:

```lua
local I = require('openmw.interfaces')

I.OSSC.awardSkillProgress('destruction', { skillGain = 0.35 })  -- your amount
I.OSSC.awardSkillProgress('destruction')                        -- OSSC's SkillExperience setting
I.OSSC.awardSkillProgress('destruction', { backend = 'external' })  -- NCG / SE / MBSP / SUS
```

`skillGain` is in the unit `skill.progress` is exposed in (`1.0` == one skill
level); major / minor / specialization bonuses are not applied, the formula is
yours. Returns `true`, or `false` plus a reason string — it never fails
silently. Crossing a full level raises the skill with the vanilla message and
sound and bumps the level counters that feed attribute / specialization bonuses;
writing `skill.progress` yourself does none of that, because the engine only
stores the write and never levels from it. The bundled Spell Framework Plus
exposes the same pair (`MagExp_SkillProgressSkipped` and
`I.MagExp_Player.awardSkillProgress`).

#### Pausing an NPC / creature caster

OSSC drives an attached NPC or creature's spellcasting — its spell list, stance
and cast animation. A mod that wants to drive the same actor itself (a scripted
scene, a dialogue, a custom AI) should hold OSSC off instead of fighting it:

| Route | Use it from | Call |
| --- | --- | --- |
| `I.OSSC_Casters` | any global script | `pause(actor, reason?)`, `unpause(actor, reason?)`, `setPaused(actor, paused, reason?)`, `isPaused(actor)`, `casterScript(actor)` |
| `I.OSSC_Caster` | a local script **on the actor itself** | `pause(reason?)`, `unpause(reason?)`, `isPaused()`, `isCasting()`, `isSuspended()` |
| `OSSC_SetCasterPaused` | any script, sent to the actor | `{ paused = true, reason = 'my-mod' }` |

A paused caster stops quick-casting immediately, hands the engine's own spell
list back and abandons an in-flight cast; releasing the pause resumes it exactly
where it was. Requests are keyed by `reason`, so two mods can pause
independently — releasing one reason does not resume the actor for the other.
`unpause(actor)` with no reason (and `I.OSSC_Caster.unpause()` with no argument)
releases every pause. A pause is not saved: after a save/load it is the
requesting mod's job to ask again.

`I.OSSC_Casters.pause` returns `false` when OSSC does not manage the actor
(disabled in the settings, dead, or a creature that fails the eligibility
toggles). It attaches the caster script on demand, so a request on an eligible
actor works outside combat too — but note that OSSC detaches out of combat on
its own: the actor-side `I.OSSC_Caster` only exists while the caster script is
attached (check `actor:hasScript(I.OSSC_Casters.casterScript(actor))`), and
`I.OSSC_Casters.isPaused` mirrors what was requested through the global route,
while the authoritative state lives on the actor. The pause shares the gate the
safe-detach protocol uses, so `isSuspended()` is true while a detach is pending
**or** a pause is held — a pause never cancels a detach, and combat resuming
never cancels a pause.

#### Reading the NPC quick-cast settings

Every OSSC NPC/creature quick-cast setting (the whole `SettingsOSSC_NPC`
group) is exposed so other mods can forward the player's configured values
instead of hardcoding the defaults. `getNPCSettings()` returns a live snapshot
table — a fresh copy on each call, safe to keep or mutate — with unset keys
answered by their registered defaults:

| Route | Use it from | Calls |
| --- | --- | --- |
| `I.OSSC_Casters` | any global script | `getNPCSettings()`, `getQuickCastFullChanceDistance()` |
| `I.OSSC` | any player script | `getNPCSettings()`, `getQuickCastFullChanceDistance()` |
| `I.OSSC_Caster` | a local script **on a managed actor itself** | `getNPCSettings()`, `getQuickCastFullChanceDistance()` |

The snapshot carries all thirteen keys of the group: `NPCQuickCastEnabled`,
`NPCQuickCastCreatures`, `NPCQuickCastNonBipedCreatures`,
`NPCQuickCastDebugLog`, `NPCQuickCastAllowPowers`, `NPCQuickCastRandomAnims`,
`NPCQuickCastPollInterval`, `NPCQuickCastBaseChance`,
`NPCQuickCastMinDistance`, `NPCQuickCastMaxDistance`,
`NPCQuickCastHealThreshold`, `NPCQuickCastCooldownMin` and
`NPCQuickCastCooldownMax`. The values are live: a player's change in the
settings menu is picked up without a reload (the global and actor routes read
OSSC's settings mirror, synced on load and on every change; the actor-side
copy refreshes once a second).

`getQuickCastFullChanceDistance()` is the convenience read-out of one of those
keys — `NPCQuickCastMinDistance`, the distance at which quick-cast probability
is 100%. NPC/creature quick-cast rolls are distance-based: at or below
**Melee / Touch Distance** (`NPCQuickCastMinDistance`, default 500) the
probability is at its maximum — 100% with the default **Base Quick-Cast
Probability** — and above it the chance falls linearly to 0% at **Maximum Cast
Distance** (`NPCQuickCastMaxDistance`, default 700). A mod that wants its own
range logic to line up with OSSC's ramp reads the values instead of guessing:

```lua
local I = require('openmw.interfaces')

local fullChanceDist = 500 -- fallbacks for an older OSSC
local maxDist, baseChance = 700, 1.0
local casters = I.OSSC_Casters
if casters then
    if type(casters.getNPCSettings) == 'function' then
        local cfg = casters.getNPCSettings()
        fullChanceDist = cfg.NPCQuickCastMinDistance
        maxDist        = cfg.NPCQuickCastMaxDistance
        baseChance     = cfg.NPCQuickCastBaseChance / 100
    elseif type(casters.getQuickCastFullChanceDistance) == 'function' then
        fullChanceDist = casters.getQuickCastFullChanceDistance()
    end
end
```

---

## 8. Pure Multi Mark Compatibility
OSSC integrates with **Pure Multi Mark (PMM)** so quick-cast Mark and Recall work with multi-mark lists. Toggle it with **Pure Multi Mark Compatibility** in the General settings (default on). It activates automatically when PMM is installed.

- **Quick-cast Mark** stores your current location in the PMM list (in addition to setting the vanilla engine mark).
- **Quick-cast Recall** plays the full cast animation first, then opens the PMM selection window after the casting happens when you have more than one mark, so you can pick which mark to teleport to. This works even with animation groups that have no `stop` text key (e.g. `qcsnap`).
- The actual teleport is performed via OSSC's global script, so it works even when PMM's own global script is not loaded.
- Closing the window without choosing a mark (Esc, the X button, the "Latest" button, or the window failing to load) cancels the recall — while this option is enabled, a vanilla Recall to the engine mark never goes through.

---

## 9. Credits
- **Mod Author:** skrow42 / Antigravity
- **Animations:** BIG thanks to MaxYari and dubiousnpc for providing the animations for casting. Also Fallchildren for his VFX bone file for spell effects on hands.
- **Physics Engine:** Thanks to MaxYari again for his great physics engine work.
- **Additional Kudos:** Thanks to Moneymitch from OpenMW discord for providing base for the Quick-Keys patch and also Ralts for allowing to use his spellcast formulas

---

## 10. Development & Tests
`tools/tests/` contains regression tests for the QuickKey1-9 hotkey logic shared with paged hotbar mods and for the QuickSelect hotbar itself. They load the real mod scripts against a stubbed OpenMW Lua API and drive them the way the engine does (`input.onInputAction`, `onUpdate`, `onKeyPress`, UI mode changes), so the shipped code paths actually run:

```
sh tools/tests/run_tests.sh
```

Any Lua 5.1+ interpreter works (`lua`, `lua5.1`, `luajit`, …); when there is none, the runner falls back to `python3` + `lupa` (`pip install lupa`) through `tools/tests/lupa_runner.py`. The suite covers the hotkey-cast decisions (row switch, plain-item slot, empty slot, *Cast on Strike* weapon, repeat press, spell hotkey, manual spell stance), what pays for a cast (a spell's magicka pool versus an enchanted item's **charge**, driven through the safety launch timer that resolves most casts — it must carry the cast's payment verdict, and the cast-chance roll that runs later must not demand the spell's cost a second time from the pool the payment already drained, so a spell cast with exactly its own cost still goes off), the QuickSelect ⇄ OSSC handshake, and the QuickSelect hotbar itself: key names the engine does not know must not raise, summoning a faded-out bar with the row switch keys, fading on world time only (no pop-ins on menu or cell transitions), the QuickLoot input hand-over, the stance / quick-cast holds, the NPC/creature quick-cast blend and attack-abort (a 2H-wielding biped's cast must leave LowerBody/root motion free, and vetoed heavy-attack plays or aborted in-flight attacks must always come with an engine attack-input release), free placement (drag, rotate, lock) and the vertical side anchors, the hand-to-hand slot in the storage layer, the settings menu itself (every setting must name a renderer the engine can resolve, with or without the mod's color-picker menu script, and a lit icon tile must keep its exact box in both border styles), and the Spell Framework Plus projectile pipeline: impacts land on the aim line, and the **Apply Race Weight to Projectile Speed (Normalise Race Speed)** toggle genuinely changes bolt speed (`launchSpell` must multiply by the caster's race weight when the toggle is on and not when it is off), the caster pause (both routes, nested reasons, the on-demand attach and the refusal cases), and the effect-penalty hand-off end to end: a global sweep may never equip another actor's slot or write its stats — the summon's own local script does it and confirms, the full-strength original is only removed on that confirmation, a reduced twin's enchantment is generated and scaled with it, a quick-cast stand-in is discarded when the same spell is recast at full strength, whatever form the engine reports the id in, a self-range quick cast always names its caster as the source object (Spell Framework Plus rejects a request without one — the drop was silent and made whole self casts never happen), and a dropped conjured bound item returns to the caster's pack with a notice, every time, until the spell ends. See `tools/tests/README.md` for what each harness drives and why. These files are development-only — they are not referenced by any `.omwscripts` manifest and are never loaded by the game.
