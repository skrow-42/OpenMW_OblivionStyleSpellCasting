# Oblivion-Style Spell Casting (OSSC) v4.4

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
- **Quick Cast Chance Penalty** (optional failure chance multiplier) — set to anything other than **Off** it also applies to NPC / eligible-creature quick-casts: their release is rolled against the same success chance as the player's (the vanilla cast-chance formula × the penalty, on the actor's own skill; creatures have no magic school skills, so their base is 100% and a skill-based penalty resolves at skill 0). A failed actor cast keeps its magicka/fatigue consumed and fizzles with the vanilla failure sound. While **Off**, actor quick-casts land unconditionally, as before. **Sure casts — Powers, abilities and "Always Succeeds" spells — are exempt from this penalty:** vanilla never rolls one, so it is answered 100% whatever this setting says
- **Quick Cast Effect Penalty** (optional magnitude / duration multiplier, in 5% steps, with a skill-based variant) — a penalised cast also reduces what the engine spawns for it: a summoned creature arrives with its health / magicka / fatigue, attributes, NPC skills and equipped weapon / armor scaled to the same percentage, and a bound item is swapped for a reduced copy — damage / armor values and the enchantment it carries included — that is taken back when the spell ends. The swap is applied by the actor's own local script (writing another actor's equipment is not allowed from a global script) and the full-strength original is discarded only once the actor confirms it. **Powers are always excluded from this penalty** (a Power burning its once-a-day use must land at full strength); abilities and "Always Succeeds" spells pay it like any other cast
- **Quick Cast Effect Penalty — Exclude Scrolls** (off by default) — excludes scrolls (the CastOnce enchantment form, consumed by the cast) from the effect penalty; regular spells, abilities and equipped magic items are still penalised
- **Shield Casting Penalty** (optional cast-animation slowdown while a shield is carried) — the shield's weight slows a quick-cast down by up to the full Carry-Capacity-Ratio formula, in shares (10%..100%) or skill-based; sure casts are slowed like any other cast
- **Block Target Spell Quick Casts While Swimming** (default on) — vanilla parity: a quick-cast with Target-range effects attempted while the caster is swimming plays out and consumes the magicka, but the spell always fizzles at the release (vanilla failure sound, no message); Self and Touch casts still work
- **Moving-Target Lead / Aim Prediction** (default on) — clones the OpenMW engine's AI spell leading (`mwmechanics/aicombat.cpp`, `AimDirToMovingTarget`) for quick-casts: a target-range bolt fired at a moving actor is aimed at the predicted intercept point instead of where the target stands at that moment. The target's velocity is estimated over the engine's own 0.25 s AI-reaction window, and the intercept is solved with the vanilla bolt speed (`fTargetSpellMaxSpeed` × the spell's effect speeds — the same speed Spell Framework Plus flies the bolt at). Player quick-casts lead identically from weapon stance, spell stance or relaxed hands (hotkey button, quickkeys 1-9, quick-select and enchanted items/scrolls all go through the same launch funnel); NPC / eligible-creature quick-casts lead any live engine combat target the same way whenever OSSC owns casting — the engine's vanilla Spell stance is left to the vanilla cast. Stationary targets and Touch/Self spells are aimed at exactly as before; a teleporting target (velocity estimate beyond sanity) is never led

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
- **Mercy CAO: Allow Short Quick-cast Windows** (default on) — when Mercy CAO is installed and keeps a spellcaster in `STANCE.Spell` as a posture, OSSC can briefly ask Mercy to yield, switch to `STANCE.Weapon`, play one normal blended quick-cast, then give Mercy its combat state and Spell posture back. A real vanilla cast cycle is never interrupted before `SpellCast Unequip Stop`. Turn this off for the old complete stand-down.
- **Mercy CAO: Quick-cast Window Cooldown (seconds)** (default 2.0) — minimum time between short windows on the same actor, so Mercy keeps most of the fight to itself. The window itself lasts only one quick-cast (or a short 0.35 s prepare/evaluation timeout if no spell is chosen).
- **Take Over Bare Spell Stance** (default on) — when an actor sits in `STANCE.Spell` without one of the nine real vanilla spellcast text keys (`self/target/touch` × `Start/Release/Stop`), treat it as a posture (Mercy warning stance, spellcast equip/idle animation, or the engine AI idling after a cast with a sticky selected spell). OSSC clears the stale selected castable, strips the engine spell list, switches to `STANCE.Weapon` and quick-casts. A real engine cast is still protected. Disable for the old unconditional stand-down in every Spell stance.
- **Bare Spell Stance Takeover Delay (seconds)** (default 1.0) — how long a Spell stance with no real vanilla spellcast text key is protected before OSSC takes it over. Increase if a genuine engine cast is being interrupted.
- **Vanilla Cast Unequip Stop Timeout (seconds)** (default 5.0) — after a real vanilla cast key, OSSC keeps the engine spell list restored and holds quick-casts until `SpellCast Unequip Stop` appears. If that animation key is missing, this fallback strips the spells and re-arms quick-casts. Set to `0` to wait strictly for `SpellCast Unequip Stop`.
- **Vanilla Casts Allowed After a Pause — Minimum / Maximum** (default 1 / 2) — when another mod (Mercy CAO included) hands this actor its spells back by releasing its pause, the engine finally has a list it can cast from. OSSC lets the engine **finish this many real vanilla casts** before it strips the list again and resumes its own quick-casts. The count is rolled per hand-back between the two values: **equal values pin the rate** (e.g. `2` / `2` always allows two casts), a **lower min than max randomises it** (e.g. `1` / `2` varies between one and two casts each time), and `0` / `0` restores the old behaviour (OSSC takes the list back on the next update — which is why the NPC often never got to cast). A max below the min is clamped up to it.
- **Vanilla Cast Allowance Timeout (seconds)** (default 6.0) — safety bound for each vanilla cast allowed by the setting above. If the engine does not press a real vanilla cast key within this many seconds, OSSC takes the spell list back anyway, so an actor is never silenced by a cast that never comes. `0` waits indefinitely for the engine.
- **Vanilla Cast Allowance Readiness (seconds)** (default 1.5) — an *unused* allowance only waits this long for the engine to ready magic at all. The engine must select a spell (Spell stance) before it can cast one; Mercy CAO releases its pause around every routine it runs, so an allowance re-armed on every release kept OSSC silent for the whole fight even while Mercy was not driving the actor. Lower = OSSC quick-casts sooner, higher = the engine gets more time to begin. `0` waits the full timeout instead.

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
- Cast success logic (optional fatigue + chance penalty) — the **Use Fatigue** and **Quick Cast Chance Penalty** gameplay settings apply to the player *and* to managed NPCs / eligible creatures when enabled: an actor's spell cast pays the same MCP fatigue formula at the release, and with the chance penalty on (anything other than Off) the actor's cast is rolled against the same success chance as the player's — the vanilla cast-chance formula (transcribed from Spell Framework Plus' helper: lowest-margin effect school ×2, minus cost, plus cast bonus + 0.2×Willpower + 0.1×Luck, times the fatigue term) multiplied by the penalty scale on the actor's own skill. Powers, abilities and "Always Succeeds" spells are **sure casts** — exempt from the Quick Cast Chance Penalty (no release roll; answered 100 before any chance scaling, exactly like vanilla). The Quick Cast Effect Penalty scales abilities and "Always Succeeds" spells like any cast but never a Power (see above); fatigue cost and shield slowdown apply to every cast. Creatures get a 100% base (the engine never fails a creature's cast) with skill-based penalties resolving at skill 0, and a failed actor cast keeps magicka + fatigue consumed and fizzles with the vanilla failure sound. With the chance penalty Off, actor casts land unconditionally as before
- **Moving-target lead (velocity leading):** With **Moving-Target Lead / Aim Prediction** on (default), OSSC clones the OpenMW engine's AI spell leading — `apps/openmw/mwmechanics/aicombat.cpp`, `AimDirToMovingTarget()` (commit `67abc60264`, 2014; shipped in OpenMW 0.45–0.51.x, replaced upstream by per-frame aiming in mid-2026) — for quick-casts. Every simulation tick the player script feeds the actor under the crosshair (the cached rendering-ray hit) and NPC / creature scripts feed their combat target to the shared tracker in `scripts/ossc/ossc_target_lead.lua`; at the launch moment the target's velocity is estimated over the engine's 0.25 s `AI_REACTION_TIME` window (with teleport-sanity and retention guards the engine never needed), and for Target-range effects the intercept time is solved exactly as the engine does — perpendicular velocity components of target and projectile must match, `tCollision = sqrt(dist² − projDistDiff²) / (sqrt(projSpeed² − velPerp²) − velDir)` — with `projSpeed` the vanilla bolt speed (`fTargetSpellMaxSpeed` × average effect speed, numerically identical to what Spell Framework Plus flies the bolt at). The resulting lead displacement is added to the already-converged aim point, so stationary targets keep the exact previous trajectory (zero displacement) and the crosshair parallax convergence survives for moving ones. Intercept times beyond 3 s are capped and targets outrunning the bolt are not led at all (the engine's math would aim behind them); both deviations are documented in the module header. The launch funnel itself never reads the stance, so player casts from weapon stance, spell stance and relaxed hands all lead identically. Actor quick-casts use the same funnel outside the engine's vanilla Spell stance; inside it OSSC stands down (see below).
- Combat-only actor scripts: NPC and eligible-creature scripts are attached only after a live combat target is reported (OpenMW's `OMWMusicCombatTargetsChanged` event), and are detached when that target list becomes empty. When **NGarde** is installed, its own combat-target-changed global event (`ngarde_combatTargetChanged`) is the authoritative combat signal instead, but casting eligibility stays OSSC's own biped/spell/toggle gates — NGarde's `fencer` flag (a parry-loadout classification) never gates spellcasting, so mage NPCs and spell-having beasts keep their quick-casts under NGarde.
- **Real vanilla spellcast detection + cast-cycle handshake (actors):** `anim.isPlaying(self, 'spellcast')` is intentionally **not** used: the engine also plays equip, unequip and idle-posture animations from the same `spellcast` group, and a selected spell stays sticky after `ActionSpell::prepare()`. The shared `ossc_vanilla_spellcast.lua` module listens to all animation text keys but only reacts to the nine real casting markers: `self start/release/stop`, `target start/release/stop`, `touch start/release/stop` (case-insensitive, also accepting full `SpellCast: Self Start`-style keys). `playBlendedAnimation` start keys are noted too, so the cycle opens before the first text key arrives. Any of those nine keys means another system temporarily re-added the actor's spells for a vanilla cast: OSSC restores its cached spells, holds quick-casts and marks a cast cycle pending. `Release` / `Stop` do **not** re-arm quick-casts by themselves. Only `SpellCast: Unequip Stop` — also accepted as group `spellcast` + key `unequip stop`, or the user form `SpellCast Unequip Stop` — ends the cycle: OSSC strips the engine-facing spells again and quick-casts resume. A configurable timeout releases the cycle if the unequip key is missing (`0` = strict wait). Equip/idle spellcast anims, CastSpell input and sticky selected castables no longer silence OSSC.

  **The strip state IS the mode switch.** The actor's castable spells have exactly one owner at a time, and OSSC decides everything from that:

  * **OSSC owns them (stripped) → quick-casts only.** The engine has nothing to cast from, so a `spellcast` `self/target/touch Start/Release/Stop` key is a leftover of a cast OSSC already ended (or an animation-only fake). It is ignored: it does not restore the spell list, does not open a cast cycle and does not hold a quick-cast. A `STANCE.Spell` in this state is a stale posture and is taken over immediately (no takeover delay).
  * **The engine owns them (not stripped) → vanilla casting only.** No quick-casts, no strip, no selected-castable clear, no stance takeover, and the list is actively kept on the actor. The phase ends when the vanilla cast cycle finishes (last allowed `SpellCast Unequip Stop`) or when the readiness grace says the engine will not use the list — then OSSC strips again and quick-casts until the next hand-back.

  **Vanilla-cast allowance (cooperation, not just detection):** restoring the engine spell list is not the same as letting the engine cast. Mercy CAO pauses OSSC when it wants a vanilla spell, restores the list, and then releases the pause — often a fraction of a second before the engine presses its cast input — so stripping the list on the first update after that release killed exactly the cast OSSC had just made possible. Every pause release therefore arms a **cast-count allowance** (rolled between `NPCVanillaCastsAllowedMin` and `NPCVanillaCastsAllowedMax`, default 1–2, so the actor does not always alternate in the same rhythm; equal bounds pin it, `0`/`0` disables it. `NPCVanillaCastAllowanceTimeout` bounds each cast): the engine keeps the spell list, its selected castable and its spell gesture, OSSC opens no window, starts no quick-cast, clears no selected castable and writes no stance until the budget is spent or `SpellCast Unequip Stop` on the last allowed cast closes it and `removeAllCastableSpells()` runs.

  **The window is not re-armed by a flickering pause.** Mercy CAO pauses and releases OSSC around every routine it runs (spell, reposition, attack burst), so a release is *not* a fresh hand-back by itself. A budget that is still open keeps its own deadline and its own remaining casts; only a release after the previous budget was spent or expired starts a new one. Without that the deadline was pushed forward every few seconds and OSSC never quick-cast again, even though `mercyDriving` was false the whole time.

  **An allowance the engine never readies magic for is retired early.** The engine has to select a spell — entering `STANCE.Spell` — before it can cast one, so an untouched budget only gets `NPCVanillaCastAllowanceReadiness` (default 1.5 s) to show that intent. After that OSSC takes the spell list back and quick-casts normally; a budget that *did* see Spell stance, or that is inside a real cast cycle, is untouched by this and still ends on its own cast keys / timeout.

  **The window hands the spells back, it does not just stop stripping them.** An earlier list of the actor's spells is snapshotted when the window opens and `Actor.spells():add()` is queued for every spell the engine is missing, so a list OSSC had stripped for its own quick-casts (the normal case) is restored even when OSSC's own "stripped" flag says otherwise — that flag only describes what OSSC did. While the window lasts the list is re-checked twice a second and anything a mod removed (or a deferred `remove()` that landed after the hand-back) is queued again, so the actor never stands through its vanilla window with an empty spell list. Every update path — no combat target, out of range, a pause, a stand-down — re-asserts the list before returning. A cast that opened while budget remained keeps its own `SpellCast Unequip Stop` handshake, and the allowance is session state (save/load, combat end and cell re-entry reset it). The two modes then alternate indefinitely: vanilla burst → OSSC quick-cast burst → vanilla burst. The full animation key list (including `SpellCast: Unequip Stop`) is documented in MW Modding Notes [3](https://operatorjack.github.io/mw-modding-notes/animation/animation-text-keys.html).
- **Vanilla Spell stance stand-down (actors):** `STANCE.Spell` (numeric value **2** in OpenMW — `Nothing=0`, `Weapon=1`, `Spell=2`) is the engine's ordinary magic stance. While the real vanilla cast cycle above is pending (until `SpellCast Unequip Stop` or its timeout), OSSC starts no quick-cast, does not clear the engine's selected castable, does not strip the engine-facing spell list, and never writes the stance back to Weapon. An OSSC cast already in flight is cleaned up rather than layered over the vanilla one. A bare Spell posture with no real cast key is taken over after the configured delay (see below). Mercy CAO's Spell *posture* uses the same short window.
- **Mercy CAO / bare Spell-posture short quick-cast window:** Mercy's `canHandOverForMagic()` deliberately returns false when OSSC is installed, so it never opens one of its own vanilla magic windows; but Mercy can keep a spellcaster in `STANCE.Spell` as a warning / waiting posture. The vanilla engine AI can also idle there with a sticky selected spell. That used to make OSSC stand down for the whole fight, even when `Cfg.mercyDriving` was false because Mercy's `combatState` was `NO_STATE`. OSSC now negotiates an explicit one-cast window instead of fighting over stance or attack input: when a Mercy interface exists, `I.MercyCAO.combatEnabled('OSSC_QuickCast', false)` stops Mercy's Combat / CombatAux trees (it keeps the current stance and writes no attack), and OSSC temporarily presents the exact fields Mercy's own `updateOSSCHold()` reads as an uncommitted `FIGHT` so Mercy releases its `I.OSSC_Caster.pause('MercyCAO')` through its normal code path. `M.canYield()` is deliberately broader than `M.isActive()`, so a NO_STATE Mercy interface can still be yielded. Without a Mercy interface, the same window runs as a **local takeover**. In both cases OSSC clears the stale selected castable, swaps to `STANCE.Weapon`, uses the ordinary player-like blended quick-cast, and then either `endYield()` restores Mercy's saved state / Spell posture (Mercy yield) or keeps Weapon stance and the stripped engine spell list (local takeover). The yield is reasserted every frame, extended to the cast deadline, and bounded by short prepare / armed timeouts. A real engine cast cycle — opened by one of the nine `spellcast` Start / Release / Stop text keys and closed by `SpellCast Unequip Stop` — is detected by `Combat.realVanillaSpellcastActive()` and always wins: no window is opened while the engine owns the temporarily restored spell list. Pause-resume graces are armed only during that cycle, never for a bare Spell posture, equip/idle spellcast animation or sticky selected castable. External pauses, death / ineligibility, combat end, save/load, watchdog timeout and every cast-cleanup path hand the body back. The same window (including the local takeover) is used by `ossc_actor_items.lua` for enchanted-item / scroll quick-casts. The local `I.OSSC_Caster` interface exposes `isMercyQuickcastWindow()` and `mercyQuickcastWindowStage()` for diagnostics.
- **Spell cache reconciliation:** `types.Actor.spells()` can be empty or return plain record-id strings at the moment the actor script attaches — Mercy CAO and other mods add spells at combat start with deferred `add()` calls. The shared classifier now decodes spell records, id strings and id-keyed entries; the local caster re-reads the live list once per second and on the first tactical poll, so a late spell add is learned instead of leaving `cached 0 castable spells` for the whole fight. An empty cache never marks the engine list as stripped or clears its selected castable. With `NPCQuickCastDebugLog` on, the heartbeat now reports a human-readable `stance`, plus `spells`, `stripped`, `enabled`, `maxDist`, `nextAction`, `mercyDriving`, `window`, `windowStage`, `realCast`, `castCycle`, `unequipWait`, `castKey`, `bareFor`, `vanillaLeft` and `vanillaDodged`, and a throttled `CAST GATE` line names the exact reason an evaluation was skipped (`vanilla cast allowance — waiting for the engine to finish N more vanilla cast(s)` among them). `Vanilla spellcast key ignored: <key> — OSSC owns the spell list, quick-casts only` names every key that was discarded in quick-cast mode. `Vanilla cast allowance armed/closed` and `Vanilla cast N started` lines trace the hand-back budget (the close line names the real reason: `budget spent`, `timed out`, or `not readied` when the engine never entered Spell stance) (the armed line reports how many spells were handed to the engine, whether the list had been stripped by OSSC, the rolled count and the `min-max` it came from; `vanillaRoll` duplicates the roll in the heartbeat). `Vanilla cast window: re-added N spell(s) to the actor …` appears whenever the list had to be repaired mid-window. `Vanilla spellcast key:` lines show which real key opened the cycle and whether `SpellCast Unequip Stop` closed it.
- **Creature eligibility:** Biped creatures quick-cast with the full NPC/humanoid animation + hand-VFX implementation. Non-biped creatures with at least one regular Spell (Powers only when **Allow Quick-Casting Powers** is on; passive Abilities never count) are eligible while **Enable Non-Biped Creature Quick-Casting** is on: their casts are timer-driven with cast sound + body swirl only — no cast animation is attempted and no hand-anchored VFX (element ball, hand glow, shield ghost) is spawned, because those skeletons have neither the animation groups nor the `Bip01 L Hand` bone. Flipping any creature toggle mid-combat stops new casts immediately and detaches the scripts through the normal safe-detach protocol.
- **NGarde parry block:** With **Block Quick Cast During NGarde Parry** on (default), exclusion works in both input orders: an active/winding guard blocks cast startup, and a cast already in progress sets NGarde's external parry-control state so a weapon guard cannot be raised over it. The state is released on every cast completion/interruption/load path.
- **Swimming gate (vanilla parity):** With **Block Target Spell Quick Casts While Swimming** on (default), a quick-cast whose effects include a Target range and that is released while the caster is swimming always fails, exactly like vanilla: the cast gesture plays, the magicka paid at animation start stays consumed, and the spell fizzles at the release moment with the vanilla "Spell Failure" sound — no projectile, no message, no skill XP, no power cooldown. "Swimming" uses the engine's own test (`types.Actor.isSwimming` — water level above `fSwimHeightScale`, ≈ 0.9 of the actor's height), so it only applies when the whole body is in the water: wading with just feet wet never triggers the rule. Self and Touch spells remain fully castable while swimming. Applies to the player; NPCs and eligible creatures still refuse these casts outright before any cost is paid. The bundled Spell Framework Plus keeps enforcing the same rule at the launch layer (`SettingsMagExp_General.BlockTargetSpellsWhileSwimming`, default on), so any Target spell that reaches `launchSpell` from a swimming caster is refused there too.
- **Area-effect parity (vanilla parity):** a quick-cast's explosion behaves like the engine's own `CastSpell::explodeSpell`, which the bundled Spell Framework Plus now mirrors: the caster is **never** caught by the blast it produced (a Touch cast detonates on the touched actor, so the caster is always inside that ring — an area Paralyze on touch used to paralyze the player along with the target), and each effect of the cast explodes only if it has an Area of its own, at its own radius, so a zero-area component of a touch spell (Damage Health, say) is no longer sprayed over everyone standing near the target. Self-range area spells still land on their caster — and, as in the engine, also on the other actors inside their ring (Morrowind's Fire Burst), because an application now carries one range type the way `CastSpell::inflict` does — and another actor's blast still hits the player. A mod that genuinely wants a self-centred nova opts back in with `includeCaster = true` (or `userData.includeCaster = true`) on the cast.
- **Free movement, 1H attack blending and safe attack abort (NPCs / eligible creatures):** NPC/creature quick-cast animations use the player script's blended rule and never claim LowerBody, leaving locomotion/root motion active even with a two-handed weapon. Normally LeftArm + RightArm + Torso play at `PRIORITY.Hit`, below a real weapon attack's `PRIORITY.Weapon`. If a 1H / H2H / thrown attack is already playing, or a 1H charge is held (its wind-up parks on a text key and `anim.isPlaying()` is false), the cast switches to **LeftArm-only** so both animations blend: the cast cannot steal the weapon arm, freeze the swing, or disappear behind VFX. Relaxed hands likewise use LeftArm-only, except the right-hand grimoire cast. The same rule is used for actor enchanted-item quick-casts. While the quick-cast owns the hands, heavy-weapon attack plays (two-handed melee, bows, crossbows) are vetoed before they start (`options.skip` in the animation-controller hook) instead of being cancelled mid-swing, and every abort releases the engine attack input (`self.controls.use = NoAttack`) so the engine's character controller can leave its wind-up state on its own. A bare `anim.cancel()` on an AI-driven attack used to strand the upper-body state machine in its wind-up forever — the AI then never released the attack input and the actor never swung again, it could only quick-cast "from time to time". Equip/unequip plays are never vetoed (the engine needs their *equip attach* text key to re-attach the weapon), one-handed and hand-to-hand attacks still blend over the cast, and a self-heal frees actors already dead-locked by an older OSSC build in the same session.

Then it delegates spell launching and impact logic to **Spell Framework Plus** for compatibility with other mods using the same framework.

- **Script state lives in tables, not in file-scope locals:** a Lua chunk is
  compiled as a single function, and a function may hold at most **200 active
  local variables** — a script whose main chunk reaches 201 does not load at all
  (`main function has more than 200 local variables`), which reads in-game as
  "no quick-casting anywhere", with only a line in `openmw.log`. The same rule
  keeps the handlers inside LuaJIT's 60-upvalue budget: every file-scope local a
  function references costs it one upvalue, and the big handlers (`onUpdate`
  especially) reference nearly all of the state. So the cast state machine, the
  settings mirror and the animation tables are grouped into `Cfg` / `Cast` /
  `Anim` / `Combat` / `Vec` / `Spells` in the actor scripts and into `Cfg` /
  `Cast` / `Anim` / `PMM` / `Stance` / `QuickkeyPress` in the player script, and
  new shared state is added as a **field of one of those tables**, not as a new
  `local`. `tools/tests/lua_local_limit_check.lua` pins the budget for every
  script the manifests load.

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

#### Vanilla skill progression

**Skill Progression Mode → `ossc`**, with **Skill Experience Ratio = `1`**,
uses vanilla skill-use gains from the loaded skill records. Content-mod changes
to those records are respected. The ratio is a multiplier (`0` disables gains,
`2` doubles them), **not a percentage of a skill level**. If you previously tuned
this setting to compensate for the old flat-progress formula, reset it to `1`
for vanilla parity.

#### Driving skill progression yourself

**Skill Progression Mode → `none`** means OSSC awards no spellcasting experience
at all, because another mod owns progression. For that mod:

- **`OSSC_SkillProgressSkipped`** — a global event fired for every cast OSSC
  silenced, carrying `{ actor, skillId, spellId, cost }`, so you know
  when to award. It fires only in the `none` mode.
- **`I.OSSC.awardSkillProgress(skillId, opts?)`** — apply the gain you computed,
  from any player script:

```lua
local I = require('openmw.interfaces')

I.OSSC.awardSkillProgress('alteration', { skillGain = 0.9 })   -- raw skill-use points
I.OSSC.awardSkillProgress('destruction')                      -- record gain * SkillExperience ratio
I.OSSC.awardSkillProgress('destruction', { backend = 'external' })  -- NCG / SE / MBSP / SUS
```

`skillGain` uses **raw vanilla skill-use points**, the same units as
`I.SkillProgression.skillUsed` and `core.stats.Skill.record(id).skillGain`.
OSSC converts those points into the normalized `skill.progress` value:

```text
progress added = skillGain / ((base skill + 1) * class factor * specialization factor)
```

The factors come from the loaded GMSTs: major `fMajorSkillBonus` (vanilla
`0.75`), minor `fMinorSkillBonus` (`1`), or miscellaneous `fMiscSkillBonus`
(`1.25`), multiplied by `fSpecialSkillBonus` (`0.8`) when the skill matches the
class specialization. For example, `skillGain = 0.9` at base skill 29, with a
major skill in the class specialization, adds `0.9 / (30 * 0.75 * 0.8) = 0.05`
(**5%**, not 90%). Fortify/drain effects on the modified skill do not change
this requirement.

An explicit `skillGain` is **not** multiplied again by the Skill Experience
Ratio. When omitted, the stat backend uses the record's `skillGain[useType + 1]`
multiplied by that ratio. `useType` accepts `0..3`. With `backend = 'external'`,
OSSC forwards the raw gain (or just the use type if no gain was supplied) to
`I.SkillProgression.skillUsed`, without adding its own award afterward.

Returns `true`, or `false` plus a reason string. At a usage level-up, vanilla
raises one skill level and resets progress to zero (overflow is discarded).
OSSC applies the same behavior, message/sound, and GMST-based attribute and
specialization counters. Only major/minor skills advance character-level
progress; miscellaneous skills still contribute to attribute bonuses. Skills
at 100 and werewolves receive no direct award.

**API compatibility:** `I.OSSC.version` is now **2**. Version 1 interpreted
`skillGain` as a fraction of a level; callers must now pass raw skill-use points,
not pre-normalized progress. This intentionally fixes the mismatch with vanilla.

Both the announcement and OSSC's own awards follow the vanilla skill rules (the
engine's `spellIncreasesSkill` / `CastSpell::cast(item)`): a plain spell without
"Always Succeeds" raises its school skill; a CastOnUse ("Cast When Used") item
raises `skillId = 'enchant'`; abilities, powers, "Always Succeeds" spells and
scrolls raise nothing in vanilla and are fully silent — no event, no award. So
`skillId == 'enchant'` unambiguously means a Cast-When-Used item use (it is the
only way a quick-cast raises Enchant) and no separate `isEnchant` flag is
carried — when you see it, award the "Cast When Used" exp. `opts.useType`
defaults the same way (`Enchant_UseMagicItem` for `enchant`,
`Spellcast_Success` otherwise).

The bundled Spell Framework Plus exposes analogous hooks
(`MagExp_SkillProgressSkipped` and `I.MagExp_Player.awardSkillProgress`). Its
separate API/formula is unchanged by this OSSC correction; see its README for
its units.

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

The snapshot carries every key of the group: `NPCQuickCastEnabled`,
`NPCQuickCastCreatures`, `NPCQuickCastNonBipedCreatures`,
`NPCQuickCastDebugLog`, `NPCQuickCastAllowPowers`, `NPCQuickCastRandomAnims`,
`NPCQuickCastPollInterval`, `NPCQuickCastBaseChance`,
`NPCQuickCastMinDistance`, `NPCQuickCastMaxDistance`,
`NPCQuickCastHealThreshold`, the touch-band weights
`NPCQuickCastTouchChance` and `NPCQuickCastTouchTargetChance`, and
`NPCQuickCastCooldownMin` / `NPCQuickCastCooldownMax`.

Tactical selection uses a strict priority order. Below **Spells Healing
Threshold**, a known Self heal is always cast first, at any range. Otherwise,
the actor casts each Self buff that is not already active before choosing an
attack spell. An active buff is never re-cast: this includes reduced
Spell Framework Plus quick-cast copies, and the actor waits until its Self
effects have ended before considering that buff again. Restore Fatigue is
maintenance, not a buff: a spell carrying that effect is only considered while
the actor's fatigue is strictly below 50%, and at or above the gate it is left
out of every pool entirely (a mixed spell that also carries a Self
Restore Health effect is still governed by the healing threshold). After the
buffs are
active, an in-range Touch spell or a Target spell is selected; outside vanilla
touch reach, only Target spells are eligible. A Target spell can be aimed at
**any live engine Combat target the actor has line of sight to**, not only at
the single active package target: `I.AI.getTargets('Combat')` supplies the
candidate pool and both an eye-level sight ray and a projectile-spawn ray must
be clear. The touch check follows vanilla
GMSTs (`fCombatDistance × fHandToHandReach`, capped by `iMaxActivateDist` and
checked for contact/cone/LOS), so an actor can cast a ranged spell instead of
running into touch range. Inside touch reach, `NPCQuickCastTouchChance` and
`NPCQuickCastTouchTargetChance` (defaults 60 / 10) weight Touch versus Target
spells; empty categories drop out. The old `NPCQuickCastRangedBuffChance`,
`NPCQuickCastTouchBuffChance`, and `NPCQuickCastBuffOnlyWhenMissing` options
were retired: buffs now always take priority and are never recast while active,
so saved values from older versions are ignored. The remaining values are live: a
player's change in the settings menu is picked up without a reload (the global
and actor routes read OSSC's settings mirror, synced on load and on every
change; the actor-side copy refreshes once a second).

The random quick-cast cooldown (`NPCQuickCastCooldownMin` / `Max`) governs
offensive spells and heals only — **buffing has no cooldown**. Self buffs are
excluded from it and space themselves a flat 2.2 seconds apart, and the buff
routine opens combat: the first buff cast starts one second after the actor
joins combat (the caster script's re-entry guard, re-armed when combat
resumes), and missing Self buffs ignore the distance-based chance roll so an
enemy does not wait for a lucky roll at range to start buffing. The chance
roll, the configured cooldown and the Touch/Target range and LOS rules still
apply to offensive spells, and heals keep the roll plus the self-only rule.

`getQuickCastFullChanceDistance()` is the convenience read-out of one of those
keys — `NPCQuickCastMinDistance`, the distance at which quick-cast probability
is 100%. NPC/creature quick-cast rolls are distance-based: at or below
**Full Chance Distance** (`NPCQuickCastMinDistance`, default 500) the
probability is at its maximum — 100% with the default **Base Quick-Cast
Probability** — and above it the chance falls linearly to 0% at **Maximum Cast
Distance** (`NPCQuickCastMaxDistance`, default 700). Touch spells are not
tied to either value: an NPC or creature only picks (and only lands) a Touch
spell while the target is within the same vanilla touch reach the player's
quick-cast uses (`fCombatDistance × fHandToHandReach`, the combat angle cone
and the `iMaxActivateDist` cap — `scripts/ossc/ossc_cast_rules.lua`, shared by
the player and the actor scripts). A mod that wants its own
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

## 9. SHOP-Redux (also in this repository)

This repository also ships **SHOP-Redux** — *Store & House Owner Patrol*, an interior
guard / anti-theft AI overhaul for OpenMW, in `shopr/`. It is a separate mod: nothing
in the sections above needs it, and it does not need OSSC.

- **Manifests:** `shopr/shopr.omwscripts` (everything at once), plus the per-module
  `shopr-Core`, `shopr-Blackjacks`, `shopr-Keylocks` and `shopr-Sleep` manifests.
- **Scripts:** `shopr/scripts/shopr/` — `shopr_Global.lua`, `shopr_Player.lua` and the
  `modules/shopr_*.lua` sub-systems, plus `shopr/scripts/shopr_sleep_npc_script*.lua`.
- **Docs:** `shopr/COMPATIBILITY.md` (per-mod compatibility report),
  `shopr/PERIODIC_WORK.md` (what runs on a timer and why),
  `shopr/ACTOR_SCRIPT_LIFECYCLE.md` (the on-demand NPC AI worker).
- **Tests:** the `tools/tests/shop_*.lua` harnesses — see `tools/tests/README.md`.

**SHOP-Redux** is the mod's name in documentation; in code — folder, script paths,
event names (`shopr_StartAIPackage`), storage sections (`shopr_Settings`) and log
prefixes — the identifier is `shopr`. The in-game settings pages keep their existing
titles (`SHOP - Core AI`, `SHOP - Blackjacks`, `SHOP - Keylocks`, `SHOP - Sleep
Spells`), as do the two documented third-party integration events
`SHOP_SleepEffectsChanged` and `SHOP_BlackjackSleepChanged`, which foreign sleep mods
send to SHOP-Redux's NPC scripts.

---

## 10. Credits
- **Mod Author:** skrow42 / Antigravity
- **Animations:** BIG thanks to MaxYari and dubiousnpc for providing the animations for casting. Also Fallchildren for his VFX bone file for spell effects on hands.
- **Physics Engine:** Thanks to MaxYari again for his great physics engine work.
- **Additional Kudos:** Thanks to Moneymitch from OpenMW discord for providing base for the Quick-Keys patch and also Ralts for allowing to use his spellcast formulas

---

## 11. Development & Tests
`tools/tests/` contains regression tests for the QuickKey1-9 hotkey logic shared with paged hotbar mods and for the QuickSelect hotbar itself. They load the real mod scripts against a stubbed OpenMW Lua API and drive them the way the engine does (`input.onInputAction`, `onUpdate`, `onKeyPress`, UI mode changes), so the shipped code paths actually run:

```
sh tools/tests/run_tests.sh
```

The actor quick-cast regressions for this fix are driven by a Python/Lupa harness
that loads the real `scripts/ossc/*.lua` files against a stubbed OpenMW API:

```
python3 tools/tests/run_actor_quickcast_tests.py
```

That runner compiles all 15 mod Lua files and then pins the behaviour above: a
Target spell quick-casts from `I.AI.getTargets('Combat')` even when
`getActiveTarget('Combat')` is nil; the engine's `STANCE.Spell` vetoes actor
spell/item casts and cancels an OSSC cast animation that was already in
flight; a held 1H / H2H charge blends the cast on LeftArm only; LowerBody is
never claimed; LOS blocks offensive casts; and Self buffs still evaluate when
no enemy is visible. See `tools/tests/README.md` for the harness details.

Any Lua 5.1+ interpreter works (`lua`, `lua5.1`, `luajit`, …); when there is none, the runner falls back to `python3` + `lupa` (`pip install lupa`) through `tools/tests/lupa_runner.py`. The suite covers the hotkey-cast decisions (row switch, plain-item slot, empty slot, *Cast on Strike* weapon, repeat press, spell hotkey, manual spell stance), what pays for a cast (a spell's magicka pool versus an enchanted item's **charge**, driven through the safety launch timer that resolves most casts — it must carry the cast's payment verdict, and the cast-chance roll that runs later must not demand the spell's cost a second time from the pool the payment already drained, so a spell cast with exactly its own cost still goes off), the QuickSelect ⇄ OSSC handshake, and the QuickSelect hotbar itself: key names the engine does not know must not raise, summoning a faded-out bar with the row switch keys, fading on world time only (no pop-ins on menu or cell transitions), the QuickLoot input hand-over, the stance / quick-cast holds, the NPC/creature quick-cast blend and attack-abort (a 2H-wielding biped's cast must leave LowerBody/root motion free, and vetoed heavy-attack plays or aborted in-flight attacks must always come with an engine attack-input release), free placement (drag, rotate, lock) and the vertical side anchors, the hand-to-hand slot in the storage layer, the settings menu itself (every setting must name a renderer the engine can resolve, with or without the mod's color-picker menu script, and a lit icon tile must keep its exact box in both border styles), and the Spell Framework Plus projectile pipeline: impacts land on the aim line, and the **Apply Race Weight to Projectile Speed (Normalise Race Speed)** toggle genuinely changes bolt speed (`launchSpell` must multiply by the caster's race weight when the toggle is on and not when it is off), the caster pause (both routes, nested reasons, the on-demand attach and the refusal cases), and the sure-cast rule — abilities, powers and "Always Succeeds" spells launch unrolled under a maxed chance roll, the effect scale reaches an ability and an "Always Succeeds" spell exactly as it reaches a normal spell while a Power lands at full strength, and the fatigue cost and shield slowdown reach every cast, each against a control cast that proves the penalty itself is intact, on the player and on actors alike — and the effect-penalty hand-off end to end: a global sweep may never equip another actor's slot or write its stats — the summon's own local script does it and confirms, the full-strength original is only removed on that confirmation, a reduced twin's enchantment is generated and scaled with it, a quick-cast stand-in is discarded when the same spell is recast at full strength, whatever form the engine reports the id in, a self-range quick cast always names its caster as the source object (Spell Framework Plus rejects a request without one — the drop was silent and made whole self casts never happen), and a dropped conjured bound item returns to the caster's pack with a notice, every time, until the spell ends. The bound-displacement rule is **per equipment slot** (a whole bound set stands at once; two spells that want the same slot replace each other), and the suite pins that: weapon, cuirass, boots, shield, two-handed gauntlets and a modded bound robe all stay active together, a second bound weapon takes only the weapon slot, and an unresolvable modded bound effect takes no slot from anyone. The effect-penalty sweep is **state-based**, and the suite pins that too: over a scene of 20 actors carrying 500 active effects, an unchanged `onUpdate` pass does no record-store reads and no per-entry string allocations (the pre-fix sweep did ~610k `tostring` calls and ~1.22M record reads on that same scene, every pass), one new effect costs one entry's worth of work, the engine is asked for an actor's active spells once per watched actor per pass, and the displacement rule still fires with the crowd standing. See `tools/tests/README.md` for what each harness drives and why. These files are development-only — they are not referenced by any `.omwscripts` manifest and are never loaded by the game.
