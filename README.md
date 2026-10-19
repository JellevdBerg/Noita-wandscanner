# Noita Wand Optimizer

An in-game Noita mod that reads your wands and spells, simulates them with the game's own
casting code, and suggests the highest-DPS arrangement for every wand — with one-click apply
and a damage meter that measures what your wands really do in fights.

## Features

- **Live suggestions** — whenever your inventory changes, every wand is re-optimized from all
  spells you carry (on any wand or loose). Runs a few builds per frame, so the game doesn't stutter.
- **Real cast logic** — simulation runs Noita's own `gun.lua` / `gun_actions.lua`, so draw order,
  modifiers, triggers, Divide/Omega etc. behave exactly as in the game. Modded spells too.
- **Contact model** — scores what happens after the cast against one target: piercing projectiles
  re-hitting every frame, hit-triggers re-firing their payload, homing vs. spread accuracy,
  Long Distance Cast payloads spawning at the target.
- **Exploit loops** — known runtime-only loops (Omega–Tentacle + Spells to Power) are recognised and
  scored as `INF`.
- **[apply]** — rearranges your actual spells into the suggested build. Frozen and always-cast
  spells are never moved.
- **Damage meter** — hooks nearby enemies and credits the damage you deal to the wand in your
  hand while firing. Shown as `(real …)`; catches runtime tricks the simulator can't see.
- **No bombs/TNT** toggle — exclude physics-body explosives from suggestions.

## Install

1. Copy `mod/wand_scanner/` into `<Noita install>/mods/` so you get `mods/wand_scanner/init.lua`.
2. Main menu → **Mods** → enable **Wand Scanner** and tick **Allow unsafe mods**
   (needed to load the game's gun code in an isolated environment and for the `state.json` export).
3. Start a run and click **[+] Wands** on the right edge of the screen.

## Using it

Each wand gets two lines: `name: now -> best DPS (real …)  [apply]`, and the suggested spells in
cast order (hover an icon for its name). The best wand is shown in yellow.
`UI_SCALE` at the top of `init.lua` sets the overlay size.

## How it works

See [docs/DESIGN.md](docs/DESIGN.md) for the architecture, the damage/contact model, its known
limits and the roadmap.

## Development

The tests run the real mod code in LuaJIT (via [lupa](https://github.com/scoder/lupa)) against a
fake Noita API. They need the game's data files, which are not included (they're Nolla Games'):
extract them with `tools_modding/data_wak_unpack.bat` from your Noita install, then:

```
pip install lupa
python tests/test_wandsim.py "%USERPROFILE%/AppData/LocalLow/Nolla_Games_Noita"
python tests/test_mod.py     "%USERPROFILE%/AppData/LocalLow/Nolla_Games_Noita"
```

`test_wandsim.py` checks the simulator against hand-calculated numbers; `test_mod.py` runs
`init.lua` frame by frame and checks the overlay (no overlapping widgets), the bombs toggle,
[apply] moving real entities, and the damage meter.
