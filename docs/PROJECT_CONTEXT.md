# Project context (for Claude)

Upload this file (plus the repo's `mod/` files and `docs/DESIGN.md`) as project knowledge.

## What this is

Thomas's Noita mod that suggests the highest-DPS spell arrangement for each wand, fully in-game.
Goal: a tool that "completely blows away wand building". Current version: **v10**.

## Setup on Thomas's PC (Windows)

- Noita install: `D:\SteamLibrary\steamapps\common\Noita` → mod lives in `mods\wand_scanner\`
- Extracted game data: `%USERPROFILE%\AppData\LocalLow\Nolla_Games_Noita\data\`
- Install a new version: delete `mods\wand_scanner\`, extract the zip into `mods\` (the zip
  contains the `wand_scanner` folder — extracting into `mods\wand_scanner\` nests it and the old
  files keep running). The panel title shows the version, e.g. `Wands v10`.
- "Allow unsafe mods" must be on. The mod writes `mods\wand_scanner\state.json` (current
  inventory) on every change — ask for it to reproduce a wand exactly.
- PowerShell: use `$env:USERPROFILE`, not `%USERPROFILE%`.

## How to work on it

- Read `docs/DESIGN.md` first. Tests: `tests/test_wandsim.py` and `tests/test_mod.py` (LuaJIT via
  `lupa`, need the extracted data folder as argument). Run both after every change; `test_mod.py`
  fails on overlapping overlay widgets.
- Bump `VERSION` in `init.lua` with every release so Thomas can tell what's loaded.
- Engine questions: `tools_modding/component_documentation.txt` in the Noita install has every
  component field and default (e.g. `damage_every_x_frames` default -1 = damage every frame).
- Thomas prefers short, direct answers, and testing in-game himself; things that can't be verified
  outside Noita should be called out explicitly.

## Decisions made

- Fully in-game (Lua), no external Python process. Overlay: [+] Wands button at right-middle,
  panel bottom-centre, closed by default, two lines per wand, only the best build shown.
- Score = DPS over 10 s of sustained fire, one target at 100 px, contact model for piercing,
  hit-trigger refiring, homing and spread. Runtime-only exploits are recognised by rule (`INF`).
- Each wand is optimized independently from the full spell pool.
- No spell lab / teleporting in the player's run.

## Open items

1. Verify in game: v9 text scaling (`GuiText` scale argument), v10 damage meter `(real …)`.
2. Learning from the meter (measured vs predicted) and the Holy Mountain shop advisor.
3. Test bench on hold: two instances work but share `save00`; next step would be Sandboxie-Plus
   (does a sandboxed Noita start? does it keep running unfocused?).
