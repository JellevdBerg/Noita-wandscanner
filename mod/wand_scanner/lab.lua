-- Lab mode (started by `lab.bat calibrate`): fires fixed builds at a dummy in the real engine and logs
-- damage per second to wand_scanner_data/calibration.csv. Calibration: how noisy is a repeated build,
-- what does the Omega loop look like.
local M = {}

M.FLAG = "mods/wand_scanner/lab_mode.txt" -- written by lab.ps1, removed when the session ends
M.OUT = "wand_scanner_data/calibration.csv" -- relative to the Noita folder (the game's working directory)
local FIRE, TAIL = 600, 60      -- frames of fire, then frames for projectiles still in flight
local SETTLE = 60               -- frames between runs
local MAX_PROJECTILES = 3000    -- watchdog: more than this = runaway, abort the run
local DUMMY_HP = 1e30 / 25      -- DamageModel hp is in-game damage / 25

-- Builds from Thomas's state export (state_omega_tentacle_wand.json).
local BOLT = { name = "Bolt staff", capacity = 2, spells_per_cast = 1, shuffle = false, recharge = 22,
  cast_delay = 13, spread = 0, speed_mult = 1, mana_max = 111, mana_charge = 38,
  spells = { { id = "LIGHT_BULLET" }, { id = "LIGHT_BULLET" } } }
local OMEGA = { name = "Omega loop", capacity = 10, spells_per_cast = 1, shuffle = false, recharge = 20,
  cast_delay = 10, spread = 0, speed_mult = 1, mana_max = 757, mana_charge = 300,
  spells = { { id = "TENTACLE_TIMER" }, { id = "HEAVY_SHOT" }, { id = "SPELLS_TO_POWER" },
    { id = "DIVIDE_3" }, { id = "OMEGA" }, { id = "MISSILE", uses = 19 } } }
M.QUEUE = {}
for rep = 1, 10 do M.QUEUE[#M.QUEUE + 1] = { build = BOLT, rep = rep } end
for rep = 1, 3 do M.QUEUE[#M.QUEUE + 1] = { build = OMEGA, rep = rep } end

function M.active()
  if not io then return false end -- "Allow unsafe mods" off: no lab
  local f = io.open(M.FLAG, "r")
  if f then f:close() end
  return f ~= nil
end

local st -- lab state, set up on the first update after the player exists
local function log_row(row)
  local f = io.open(M.OUT, "a")
  if not f then return end
  f:write(table.concat(row, ","), "\n")
  f:close()
end

local function comp(e, name) return EntityGetFirstComponentIncludingDisabled(e, name) end

-- A fresh wand per build, made the way the game makes wands (cards added before pickup). Rewriting the
-- held wand's cards never changed what it fired (runs 6-7), while a spawned wand fired its own spells
-- once equipped (run 4, after Thomas pressed 1).
local EQUIP_FRAMES = 30 -- frames before each run to get the new wand into your hand
local function make_wand(b, player)
  local x, y = EntityGetTransform(player)
  local w = EntityLoad("mods/wand_scanner/lab_wand.xml", x, y)
  local ab = comp(w, "AbilityComponent")
  ComponentObjectSetValue2(ab, "gun_config", "deck_capacity", b.capacity)
  ComponentObjectSetValue2(ab, "gun_config", "actions_per_round", b.spells_per_cast)
  ComponentObjectSetValue2(ab, "gun_config", "shuffle_deck_when_empty", b.shuffle)
  ComponentObjectSetValue2(ab, "gun_config", "reload_time", b.recharge)
  ComponentObjectSetValue2(ab, "gunaction_config", "fire_rate_wait", b.cast_delay)
  ComponentObjectSetValue2(ab, "gunaction_config", "spread_degrees", b.spread)
  ComponentObjectSetValue2(ab, "gunaction_config", "speed_multiplier", b.speed_mult)
  ComponentSetValue2(ab, "mana_max", b.mana_max)
  ComponentSetValue2(ab, "mana", b.mana_max)
  ComponentSetValue2(ab, "mana_charge_speed", b.mana_charge)
  for i, s in ipairs(b.spells) do
    local card = CreateItemActionEntity(s.id)
    EntitySetComponentsWithTagEnabled(card, "enabled_in_world", false)
    EntityAddChild(w, card)
    local item = comp(card, "ItemComponent")
    ComponentSetValue2(item, "inventory_slot", i - 1, 0)
    if s.uses then ComponentSetValue2(item, "uses_remaining", s.uses) end
  end
  GamePickUpInventoryItem(player, w, false)
  return w
end

-- Put the wand in hand. Setting mActiveItem alone didn't (runs 1-4); clearing mActualActiveItem makes the
-- game redo the equip. Repeated every frame until the game reports it in hand.
local function equip(player, w)
  local inv = comp(player, "Inventory2Component")
  if ComponentGetValue2(inv, "mActualActiveItem") == w then return true end
  ComponentSetValue2(inv, "mActiveItem", w)
  ComponentSetValue2(inv, "mActualActiveItem", 0)
  ComponentSetValue2(inv, "mForceRefresh", true)
  return false
end

local function kill_projectiles()
  for _, p in ipairs(EntityGetWithTag("projectile") or {}) do EntityKill(p) end
end

local function setup(player)
  local x, y = EntityGetTransform(player)
  st = { px = x, py = y - 400, i = 0, frame = -SETTLE } -- in the sky above the spawn: open air
  for _, child in ipairs(EntityGetAllChildren(player) or {}) do
    if EntityGetName(child) == "inventory_quick" then
      for _, item in ipairs(EntityGetAllChildren(child) or {}) do EntityKill(item) end -- lab only: saves are restored after
    end
  end
  local dmg = comp(player, "DamageModelComponent")
  ComponentSetValue2(dmg, "max_hp", 4e6)
  ComponentSetValue2(dmg, "hp", 4e6)
  log_row({ "build", "rep", "second", "damage", "self_damage", "projectiles_peak", "frames", "wall_s",
    "held", "mana_min" })
  GamePrint("[lab] calibration started: " .. #M.QUEUE .. " runs, don't touch anything")
end

local function new_dummy()
  if st.dummy and EntityGetIsAlive(st.dummy) then EntityKill(st.dummy) end
  local d = EntityLoad("data/entities/props/dummy_target.xml", st.px + 100, st.py + 8)
  local dm = comp(d, "DamageModelComponent")
  ComponentSetValue2(dm, "max_hp", DUMMY_HP)
  ComponentSetValue2(dm, "hp", DUMMY_HP)
  EntityAddComponent2(d, "LuaComponent", {
    script_damage_received = "mods/wand_scanner/damage_hook.lua", execute_every_n_frame = -1 })
  st.dummy = d
end

local function finish_bin(force)
  local r = st.run
  if r.bin_frames < 60 and not force then return end
  log_row({ r.job.build.name, r.job.rep, r.second, string.format("%.6g", r.bin_dmg),
    string.format("%.6g", r.bin_self), r.bin_peak, r.bin_frames, string.format("%.3f", os.clock() - r.bin_wall),
    r.bin_held, string.format("%.4g", r.bin_mana) })
  r.second, r.bin_dmg, r.bin_self, r.bin_peak, r.bin_frames, r.bin_wall = r.second + 1, 0, 0, 0, 0, os.clock()
  r.bin_held, r.bin_mana = 0, math.huge
end

-- Fire and aim at the dummy. Pressing fire through ControlsComponent never fired (runs 1-3); forcing it
-- does. Controls stay off, or your real mouse moves the aim (run 5).
local function press(player)
  local c = comp(player, "ControlsComponent")
  local firing = st.frame <= FIRE
  ComponentSetValue2(c, "enabled", false)
  ComponentSetValue2(comp(player, "PlatformShooterPlayerComponent"), "mForceFireOnNextUpdate", firing)
  ComponentSetValue2(c, "mAimingVector", 100, 0)
  ComponentSetValue2(c, "mAimingVectorNormalized", 1, 0)
  ComponentSetValue2(c, "mMousePosition", st.px + 100, st.py)
end

function M.update(player)
  if not st then setup(player) end
  -- Pin the player and the dummy in place, and keep the player alive (self-damage is logged).
  EntitySetTransform(player, st.px, st.py)
  ComponentSetValue2(comp(player, "CharacterDataComponent"), "mVelocity", 0, 0)
  local dmg = comp(player, "DamageModelComponent")
  local lost = (ComponentGetValue2(dmg, "max_hp") - ComponentGetValue2(dmg, "hp")) * 25
  ComponentSetValue2(dmg, "hp", ComponentGetValue2(dmg, "max_hp"))
  if st.dummy then EntitySetTransform(st.dummy, st.px + 100, st.py + 8) end

  local total = tonumber(GlobalsGetValue("wand_scanner_dmg", "0")) or 0
  local delta = (total - (st.last_total or total)) * 25
  st.last_total = total

  st.frame = st.frame + 1
  local r = st.run
  if not r then
    if st.frame < 0 then return end
    st.i = st.i + 1
    local job = M.QUEUE[st.i]
    if not job then
      if not st.done then GamePrint("[lab] calibration done: closing the game"); st.done = true end
      -- Close the game so lab.bat restores your saves; unattended runs need this. Lab saves are thrown away.
      if st.frame > 180 and os and os.exit then os.exit(0) end
      return
    end
    kill_projectiles()
    new_dummy()
    if st.wand then EntityKill(st.wand) end
    st.wand = make_wand(job.build, player)
    st.run = { job = job, second = 1, bin_dmg = 0, bin_self = 0, bin_peak = 0, bin_frames = 0, bin_wall = os.clock(),
      bin_held = 0, bin_mana = math.huge }
    st.frame = -EQUIP_FRAMES
    return
  end
  if st.frame <= 0 then -- equip phase: not timed, not logged
    equip(player, st.wand)
    r.bin_wall = os.clock()
    return
  end

  press(player)
  if ComponentGetValue2(comp(player, "Inventory2Component"), "mActualActiveItem") == st.wand then r.bin_held = 1 end
  r.bin_mana = math.min(r.bin_mana, ComponentGetValue2(comp(st.wand, "AbilityComponent"), "mana"))

  local n = #(EntityGetWithTag("projectile") or {})
  r.bin_dmg, r.bin_self = r.bin_dmg + math.max(delta, 0), r.bin_self + lost
  r.bin_peak, r.bin_frames = math.max(r.bin_peak, n), r.bin_frames + 1
  local runaway = n > MAX_PROJECTILES
  if runaway or st.frame >= FIRE + TAIL then
    finish_bin(true)
    if runaway then log_row({ r.job.build.name, r.job.rep, "WATCHDOG", "", "", n, "", "", "", "" }) end
    kill_projectiles()
    st.run, st.frame = nil, -SETTLE
  else
    finish_bin(false)
  end
end

LabMode = M
return M
