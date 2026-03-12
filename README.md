## CRPM — Clarity Roleplaying Mechanics

I made this for my guild, <Clarity>

---

### Overview  
CRPM is a lightweight WoW addon for roleplayers who want a simple way to roll dice and apply character modifiers without dragging in a giant RP suite.

Roll dice, add modifiers, share the result.

You can make very simple character sheets, define whatever attributes your RP uses, and roll from those stats directly. No assumptions.

---

### Features
- Roll standard dice like d20, 2d6, 3d8+5, and more complicated formulas too
- Use your own custom attributes for bonuses and penalties
- Keep simple per-character sheets in a small movable window
- Roll directly from chat commands or from the sheet UI
- Call for rolls for your group
- Store the last roll call so players can use /crpm lastcall
- Share rolls with your party, raid, instance group, or a custom channel that starts with CRPM
- Inspect another player’s sheet, including cross-realm players


CRPM is meant to stay small and focused. There are already addons for broader RP stuff. This one is for dice and modifiers.

---

### Commands

```
/crpm sheet
    Open your character sheet

/crpm roll <expr>
/crpm r <expr>
    Roll dice
    Example: /crpm roll 2d6+Strength

/crpm call <expr>
    Call for a roll from your group or CRPM channel

/crpm lastcall
/crpm lc
    Roll the last call you received

/crpm inspect [name]
    Inspect another player's sheet
    If no name is given, it tries your current target

/crpm help
    Show command help
```

---

### Examples

```
/crpm r d20+Might
/crpm r 2d6+Swordplay
/crpm r 3d6+(2*Will)
/crpm call d20+Courage
/crpm inspect
```

---

### A couple notes:
- The name on your CRPM sheet is the name that prints in CRPM chat output.
- Attribute names are custom, but for parser sanity they should be kept expression-friendly.
- If you want to use CRPM outside of a party or raid, join a custom channel whose name starts with CRPM.


### AI Notice
Parts of this addon were reviewed, edited, and rewritten by AI.

[CurseForge Project Page](https://www.curseforge.com/wow/addons/crpm)

This project is licensed under GPL‑3 — you’re free to use, modify, and share it, but derivative work must stay under the same license. Read the full license [here](https://www.gnu.org/licenses/gpl-3.0.html).
