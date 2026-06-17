# Oblivion-Style Spell Casting (OSSC) v2.51

**Oblivion-Style Spell Casting** (OSSC) brings modern spellcasting mechanics to OpenMW. It allows you to cast your currently selected spell (and enchanted item casts) using a dedicated hotkey without needing to switch to spell stance, similar to TES IV: Oblivion.

---

## 1. Features
- **Dedicated Casting Key:** Quickly cast the currently selected spell using a single button (unset by default—bind it in settings). Gamepad compatible.
- **Per-School / Per-Range / Per-Perspective Animation Selection:** Choose a different animation for each **magic school** × **cast type** (Self/Touch/Target) × **camera** (1st/3rd person).
- **Configurable Animation Speeds:** Adjust speed per animation group and apply a global scale multiplier.
- **Casting VFX Options:** Toggle player swirl, hand swirl (element ball), and hand glow effects.
- **Snap Sound Control:** Optional snap animation sound with a configurable volume slider (0.0–1.0), timed to the animation.
- **Physics-Based Projectiles:** Spells are launched as real world objects via **Spell Framework Plus**, supporting collision and physics behavior.
- **Enchanted Item Casting Support:** Casting from selected enchanted items is supported and uses the same school/range/perspective animation selection logic.
- **Safety / Anti-Spam Reliability:** Input is ignored while a cast is still playing; unlock occurs on animation stop (with a configurable safety-unlock timer fallback).

---

## 2. Requirements
To run OSSC, the following must be enabled:
1. **Spell Framework Plus** — provides spell launch / projectile / impact logic.

Also required:
- **OpenMW 0.51RC1+**.

---

## 3. Installation
1. Install OSSC.
2. Ensure OSSC is enabled in your OpenMW mod list.
3. Ensure **Spell Framework Plus** is installed and enabled.
4. Enjoy

---

## 4. Usage & Keybindings
- **Cast Key:** Press your assigned key to cast the currently selected spell. This system exists next to vanilla casting, not replacing it.
- **Rebinding:**  
  `ESC → Options → Scripts → Oblivion-Style Spell Casting`  
  Click **Quick Cast** and press any key/button to bind.

Notes:
- Casting is locked until the animation reaches its **stop** text key (prevents spam bugs and “delayed next cast” issues).
- If the player is knocked down/knocked out, casting will remain locked until recovery animations finish.

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
- **Use Fatigue** (optional fatigue usage on casting)
- **Quick Cast Chance Penalty** (optional failure chance multiplier)

### Snap Sound
- **Snap Sound Volume (0.0–1.0)**  
  Controls the volume of the snap sound used by the `qcsnap` animation group.  
  Sound timing is driven by the animation so it stays consistent and doesn’t retrigger during spam.
  Setting to 0.0 mutes the sound.

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
- Cast success logic (optional fatigue + chance penalty)

Then it delegates spell launching and impact logic to **Spell Framework Plus** for compatibility with other mods using the same framework.

---

## 8. Credits
- **Mod Author:** skrow42 / Antigravity
- **Animations:** BIG thanks to MaxYari and dubiousnpc for providing the animations for casting. Also Fallchildren for his VFX bone file for spell effects on hands.
- **Physics Engine:** Thanks to MaxYari again for his great physics engine work.

---
