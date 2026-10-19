-- wandsim.lua: simulates wands with Noita's own gun.lua and searches for high-DPS builds.
-- gun.lua runs in a private environment (G) so its globals (deck, c, mana, ...) can't
-- clash with other mods, and engine calls it would make are replaced by stand-ins.
local M = {}
local G = setmetatable({}, { __index = _G })

local function read(path)
  local ok, src = pcall(ModTextFileGetContent, path)
  if ok and src and src ~= "" then return src end
end

local loaded = {}
local function env_dofile(path, once)
  if path:find("_generated%.lua$") then return end -- engine bindings; the harness stands in
  if once and loaded[path] then return end
  loaded[path] = true
  local src = read(path)
  if not src then return end -- shortcut: missing helper libs only matter for exotic spells
  local f = assert(loadstring(src, path))
  setfenv(f, G)
  f()
end
G.dofile = function(p) env_dofile(p, false) end
G.dofile_once = function(p) env_dofile(p, true) end

---------------------------------------------------------------------------
-- Stand-ins for the engine side of gun.lua (runs inside G)
---------------------------------------------------------------------------
local function harness()
  ACTION_TYPE_PROJECTILE, ACTION_TYPE_STATIC_PROJECTILE, ACTION_TYPE_MODIFIER = 0, 1, 2
  ACTION_TYPE_DRAW_MANY, ACTION_TYPE_MATERIAL, ACTION_TYPE_OTHER = 3, 4, 5
  ACTION_TYPE_UTILITY, ACTION_TYPE_PASSIVE = 6, 7

  local NUMS = { "fire_rate_wait", "spread_degrees", "damage_projectile_add", "damage_explosion_add",
    "damage_explosion", "damage_electricity_add", "damage_ice_add", "damage_critical_chance",
    "damage_null_all", "explosion_radius", "lifetime_add", "bounces", "gravity", "knockback_force",
    "lightning_count", "pattern_degrees", "screenshake", "dampening", "ragdoll_fx", "gore_particles",
    "material_amount", "trail_material_amount", "action_draw_many_count", "reload_time" }
  local STRS = { "material", "trail_material", "extra_entities", "game_effect_entities" }

  function ConfigGunActionInfo_Init(s)
    for _, k in ipairs(NUMS) do s[k] = 0 end
    for _, k in ipairs(STRS) do s[k] = "" end
    s.speed_multiplier = 1
    s.child_speed_multiplier = 1
    s.friendly_fire = false
  end
  function ConfigGunActionInfo_Copy(src, dst) for k, v in pairs(src) do dst[k] = v end end
  function ConfigGun_Init(g)
    g.actions_per_round = 1; g.shuffle_deck_when_empty = false; g.reload_time = 0; g.deck_capacity = 0
  end
  function ConfigGunShotEffects_Init(e) e.recoil_knockback = 0 end

  local function noop() end
  for _, name in ipairs({ "ConfigGunActionInfo_PassToGame", "ConfigGunShotEffects_PassToGame",
    "SetProjectileConfigs", "OnActionPlayed", "OnNotEnoughManaForAction", "ActionUsed", "LogAction",
    "BaabInstruction", "Reflection_RegisterProjectile", "SetRandomSeed", "print_error",
    "GlobalsSetValue", "EntityInflictDamage", "ComponentSetValue2" }) do
    getfenv(1)[name] = noop
  end
  function ActionUsesRemainingChanged() return true end
  rng_state = 1
  function Random(a, b) -- Park-Miller; exact in doubles, deterministic per run
    rng_state = (rng_state * 16807) % 2147483647
    return a + rng_state % (b - a + 1)
  end
  function GameGetFrameNum() return sim_frame end
  function GetUpdatedEntityID() return 0 end
  function EntityGetWithTag() return {} end
  function EntityGetInRadiusWithTag() return {} end
  function EntityGetComponent() return nil end
  function EntityGetFirstComponent() return nil end
  function EntityGetFirstComponentIncludingDisabled() return nil end
  function EntityGetAllChildren() return nil end
  function EntityGetTransform() return 0, 0 end
  function HasFlagPersistent() return true end
  function GlobalsGetValue(_, d) return d end

  -- Record every projectile with the shot state (c) it belongs to; c keeps mutating
  -- until the shot is done, so reading it afterwards gives the final modifiers.
  -- trig_stack tracks which projectile's trigger we're inside, so payloads know their parent.
  sim_frame, proj_log, trig_stack, last_proj, reload_frames = 0, {}, {}, nil, nil
  function BeginProjectile(f)
    local t = trig_stack[#trig_stack]
    proj_log[#proj_log + 1] = { file = f, state = c, parent = t and t.idx, trig = t and t.kind }
    last_proj = #proj_log
  end
  function EndProjectile() end
  function BeginTriggerTimer() trig_stack[#trig_stack + 1] = { idx = last_proj, kind = "timer" } end
  function BeginTriggerHitWorld() trig_stack[#trig_stack + 1] = { idx = last_proj, kind = "hit" } end
  function BeginTriggerDeath() trig_stack[#trig_stack + 1] = { idx = last_proj, kind = "death" } end
  function EndTrigger() trig_stack[#trig_stack] = nil end
  function StartReload(t) reload_frames = t end

  function sim_cycle(always, max_shots)
    local shots = {}
    for i = 1, max_shots do
      proj_log, trig_stack, reload_frames = {}, {}, nil
      _start_shot(sim_mana)
      for _, id in ipairs(always) do _play_permanent_card(id) end
      _draw_actions_for_shot(true)
      sim_mana = mana -- gun.lua's global after spending
      local p = {}
      for j, e in ipairs(proj_log) do
        local s = e.state
        p[j] = { file = e.file, parent = e.parent, trig = e.trig, dmg_add = s.damage_projectile_add,
          expl_add = s.damage_explosion_add, crit = s.damage_critical_chance,
          elec_add = s.damage_electricity_add, ice_add = s.damage_ice_add, null_all = s.damage_null_all,
          speed = s.speed_multiplier, life_add = s.lifetime_add, spread = s.spread_degrees,
          extra = s.extra_entities }
      end
      shots[i] = { delay = root_shot.state.fire_rate_wait, reload = reload_frames, projectiles = p }
      if reload_frames then break end
    end
    return shots
  end

  function sim_setup(w, deck_ids, uses)
    gun = {}; ConfigGun_Init(gun)
    gun.actions_per_round = w.spells_per_cast
    gun.shuffle_deck_when_empty = w.shuffle
    gun.reload_time = w.recharge
    gun.deck_capacity = w.capacity
    state_from_game = {}; ConfigGunActionInfo_Init(state_from_game)
    state_from_game.fire_rate_wait = w.cast_delay
    state_from_game.spread_degrees = w.spread
    state_from_game.speed_multiplier = w.speed_mult
    _clear_deck(false)
    for i, id in ipairs(deck_ids) do _add_card_to_deck(id, i, uses[i], true) end
    sim_mana = w.mana_max
    rng_state = 1
  end
end
setfenv(harness, G)
harness()
env_dofile("data/scripts/gun/gun.lua")

-- id -> { sprite, name ("$action_..."), type } for the UI
M.actions = {}
for _, a in ipairs(G.actions or {}) do
  M.actions[a.id] = { sprite = a.sprite, name = a.name, type = a.type, mana = a.mana or 10,
    projectile = a.related_projectiles and a.related_projectiles[1] }
end

---------------------------------------------------------------------------
-- Damage: read projectile XMLs (with <Base> inheritance)
---------------------------------------------------------------------------
local function parse_xml(src)
  src = src:gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
  local root = { children = {} }
  local stack = { root }
  for close, name, attrs, selfclose in src:gmatch("<(/?)([%w_%.:]+)(.-)(/?)>") do
    if close == "/" then
      if #stack > 1 then table.remove(stack) end
    else
      local node = { name = name, attr = {}, children = {} }
      for k, v in attrs:gmatch('([%w_%.:]+)%s*=%s*"([^"]*)"') do node.attr[k] = v end
      local parent = stack[#stack]
      parent.children[#parent.children + 1] = node
      if selfclose ~= "/" then stack[#stack + 1] = node end
    end
  end
  return root.children[1]
end

local function child(node, name)
  for _, c in ipairs(node.children) do
    if c.name == name then return c end
  end
end

local proj_cache = {}
local function projectile_stats(path)
  if proj_cache[path] then return proj_cache[path] end
  local merged = { proj = {}, expl = {}, types = {} }
  proj_cache[path] = merged -- set early so a self-referencing Base can't loop
  local src = read(path)
  local root = src and parse_xml(src)
  if not root then return merged end

  local function take(parent)
    if child(parent, "HomingComponent") then merged.homing = true end
    local pc = child(parent, "ProjectileComponent")
    if not pc then return end
    for k, v in pairs(pc.attr) do merged.proj[k] = v end
    for tag, key in pairs({ config_explosion = "expl", damage_by_type = "types" }) do
      local c = child(pc, tag)
      if c then for k, v in pairs(c.attr) do merged[key][k] = v end end
    end
  end
  -- Base file first, then the overrides inside <Base>, then the entity's own components.
  for _, c in ipairs(root.children) do
    if c.name == "Base" then
      local file = c.attr.file or ""
      local b = projectile_stats(file)
      for _, key in ipairs({ "proj", "expl", "types" }) do
        for k, v in pairs(b[key]) do merged[key][k] = v end
      end
      merged.physics = merged.physics or b.physics or file:find("physics") ~= nil
      merged.homing = merged.homing or b.homing
      take(c)
    end
  end
  take(root)
  return merged
end

-- Physics-body projectiles that explode: bombs, TNT, propane tanks... (they fall/roll, not fly).
function M.is_physics_explosive(id)
  local a = M.actions[id]
  if not (a and a.projectile) then return false end
  local st = projectile_stats(a.projectile)
  return st.physics == true and (tonumber(st.expl.damage) or 0) > 0
end

-- Per-hit damage and explosion damage of one projectile, in in-game units.
local function hit_and_expl(p)
  if p.null_all ~= 0 then return 0, 0 end
  local st = projectile_stats(p.file)
  local hit = (tonumber(st.proj.damage) or 0) + p.dmg_add + p.elec_add + p.ice_add
  for _, v in pairs(st.types) do hit = hit + (tonumber(v) or 0) end
  local crit = 1 + 4 * math.min(math.max(p.crit, 0), 100) / 100 -- crits deal 5x; expectation
  local expl = (tonumber(st.expl.damage) or 0) + p.expl_add
  return 25 * math.max(hit, 0) * crit, 25 * math.max(expl, 0) -- data files store damage / 25
end

function M.damage(p) -- single clean hit, no contact model
  local h, e = hit_and_expl(p)
  return h + e
end

---------------------------------------------------------------------------
-- Contact model: what happens after the cast, against one target.
-- The engine damages an overlapping projectile's target EVERY frame unless the projectile
-- dies on contact (or sets damage_every_x_frames / penetrate_entities). Piercing just
-- turns off dying, so a piercing projectile parked inside an enemy hits it every frame,
-- and a hit-trigger on it fires its payload every frame too.
---------------------------------------------------------------------------
M.TARGET_DIST = 100 -- px from the wand to the target
M.TARGET_SIZE = 16  -- px, a typical enemy

local function has(extra, pattern) return (extra or ""):find(pattern) ~= nil end

-- How many damage ticks one projectile lands on the target (expected value).
local function contact(p, spawned_on_target)
  local st = projectile_stats(p.file)
  local homing = st.homing or (has(p.extra, "homing") and not has(p.extra, "anti_homing"))
    or has(p.extra, "autoaim")
  local life = tonumber(st.proj.lifetime) or -1
  if life < 0 then life = M.WINDOW end -- endless
  life = math.max(1, life + (p.life_add or 0))
  local speed = ((tonumber(st.proj.speed_min) or 0) + (tonumber(st.proj.speed_max) or 0)) / 2
    * (p.speed or 1)

  -- Getting there: payloads spawn where their carrier hit (on the target); cast projectiles
  -- must fly TARGET_DIST, and without homing their spread decides the hit chance.
  local travel, chance = 0, 1
  if not spawned_on_target then
    if speed > 0 then travel = M.TARGET_DIST / speed * 60 end -- shortcut: thrown/physics (speed 0) always arrive
    if travel >= life then return 0 end
    if not homing then
      local half = math.deg(math.atan((M.TARGET_SIZE / 2) / M.TARGET_DIST))
      -- modifier/wand spread plus the projectile's own built-in randomness (radians in the XML)
      local spread = math.abs(p.spread or 0) + math.deg(tonumber(st.proj.direction_random_rad) or 0)
      if spread > half then chance = half / spread end
    end
  end

  -- Staying there: dies on contact -> 1 tick; lingering -> a tick every x frames while overlapping.
  local lingers = has(p.extra, "piercing_shot") or st.proj.on_collision_die == "0"
  if not lingers or st.proj.penetrate_entities == "1" then return chance end
  local every = tonumber(st.proj.damage_every_x_frames) or -1
  if every < 1 then every = 1 end
  local overlap
  if homing then
    overlap = life - travel -- homing keeps pulling it back into the target
  else
    overlap = speed > 0 and math.min(life - travel, M.TARGET_SIZE / speed * 60) or (life - travel)
  end
  return chance * math.max(1, overlap / every)
end

-- Total damage of one shot's projectiles, multiplying payloads by how often their trigger fires.
local function shot_damage(projectiles)
  local ticks, mult, total = {}, {}, 0
  for j, p in ipairs(projectiles) do -- parents always come before their payloads
    local m, on_target = 1, false
    if p.parent then
      on_target = ticks[p.parent] > 0 -- payload starts on the target only if its carrier got there
      m = mult[p.parent]
      -- A hit trigger refires on every contact tick; timer/death triggers fire once.
      if p.trig == "hit" then m = m * math.max(1, ticks[p.parent]) end
    end
    ticks[j] = contact(p, on_target)
    mult[j] = m
    local h, e = hit_and_expl(p)
    total = total + m * (h * ticks[j] + e * math.min(1, ticks[j]))
  end
  return total
end
M.shot_damage = shot_damage

---------------------------------------------------------------------------
-- Run a wand for `window` frames and score it
---------------------------------------------------------------------------
M.WINDOW = 600 -- 10 s of sustained fire per build

---------------------------------------------------------------------------
-- Known exploit loops: damage that only exists at runtime, so it can't be simulated.
-- Omega-Tentacle + Spells to Power: Omega recasts the Tentacle, which recasts Omega...,
-- and the Tentacle steals StP's "already eaten" tag, so damage grows until the target dies.
---------------------------------------------------------------------------
function M.infinite_loop(wand, spells)
  local tentacle, omega, stp, cost = nil, nil, false, 0
  for i, s in ipairs(spells) do
    local id = s.id
    if (id == "TENTACLE" or id == "TENTACLE_TIMER") and not tentacle then
      tentacle = i
      cost = cost + M.actions[id].mana
    elseif id == "OMEGA" and not omega then
      omega = i
      cost = cost + M.actions[id].mana
    elseif id == "SPELLS_TO_POWER" and not stp then
      stp = true
      cost = cost + M.actions[id].mana
    end
  end
  -- shortcut: checks presence, order and mana only; other spells could still break the loop in-game
  return tentacle ~= nil and omega ~= nil and stp and tentacle < omega and cost <= wand.mana_max
end

-- spells: list of { id, uses, always_cast }
function M.dps(wand, spells)
  if M.infinite_loop(wand, spells) then return math.huge end
  local deck, uses, always = {}, {}, {}
  for _, s in ipairs(spells) do
    if s.always_cast then
      always[#always + 1] = s.id
    else
      deck[#deck + 1] = s.id
      uses[#uses + 1] = s.uses or -1
    end
  end
  G.sim_setup(wand, deck, uses)
  local frame, total = 0, 0
  for _ = 1, 500 do
    if frame >= M.WINDOW then break end
    local cycle = G.sim_cycle(always, 200)
    if cycle[#cycle].reload == nil then break end -- can't finish a cycle (e.g. charges spent)
    for _, s in ipairs(cycle) do
      total = total + shot_damage(s.projectiles)
      -- A shot waits its cast delay, or the recharge if it ended the cycle.
      local wait = math.max(math.max(s.delay, 0), s.reload or 0)
      frame = frame + wait
      G.sim_frame = frame
      G.sim_mana = math.min(wand.mana_max, G.sim_mana + wand.mana_charge * wait / 60)
    end
  end
  return total / (math.max(frame, M.WINDOW) / 60) -- idle time after running dry still counts
end

---------------------------------------------------------------------------
-- Search: hill climbing with restarts over ordered spell lists.
-- Calls `yield()` every few evaluations so the game can keep running.
---------------------------------------------------------------------------
function M.optimize(wand, pool, evals, yield_every, top)
  local seed = 12345
  local function rand(n) -- 1..n
    seed = (seed * 16807) % 2147483647
    return 1 + seed % n
  end
  local always = {}
  for _, s in ipairs(wand.spells) do
    if s.always_cast then always[#always + 1] = s end
  end
  local cap, cache, count = wand.capacity, {}, 0

  local function score(b)
    local key = {}
    for i, idx in ipairs(b) do key[i] = pool[idx].id .. ":" .. (pool[idx].uses or -1) end
    key = table.concat(key, ",")
    if not cache[key] then
      local spells = {}
      for _, s in ipairs(always) do spells[#spells + 1] = s end
      for _, idx in ipairs(b) do spells[#spells + 1] = pool[idx] end
      cache[key] = { dps = M.dps(wand, spells), build = b }
      count = count + 1
      if count % yield_every == 0 then coroutine.yield() end
    end
    return cache[key].dps
  end

  local function unused(b)
    local used, out = {}, {}
    for _, i in ipairs(b) do used[i] = true end
    for i = 1, #pool do if not used[i] then out[#out + 1] = i end end
    return out
  end

  local function neighbor(b)
    local n = {}
    for i, v in ipairs(b) do n[i] = v end
    local free, moves = unused(n), {}
    if #free > 0 and #n < cap then moves[#moves + 1] = "add" end
    if #free > 0 and #n > 0 then moves[#moves + 1] = "replace" end
    if #n > 1 then moves[#moves + 1] = "remove"; moves[#moves + 1] = "swap" end
    local m = moves[rand(#moves)]
    if m == "add" then
      table.insert(n, rand(#n + 1), free[rand(#free)])
    elseif m == "replace" then
      n[rand(#n)] = free[rand(#free)]
    elseif m == "remove" then
      table.remove(n, rand(#n))
    else
      local i, j = rand(#n), rand(#n)
      n[i], n[j] = n[j], n[i]
    end
    return n
  end

  local function random_build()
    local free, b = unused({}), {}
    for _ = 1, rand(math.min(cap, #pool)) do
      b[#b + 1] = table.remove(free, rand(#free))
    end
    return b
  end

  if #pool == 0 or cap < 1 then return {} end
  local cur, stale = random_build(), 0
  for _ = 1, evals do
    local nxt = neighbor(cur)
    local sn, sc = score(nxt), score(cur)
    if sn >= sc then
      stale = (sn > sc) and 0 or stale + 1
      cur = nxt
    else
      stale = stale + 1
    end
    if stale > 150 then cur, stale = random_build(), 0 end -- stuck on a plateau: restart
  end

  local ranked = {}
  for _, v in pairs(cache) do
    if v.dps > 0 then ranked[#ranked + 1] = v end
  end
  table.sort(ranked, function(a, b) return a.dps > b.dps end)
  local out = {}
  for i = 1, math.min(top, #ranked) do
    local spells = {}
    for _, idx in ipairs(ranked[i].build) do spells[#spells + 1] = pool[idx] end
    out[i] = { dps = ranked[i].dps, spells = spells }
  end
  return out
end

M.G = G -- the simulator's private environment (for debugging)
WandSim = M -- global so init.lua can reach it after dofile_once
