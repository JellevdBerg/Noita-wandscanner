"""Runs the real init.lua frame by frame against a fake Noita (entities + GUI) and checks the overlay."""
import os, sys
from lupa.luajit21 import LuaRuntime

if len(sys.argv) < 2:
    sys.exit("usage: python %s <folder containing the extracted Noita data/ folder>" % sys.argv[0])
DATA = sys.argv[1]
MOD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "wand_scanner")
L = LuaRuntime()
g = L.globals()

def read(path):
    if path.startswith("mods/wand_scanner/"):
        return open(os.path.join(MOD, path.split("/")[-1])).read()
    full = os.path.join(DATA, path)
    return open(full, encoding="utf-8", errors="replace").read() if os.path.exists(full) else ""
g.ModTextFileGetContent = read

L.execute(r'''
-- fake entities: player 1 -> quick 2 (wands 10, 11), full 3 (loose spells)
local names = { [2] = "inventory_quick", [3] = "inventory_full" }
kids = { [1] = {2, 3}, [2] = {10, 11}, [3] = {200, 201}, [10] = {100, 101}, [11] = {110, 111, 112, 113} }
vals = {}
local function wand(e, t) vals["ab"..e] = t; vals["sp"..e] = { image_file = "data/items_gfx/wands/wand_0001.png" } end
wand(10, { ui_name = "Bolt staff", deck_capacity = 2, actions_per_round = 1, shuffle_deck_when_empty = false,
  reload_time = 20, fire_rate_wait = 9, spread_degrees = 0, speed_multiplier = 1, mana_max = 90, mana_charge_speed = 28 })
wand(11, { ui_name = "Good Rapid bolt wand", deck_capacity = 7, actions_per_round = 1, shuffle_deck_when_empty = true,
  reload_time = 27, fire_rate_wait = 2, spread_degrees = 8, speed_multiplier = 1.03, mana_max = 220, mana_charge_speed = 45 })
local function spell(e, id, uses, slot, frozen) vals["ia"..e] = { action_id = id }; vals["it"..e] = { uses_remaining = uses or -1, permanently_attached = false, is_frozen = frozen or false, inventory_slot = { slot or 0, 0 } } end
spell(100, "LIGHT_BULLET"); spell(101, "LIGHT_BULLET")
spell(110, "BOUNCY_ORB"); spell(111, "BOUNCY_ORB"); spell(112, "BOUNCY_ORB")
spell(113, "LIGHT_BULLET", -1, 3, true) -- frozen: must never move
spell(200, "DAMAGE", -1, 0); spell(201, "BOMB", 3, 1)
vals["inv1"] = { full_inventory_slots_x = 4, full_inventory_slots_y = 1, mForceRefresh = false, mActiveItem = 10 }

function EntityGetWithTag(t) return t == "player_unit" and {1} or {} end
function EntityGetAllChildren(e) return kids[e] end
function EntityGetName(e) return names[e] or "" end
tags = {}
function EntityHasTag(e, t)
  if t == "wand" then return e == 10 or e == 11 end
  if t == "player_unit" then return e == 1 end
  return tags[e .. t] == true
end
function EntityAddTag(e, t) tags[e .. t] = true end
function EntityGetTransform() return 0, 0 end
function EntityGetInRadiusWithTag(_, _, _, t) return t == "enemy" and { 500 } or {} end
hooks = {}
function EntityAddComponent2(e, c, f) hooks[#hooks + 1] = { e = e, c = c, f = f } end
globals = {}
function GlobalsGetValue(k, d) return globals[k] or d end
function GlobalsSetValue(k, v) globals[k] = v end
vals["ctl1"] = { mButtonDownFire = false }
function EntityGetFirstComponentIncludingDisabled(e, c)
  local key = ({ AbilityComponent = "ab", SpriteComponent = "sp", ItemActionComponent = "ia", ItemComponent = "it", Inventory2Component = "inv", ControlsComponent = "ctl" })[c]
  return key and vals[key .. e] and (key .. e) or nil
end
function ComponentGetValue2(c, f)
  local v = vals[c][f]
  if f == "inventory_slot" then return v[1], v[2] end
  return v
end
function ComponentSetValue2(c, f, a, b) vals[c][f] = (f == "inventory_slot") and { a, b } or a end
function EntityGetParent(e)
  for p, list in pairs(kids) do for _, k in ipairs(list) do if k == e then return p end end end
  return 0
end
function EntityRemoveFromParent(e)
  local p = EntityGetParent(e)
  for i, k in ipairs(kids[p] or {}) do if k == e then table.remove(kids[p], i); return end end
end
function EntityAddChild(p, e) kids[p] = kids[p] or {}; table.insert(kids[p], e) end
function ComponentObjectGetValue2(c, _, f) return vals[c][f] end
frame = 0
function GameGetFrameNum() return frame end
function GameTextGetTranslatedOrNot(s) return s end

-- fake GUI that records draw calls
calls, click = {}, false
function GuiCreate() return 1 end
function GuiStartFrame() calls = {}; boxes = {} end
function GuiGetScreenDimensions() return 640, 360 end
-- every widget also records its box, so the test can check for overlaps
boxes = {}
local function box(kind, x, y, w, h, label) boxes[#boxes+1] = { kind = kind, x = x, y = y, w = w, h = h, label = label } end
function GuiGetTextDimensions(_, s, scale) return #s * 6 * (scale or 1), 9 * (scale or 1) end
function GuiButton(_, id, x, y, t)
  calls[#calls+1] = ("BUTTON %d,%d %s"):format(x, y, t)
  box("button", x, y, #t * 6, 9, t)
  if click and t:find(click, 1, true) then click = false; return true end
  return false
end
function GuiImage(_, id, x, y, s, a, sx) calls[#calls+1] = ("IMAGE %d,%d %s"):format(x, y, s); box("image", x, y, 16 * (sx or 1), 16 * (sx or 1), s) end
function GuiText(_, x, y, t, scale) calls[#calls+1] = ("TEXT %d,%d %s"):format(x, y, t); box("text", x, y, #t * 6 * (scale or 1), 9 * (scale or 1), t) end
function GuiImageNinePiece(_, id, x, y, w, h) calls[#calls+1] = ("PANEL %d,%d %dx%d"):format(x, y, w, h) end
function GuiColorSetForNextWidget() calls[#calls+1] = "COLOR" end
function GuiTooltip(_, t) calls[#calls+1] = "TOOLTIP " .. t end
function GuiZSetForNextWidget() end
function GamePrint(s) print(s) end
function dofile_once(p) local f = assert(loadstring(ModTextFileGetContent(p), p)); f() end
''')
L.execute(read("mods/wand_scanner/init.lua"))
L.execute('WandSim.RECIPES = { { name = "Test combo", parts = { "DAMAGE", { "BOMB" }, "OMEGA" } } }')  # one spell short

calls = lambda: list(g.calls.values())
g.OnWorldPostUpdate()
first = calls()[0]
assert first.startswith("BUTTON") and "[+] Wands" in first and first.split()[1].endswith(",180"), first  # right edge, middle
g.click = "Wands"  # open the panel so its status line shows progress
for f in range(1, 5000):  # run until the search finishes
    g.frame = f
    g.OnWorldPostUpdate()
    if f > 30 and any("ready" in c for c in calls()):
        break
frames_used = f

def check_layout():
    out = calls()
    bx = [b for b in g.boxes.values()]
    for i, a in enumerate(bx):  # nothing may overlap anything else
        for b in bx[i + 1:]:
            if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h:
                raise AssertionError(f"overlap: {a.kind} '{a.label}' and {b.kind} '{b.label}'")
    panel = next(c for c in out if c.startswith("PANEL"))
    x, y = map(float, panel.split()[1].split(","))
    w, h = map(float, panel.split()[2].split("x"))
    assert abs((x + w / 2) - 320) <= 1 and y + h <= 360, panel  # centred, at the bottom
    for b in bx[1:]:  # everything except the open/close button sits inside the panel
        assert x <= b.x and b.x + b.w <= x + w + 0.5 and y <= b.y and b.y + b.h <= y + h + 0.5, (b.kind, b.label, panel)
    return out

out = check_layout()
print("\n".join(out))
assert any(c.startswith("TEXT") and "Wands v" in c for c in out)
assert any("Recipes: Test combo (need $action_omega)" in c for c in out)
assert "COLOR" in out and any(c.startswith("TOOLTIP") for c in out)
print(f"\nlayout ok, no overlaps (search finished in ~{frames_used} frames)")

# Toggle "no bombs/TNT": Bomb must disappear from every suggested build.
g.click = "no bombs"
for f in range(f + 1, f + 5000):
    g.frame = f
    g.OnWorldPostUpdate()
    if any("[x] no bombs" in c for c in calls()) and any("ready" in c for c in calls()):
        break
out = check_layout()
assert not any("bomb.png" in c for c in out), [c for c in out if "bomb.png" in c]
print("toggle ok")

# Apply: click the first "[apply]" and check the real entities moved into the suggested order.
btn = next(c for c in out if c.startswith("BUTTON") and "[apply]" in c)
by = float(btn.split()[1].split(",")[1]) + 1  # the button sits 1px above its row's text
header = next(c for c in out if c.startswith("TEXT") and abs(float(c.split()[1].split(",")[1]) - by) < 1)
wand_entity = 10 if "Bolt staff" in header else 11
icons = [c for c in out if c.startswith("IMAGE") and "gun_actions" in c
         and 0 < float(c.split()[1].split(",")[1]) - by < 20]
suggested = [os.path.basename(c.split()[2])[:-4].upper() for c in icons]
g.click = "[apply]"
g.OnWorldPostUpdate()
ids = lambda e: [g.vals["ia%d" % k].action_id for k in sorted(g.kids[e].values(),
                 key=lambda k: g.vals["it%d" % k].inventory_slot[1])]
on_wand = [i for i in ids(wand_entity)]
if wand_entity == 11:
    on_wand = [g.vals["ia%d" % k].action_id for k in sorted(g.kids[11].values(), key=lambda k: g.vals["it%d" % k].inventory_slot[1]) if k != 113]
print("suggested:", suggested, " now on wand:", on_wand, " loose:", ids(3))
assert on_wand == suggested, (on_wand, suggested)
assert 113 in list(g.kids[11].values()), "frozen spell moved"
assert g.vals["inv1"].mForceRefresh is True
assert sum(len(g.kids[e]) for e in (3, 10, 11)) == 8  # nothing lost or duplicated
print("apply ok")

# Damage meter: an enemy gets the hook; "fire" for a second while the hook reports a huge hit.
assert any(h.c == "LuaComponent" and "damage_hook" in h.f.script_damage_received for h in g.hooks.values())
hook_env = L.eval("function(src) local env = setmetatable({}, {__index = _G}); local f = assert(loadstring(src)); setfenv(f, env); f(); return env end")(
    open(os.path.join(MOD, "damage_hook.lua")).read())
g.vals["inv1"].mActiveItem = 11          # holding the second wand
g.vals["ctl1"].mButtonDownFire = True
for k in range(90):
    g.frame += 1
    if k == 10:
        hook_env.damage_received(4e28, "", 1, False, 0)   # 1e30 in-game damage, like the Omega loop
        hook_env.damage_received(5.0, "", 999, False, 0)  # someone else's damage: ignored
    g.OnWorldPostUpdate()
out = calls()
row = next(c for c in out if c.startswith("TEXT") and "(real " in c)
print(row)
assert "e+" in row, row  # 1e30 shown compactly
i = out.index(row)
assert out[i - 1] == "COLOR", "the wand with the huge measured damage should be highlighted as best"
assert "Bolt staff" not in row
print("meter ok")
