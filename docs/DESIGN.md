# Design notes

## Files

| File | Role |
|---|---|
| `mod/wand_scanner/init.lua` | Scans the inventory, schedules the search, damage meter, overlay, [apply], `state.json` export |
| `mod/wand_scanner/wandsim.lua` | Simulator: runs `gun.lua` in a private environment, damage/contact model, exploit rules, search |
| `mod/wand_scanner/damage_hook.lua` | Added to nearby enemies; reports damage the player causes via a game global |
| `mod/wand_scanner/mod.xml` | Mod manifest (`request_no_api_restrictions="1"`) |

## Simulation

- `gun.lua` and `gun_actions.lua` are loaded from the game's virtual file system into a private Lua
  environment (`loadstring` + `setfenv`), so their globals (`deck`, `c`, `mana`, …) can't clash with
  other mods. `*_generated.lua` files are skipped; a harness stands in for the engine calls
  (`BeginProjectile`, triggers, `StartReload`, config init/copy, RNG, entity queries).
- Each projectile is recorded with the shot state `c` it belongs to (read after the shot finishes,
  so it carries the final modifiers) and the trigger that spawned it (`hit`/`timer`/`death`).
- A build is scored on **10 s of sustained fire** (`M.WINDOW = 600` frames): mana regenerates,
  limited-use spells run out, and a wand that runs dry still pays for the idle time.

## Damage model

- Projectile stats come from the projectile XMLs, merging `<Base file=…>` inheritance:
  `ProjectileComponent` damage, `damage_by_type`, `config_explosion` damage, lifetime, speed,
  `direction_random_rad`, `on_collision_die`, `penetrate_entities`, `damage_every_x_frames`,
  and a `HomingComponent` if present. Data files store damage / 25.
- Crit chance is applied as an expectation (crits deal 5×), to the hit part only.

### Contact model (one target, `TARGET_DIST` = 100 px, `TARGET_SIZE` = 16 px)

- **Reaching the target**: cast projectiles fly `TARGET_DIST` (must arrive within their lifetime).
  Without homing, hit chance = target half-angle ÷ total spread (modifier/wand spread + the XML's
  built-in randomness). Homing = always hits.
- **Lingering**: per `component_documentation.txt`, `damage_every_x_frames` defaults to -1 = "do
  damage every frame". Piercing (`piercing_shot.lua`) only sets `on_collision_die = 0`, so a piercing
  projectile overlapping the target damages it every frame. With homing it stays for its remaining
  lifetime; without, for one pass (`TARGET_SIZE / speed`). `penetrate_entities = 1` = once per entity.
- **Triggers**: a hit-trigger refires its payload on every contact tick of its carrier; timer and
  death triggers fire once. Payloads start on the target only if their carrier reached it.

### Exploit rules

Damage that only exists at runtime is recognised by rule and scored `INF`:

- **Omega–Tentacle + Spells to Power**: Omega recasts the Tentacle which recasts Omega…; the Tentacle
  steals StP's "already eaten" tag, so damage grows until the target dies. Rule: a `TENTACLE` or
  `TENTACLE_TIMER` before `OMEGA`, `SPELLS_TO_POWER` on the same wand, and enough max mana for the
  three. (Presence + order + mana only.)

### Recipes

`M.RECIPES` lists known runtime combos as spell ids (a list = any one of them). The panel shows
the ones you carry (any wand or loose) or are one spell short of. They also serve as seeds for the
planned discovery search.

### Known limits

- One target at a fixed distance; no terrain, bounces off walls, crowds or bosses.
- Damage over time (fire, poison), status effects and most `extra_entities` effects aren't scored.
- Absolute numbers for trigger/piercing loops are likely too high (assumes every-frame refiring and
  perfect lock-on); use them for ranking, and trust the damage meter for real numbers.
- Shuffle wands are scored on one fixed shuffle order.

## Search

Hill climbing with random restarts over ordered spell lists (add / remove / replace / swap), 1500
steps per wand, cached by build. It runs inside a coroutine, 3 builds per frame. Each wand is
optimized independently from the full pool, so two wands may suggest the same spell. Frozen and
always-cast spells are excluded from the pool. A wand whose current build is already `INF` is kept.

## Damage meter

Every `INTERVAL` frames, enemies within 600 px get a `LuaComponent` with
`script_damage_received = damage_hook.lua` (`execute_every_n_frame = -1`). The hook adds damage
caused by the player (directly, or via a projectile's `mWhoShot`) to the global `wand_scanner_dmg`.
The mod credits the per-frame delta to the held wand (`mActiveItem`), and counts time only while
firing (`mButtonDownFire`, plus 60 frames of grace). Keyed per wand + exact spell order; not saved
between sessions.

## Roadmap

1. **Learning from the meter**: when measured ≫ predicted, learn which spell patterns the simulator
   underrates and bias the search toward them.
2. **Shop advisor**: in a Holy Mountain, "buying this spell takes your best wand from X to Y".
3. **Test bench** (on hold): a second Noita instance in a lab world fires shortlisted builds at a
   dummy and reports measured DPS. Two instances run fine but share `save00` (no option to change
   the save folder), so the bench must run sandboxed, e.g. via Sandboxie-Plus. Still to check:
   whether a sandboxed Noita starts, and whether it keeps simulating while unfocused.

## Lab scoring (`labscore.lua`, not wired in yet)

For builds measured in the real engine. One dummy with ~1e30 HP; damage is logged per second. Rank by the
highest tier of cumulative damage crossed (1e3, 1e6, 1e9, 1e30), then by time to the top tier (or by total
damage when the dummy survived: censored), then by self-damage. `runaway` = damage per second at least
doubled for 3 seconds in a row (thresholds to be refit on calibration data). Test: `tests/test_labscore.py`.
