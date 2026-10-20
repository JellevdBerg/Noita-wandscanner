-- Wand Scanner: finds high-DPS spell arrangements for your wands, entirely in-game.
-- Simulation uses Noita's own gun.lua (see wandsim.lua); results show in an overlay.
dofile_once("mods/wand_scanner/wandsim.lua")

local VERSION = "v12" -- shown in the panel title, so you can tell which build is loaded

local INTERVAL = 30        -- frames between inventory checks (~0.5 s)
local EVALS = 1500         -- search steps per wand
local EVALS_PER_FRAME = 3  -- up to ~1 ms each for trigger-heavy builds; keeps the game smooth
local UI_SCALE = 0.8       -- size of the whole overlay; lower = smaller

---------------------------------------------------------------------------
-- Reading the inventory
---------------------------------------------------------------------------
local function child_named(parent, name)
  for _, c in ipairs(EntityGetAllChildren(parent) or {}) do
    if EntityGetName(c) == name then return c end
  end
end

-- One spell card entity -> table (nil if it isn't a spell)
local function read_spell(e)
  local action = EntityGetFirstComponentIncludingDisabled(e, "ItemActionComponent")
  if not action then return nil end
  local spell = { id = ComponentGetValue2(action, "action_id"), entity = e }
  local item = EntityGetFirstComponentIncludingDisabled(e, "ItemComponent")
  if item then
    spell.uses = ComponentGetValue2(item, "uses_remaining") -- -1 = unlimited
    spell.always_cast = ComponentGetValue2(item, "permanently_attached")
    spell.frozen = ComponentGetValue2(item, "is_frozen") -- locked to its wand; never moved
    spell.slot, spell.slot_y = ComponentGetValue2(item, "inventory_slot")
  end
  return spell
end

-- One wand entity -> table with stats + spells in slot order
local function read_wand(e)
  local ab = EntityGetFirstComponentIncludingDisabled(e, "AbilityComponent")
  if not ab then return nil end
  local sprite = EntityGetFirstComponentIncludingDisabled(e, "SpriteComponent")
  local wand = {
    entity          = e,
    name            = ComponentGetValue2(ab, "ui_name"),
    sprite          = sprite and ComponentGetValue2(sprite, "image_file") or "",
    capacity        = ComponentObjectGetValue2(ab, "gun_config", "deck_capacity"),
    spells_per_cast = ComponentObjectGetValue2(ab, "gun_config", "actions_per_round"),
    shuffle         = ComponentObjectGetValue2(ab, "gun_config", "shuffle_deck_when_empty"),
    recharge        = ComponentObjectGetValue2(ab, "gun_config", "reload_time"),
    cast_delay      = ComponentObjectGetValue2(ab, "gunaction_config", "fire_rate_wait"),
    spread          = ComponentObjectGetValue2(ab, "gunaction_config", "spread_degrees"),
    speed_mult      = ComponentObjectGetValue2(ab, "gunaction_config", "speed_multiplier"),
    mana_max        = ComponentGetValue2(ab, "mana_max"),
    mana_charge     = ComponentGetValue2(ab, "mana_charge_speed"),
    spells          = {},
  }
  for i, c in ipairs(EntityGetAllChildren(e) or {}) do
    local s = read_spell(c)
    if s then
      s.child_index = i -- entity order; tiebreaker when slots are missing
      wand.spells[#wand.spells + 1] = s
    end
  end
  -- Freshly generated wands often report slot 0 for every spell until opened in the
  -- inventory, and table.sort isn't stable, so entity order breaks ties.
  table.sort(wand.spells, function(a, b)
    local sa, sb = a.slot or 0, b.slot or 0
    if sa ~= sb then return sa < sb end
    return a.child_index < b.child_index
  end)
  return wand
end

local function scan()
  local player = (EntityGetWithTag("player_unit") or {})[1]
  if not player then return nil end
  local state = { wands = {}, loose = {}, player = player }
  local quick = child_named(player, "inventory_quick")
  for _, e in ipairs(quick and EntityGetAllChildren(quick) or {}) do
    if EntityHasTag(e, "wand") then
      local w = read_wand(e)
      local ids = {}
      for _, s in ipairs(w.spells) do ids[#ids + 1] = s.id end
      w.key = e .. ":" .. table.concat(ids, ",")
      state.wands[#state.wands + 1] = w
    end
  end
  local full = child_named(player, "inventory_full")
  for _, e in ipairs(full and EntityGetAllChildren(full) or {}) do
    local s = read_spell(e)
    if s then state.loose[#state.loose + 1] = s end
  end
  return state
end

---------------------------------------------------------------------------
-- Apply: rearrange real spell entities into a suggested build
---------------------------------------------------------------------------
local function set_slot(e, x, y)
  local item = EntityGetFirstComponentIncludingDisabled(e, "ItemComponent")
  if item then ComponentSetValue2(item, "inventory_slot", x, y) end
end

-- Puts `spells` (in order) on `wand`; spells it no longer uses go to your spell inventory.
-- Returns true, or false + reason without changing anything.
local function apply_build(state, wand, spells)
  local player = state.player
  local full = child_named(player, "inventory_full")
  local inv = EntityGetFirstComponentIncludingDisabled(player, "Inventory2Component")
  if not (full and inv) then return false, "can't find your inventory" end

  local in_build = {}
  for _, s in ipairs(spells) do in_build[s.entity] = true end

  -- Spells leaving this wand (always-cast and frozen ones are part of the wand and stay).
  local evict = {}
  for _, s in ipairs(wand.spells) do
    if not s.always_cast and not s.frozen and not in_build[s.entity] then evict[#evict + 1] = s end
  end

  -- Free cells in the spell inventory, counting cells that build spells will vacate.
  local w, h = ComponentGetValue2(inv, "full_inventory_slots_x"), ComponentGetValue2(inv, "full_inventory_slots_y")
  local taken = {}
  for _, s in ipairs(state.loose) do
    if not in_build[s.entity] then taken[(s.slot or 0) .. "," .. (s.slot_y or 0)] = true end
  end
  local free = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      if not taken[x .. "," .. y] then free[#free + 1] = { x, y } end
    end
  end
  if #evict > #free then return false, "not enough room in your spell inventory" end

  -- Move the build onto the wand, in order. Always-cast spells keep their place.
  for i, s in ipairs(spells) do
    if EntityGetParent(s.entity) ~= wand.entity then
      EntityRemoveFromParent(s.entity)
      EntityAddChild(wand.entity, s.entity)
    end
    set_slot(s.entity, i - 1, 0)
  end
  for i, s in ipairs(evict) do
    EntityRemoveFromParent(s.entity)
    EntityAddChild(full, s.entity)
    set_slot(s.entity, free[i][1], free[i][2])
  end
  ComponentSetValue2(inv, "mForceRefresh", true) -- tell Noita to rebuild the inventory/wands
  return true
end

-- Debug export: the current inventory as JSON, so a wand can be reproduced outside the game.
local EXPORT_PATH = "mods/wand_scanner/state.json"

local function to_json(v)
  local t = type(v)
  if t == "table" then
    local parts = {}
    if #v > 0 or next(v) == nil then
      for _, item in ipairs(v) do parts[#parts + 1] = to_json(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, item in pairs(v) do parts[#parts + 1] = string.format("%q:%s", tostring(k), to_json(item)) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  return "null"
end

local export_reported = false
local function export(state)
  local ok, f, err = pcall(io.open, EXPORT_PATH, "w")
  if ok and f then
    f:write(to_json({ wands = state.wands, loose_spells = state.loose }))
    f:close()
  end
  if not export_reported then -- say once, in the in-game log, whether it worked
    export_reported = true
    GamePrint(ok and f and ("[wand_scanner] inventory exported to " .. EXPORT_PATH)
      or ("[wand_scanner] couldn't write " .. EXPORT_PATH .. ": " .. tostring(ok and err or f)))
  end
end

-- Cheap fingerprint of everything the search depends on, to spot inventory changes.
local function signature(state)
  local parts = {}
  for _, w in ipairs(state.wands) do
    parts[#parts + 1] = table.concat({ w.capacity, w.spells_per_cast, tostring(w.shuffle), w.recharge,
      w.cast_delay, w.mana_max, w.mana_charge }, ",")
    for _, s in ipairs(w.spells) do parts[#parts + 1] = s.id .. ":" .. tostring(s.uses) .. tostring(s.always_cast) end
    parts[#parts + 1] = "|"
  end
  for _, s in ipairs(state.loose) do parts[#parts + 1] = s.id .. ":" .. tostring(s.uses) end
  return table.concat(parts, ";")
end

---------------------------------------------------------------------------
-- Damage meter: real damage from real fights, credited to the wand in your hand.
-- Enemies near you get damage_hook.lua, which reports every hit you cause (piercing
-- ticks, trigger chains, Spells to Power... everything the simulator can't see).
---------------------------------------------------------------------------
local HOOK_RADIUS = 600  -- px around you in which enemies get the hook
local FIRE_GRACE = 60    -- frames after releasing fire that still count (projectiles in flight)
local meter = {}         -- wand key -> { dmg = in-game damage, frames = frames spent firing }
local wand_keys = {}     -- wand entity -> key, from the latest scan
local last_total, grace = nil, 0

local function hook_enemies(player)
  local x, y = EntityGetTransform(player)
  for _, e in ipairs(EntityGetInRadiusWithTag(x, y, HOOK_RADIUS, "enemy") or {}) do
    if not EntityHasTag(e, "wand_scanner_hooked") then
      EntityAddTag(e, "wand_scanner_hooked")
      EntityAddComponent2(e, "LuaComponent", {
        script_damage_received = "mods/wand_scanner/damage_hook.lua",
        execute_every_n_frame = -1, -- only on damage events
      })
    end
  end
end

local function update_meter(player)
  local inv = EntityGetFirstComponentIncludingDisabled(player, "Inventory2Component")
  local controls = EntityGetFirstComponentIncludingDisabled(player, "ControlsComponent")
  local held = inv and wand_keys[ComponentGetValue2(inv, "mActiveItem")]
  if controls and ComponentGetValue2(controls, "mButtonDownFire") then grace = FIRE_GRACE end

  local total = tonumber(GlobalsGetValue("wand_scanner_dmg", "0")) or 0
  local delta = last_total and (total - last_total) or 0
  last_total = total
  if not held then return end
  local m = meter[held] or { dmg = 0, frames = 0 }
  meter[held] = m
  -- shortcut: damage landing after you switch wands is credited to the new wand
  m.dmg = m.dmg + math.max(delta, 0) * 25 -- hooks report damage / 25
  if grace > 0 then
    m.frames = m.frames + 1
    grace = grace - 1
  end
end

local function measured_dps(wand)
  local m = meter[wand.key]
  if not m or m.frames < 30 or m.dmg <= 0 then return nil end -- need half a second of firing
  return m.dmg / (m.frames / 60)
end

---------------------------------------------------------------------------
-- Search, spread over frames with a coroutine
---------------------------------------------------------------------------
local results, progress = nil, nil
local results_state = nil -- the inventory scan the current results were computed from
local recipes = {}        -- known combos you have (or are one spell short of)
local exclude_explosives = false -- toggled from the panel
local exclude_limited = false    -- toggled from the panel: skip spells with limited uses
local job, last_sig = nil, nil

local function search_all(state)
  local pool = {}
  for _, w in ipairs(state.wands) do
    for _, s in ipairs(w.spells) do
      if not s.always_cast and not s.frozen then pool[#pool + 1] = s end
    end
  end
  for _, s in ipairs(state.loose) do pool[#pool + 1] = s end
  local carried = {}
  for _, w in ipairs(state.wands) do for _, s in ipairs(w.spells) do carried[#carried + 1] = s end end
  for _, s in ipairs(state.loose) do carried[#carried + 1] = s end
  local found = WandSim.recipes(carried)
  if exclude_explosives then
    local kept = {}
    for _, s in ipairs(pool) do
      if not WandSim.is_physics_explosive(s.id) then kept[#kept + 1] = s end
    end
    pool = kept
  end
  if exclude_limited then
    local kept = {}
    for _, s in ipairs(pool) do
      if (s.uses or -1) < 0 then kept[#kept + 1] = s end
    end
    pool = kept
  end

  local out = {}
  for i, w in ipairs(state.wands) do
    progress = { i, #state.wands }
    local now = WandSim.dps(w, w.spells)
    local best
    if now == math.huge then
      best = { dps = now, spells = w.spells } -- a working exploit loop: nothing to improve, keep it
    else
      best = WandSim.optimize(w, pool, EVALS, EVALS_PER_FRAME, 1)[1]
    end
    out[i] = { wand = w, now = now, best = best }
  end
  -- The wand that can reach the highest DPS with the spells you're carrying.
  results, progress, results_state, recipes = out, nil, state, found
end

local function step_search()
  if not job then return end
  local ok, err = coroutine.resume(job)
  if not ok then
    print("[wand_scanner] search failed: " .. tostring(err))
    job, progress = nil, nil
  elseif coroutine.status(job) == "dead" then
    job = nil
  end
end

---------------------------------------------------------------------------
-- Overlay: button on the right edge, panel centred at the bottom.
-- Positions come from measured text widths, so nothing overlaps at any scale.
---------------------------------------------------------------------------
local gui = GuiCreate()
local panel_open = false
local S = UI_SCALE
local ICON = 17 * S      -- spacing between spell icons
local LINE = 11 * S      -- text line height
local PAD = 5            -- panel padding
local WAND_COL = 22 * S  -- room for the wand sprite left of each row

local function text(x, y, s) GuiText(gui, x, y, s, S) end
local function text_w(s, scale) return (GuiGetTextDimensions(gui, s, scale or S)) or #s * 5 * (scale or S) end
local function num(v)
  if v == math.huge then return "INF" end
  if v >= 1e15 then return string.format("%.1e", v) end
  for _, u in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e4, "k" } }) do
    if v >= u[1] then return string.format("%.1f%s", v / u[1], u[2]) end
  end
  return string.format("%.0f", v)
end

local function same_build(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i].id ~= b[i].id then return false end end
  return true
end

-- Draws spell icons from x; returns the x where they end.
local function draw_spells(nid, x, y, spells)
  if #spells == 0 then
    text(x, y + 3 * S, "(empty)")
    return x + text_w("(empty)")
  end
  for i, s in ipairs(spells) do
    local a = WandSim.actions[s.id]
    local sx = x + (i - 1) * ICON
    if a and a.sprite then
      GuiImage(gui, nid(), sx, y, a.sprite, 1, S, S)
      local label = GameTextGetTranslatedOrNot(a.name)
      if s.uses and s.uses >= 0 then label = label .. " (" .. s.uses .. " charges)" end
      if s.always_cast then label = label .. " [always cast]" end
      GuiTooltip(gui, label, "")
    else
      text(sx, y + 3 * S, "?")
    end
  end
  return x + #spells * ICON
end

local function draw()
  GuiStartFrame(gui)
  local id = 0
  local function nid() id = id + 1; return id end
  local sw, sh = GuiGetScreenDimensions(gui)

  local open_label = panel_open and "[-] Wands" or "[+] Wands"
  if GuiButton(gui, nid(), sw - text_w(open_label, 1) - 4, sh / 2, open_label) then
    panel_open = not panel_open
  end
  if not panel_open then return end

  -- Measure everything first, then size the panel to fit.
  local rows = results or {}
  local status = progress and string.format("optimizing %d/%d", progress[1], progress[2])
    or (results and "ready" or "waiting for a run")
  local title = "Wands " .. VERSION .. "  -  " .. status
  local toggle = (exclude_explosives and "[x]" or "[ ]") .. " no bombs/TNT"
  local toggle2 = (exclude_limited and "[x]" or "[ ]") .. " no limited uses"
  local w = text_w(title) + 12 + text_w(toggle, 1) + 8 + text_w(toggle2, 1)
  local lines = {}
  for i, r in ipairs(rows) do
    local head = string.format("%s:  %s -> %s DPS", r.wand.name, num(r.now), r.best and num(r.best.dps) or "-")
    local real = measured_dps(r.wand)
    if real then head = head .. "  (real " .. num(real) .. ")" end
    local can_apply = r.best and r.best.dps > r.now and not progress
    local unchanged = not r.best or same_build(r.wand.spells, r.best.spells)
    local head_w = WAND_COL + text_w(head) + (can_apply and (6 + text_w("[apply]", 1)) or 0)
    local note = not r.best and "(nothing to suggest)" or "(already best)"
    local icons_w = WAND_COL + (unchanged and text_w(note) or #r.best.spells * ICON)
    w = math.max(w, head_w, icons_w)
    lines[i] = { head = head, can_apply = can_apply, unchanged = unchanged, note = note }
  end
  local recipe_line
  if results and #recipes > 0 then
    local parts = {}
    for _, r in ipairs(recipes) do
      local miss = r.missing[1] and WandSim.actions[r.missing[1]]
      parts[#parts + 1] = r.name .. (miss and (" (need " .. GameTextGetTranslatedOrNot(miss.name) .. ")") or " (ready)")
    end
    recipe_line = "Recipes: " .. table.concat(parts, ", ")
    w = math.max(w, text_w(recipe_line))
  end
  w = w + 2 * PAD
  local BLOCK = LINE + ICON + 5
  local h = 2 * PAD + LINE + 4 + math.max(#rows, 1) * BLOCK + (recipe_line and LINE or 0)
  local x0, y0 = (sw - w) / 2, sh - h - 10

  GuiZSetForNextWidget(gui, 10) -- behind the icons and text
  GuiImageNinePiece(gui, nid(), x0, y0, w, h)

  text(x0 + PAD, y0 + PAD, title)
  if GuiButton(gui, nid(), x0 + w - PAD - text_w(toggle, 1), y0 + PAD - 1, toggle) then
    exclude_explosives = not exclude_explosives
    last_sig, job, results, progress = nil, nil, nil, nil -- re-run the search on the next check
  end
  if GuiButton(gui, nid(), x0 + w - PAD - text_w(toggle, 1) - 8 - text_w(toggle2, 1), y0 + PAD - 1, toggle2) then
    exclude_limited = not exclude_limited
    last_sig, job, results, progress = nil, nil, nil, nil
  end

  -- Best wand = highest reachable DPS, predicted or measured (measured keeps growing mid-fight).
  local best_i, best_v = nil, -1
  for i, r in ipairs(rows) do
    local v = math.max(r.best and r.best.dps or r.now, measured_dps(r.wand) or 0)
    if v > best_v then best_i, best_v = i, v end
  end

  local y = y0 + PAD + LINE + 4
  for i, r in ipairs(rows) do
    local l = lines[i]
    local x = x0 + PAD
    if r.wand.sprite:find("%.png$") then
      GuiImage(gui, nid(), x, y, r.wand.sprite, 1, S, S)
    end
    if i == best_i then GuiColorSetForNextWidget(gui, 1, 0.85, 0.2, 1) end -- best wand in yellow
    text(x + WAND_COL, y, l.head)
    if l.can_apply then
      if GuiButton(gui, nid(), x + WAND_COL + text_w(l.head) + 6, y - 1, "[apply]") then
        local ok, why = apply_build(results_state, r.wand, r.best.spells)
        GamePrint(ok and ("[wand_scanner] applied the best build to " .. r.wand.name)
          or ("[wand_scanner] couldn't apply: " .. why))
        if ok then last_sig, results = nil, nil end -- rescan and re-optimize right away
      end
    end
    local iy = y + LINE -- second line: the suggested build only
    if l.unchanged then
      text(x + WAND_COL, iy + 3 * S, l.note)
    else
      draw_spells(nid, x + WAND_COL, iy, r.best.spells)
    end
    y = y + BLOCK
  end
  if recipe_line then text(x0 + PAD, y, recipe_line) end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
function OnWorldPostUpdate()
  if GameGetFrameNum() % INTERVAL == 0 then
    local state = scan()
    if state then
      wand_keys = {}
      for _, w in ipairs(state.wands) do wand_keys[w.entity] = w.key end
      hook_enemies(state.player)
      local sig = signature(state)
      if sig ~= last_sig then -- inventory changed: start a fresh search
        last_sig = sig
        export(state)
        job = coroutine.create(function() search_all(state) end)
      end
    end
  end
  local player = (EntityGetWithTag("player_unit") or {})[1]
  if player then update_meter(player) end
  step_search()
  draw() -- every frame: Noita's GUI is immediate-mode
end
