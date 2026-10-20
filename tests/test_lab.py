"""Runs lab.lua's calibration queue against a fake Noita and checks the CSV it writes (bins, watchdog)."""
import csv, os, tempfile
from lupa.luajit21 import LuaRuntime

MOD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "wand_scanner")
os.chdir(tempfile.mkdtemp())  # lab.lua writes relative to the game's working directory
os.makedirs("mods/wand_scanner"); os.makedirs("wand_scanner_data")
L = LuaRuntime()
L.execute(open(os.path.join(MOD, "lab.lua")).read())
lab = L.globals().LabMode
assert not lab.active()
open("mods/wand_scanner/lab_mode.txt", "w").write("calibrate")
assert lab.active()

L.execute(r'''
comps, alive, nextid, frame, projectiles = {}, {}, 100, 0, 0
local function new() nextid = nextid + 1; alive[nextid] = true; return nextid end
function EntityGetFirstComponentIncludingDisabled(e, n)
  local k = e .. ":" .. n; comps[k] = comps[k] or { hp = 4, max_hp = 4 }; return k end
function ComponentGetValue2(c, f) return comps[c][f] end
function ComponentSetValue2(c, f, v) comps[c][f] = v end
function ComponentObjectSetValue2(c, o, f, v) comps[c][o .. "." .. f] = v end
function EntityGetTransform() return 0, 0 end
function EntitySetTransform() end
function EntityLoad() return new() end
function CreateItemActionEntity() return new() end
kids = {}
function EntityAddChild(p, e) kids[p] = kids[p] or {}; table.insert(kids[p], e) end
function EntityRemoveFromParent(e) for _, l in pairs(kids) do for i, k in ipairs(l) do if k == e then table.remove(l, i) end end end end
function EntitySetComponentsWithTagEnabled() end
function GamePickUpInventoryItem() end
function EntityAddComponent2() end
function EntityGetAllChildren(e) local l = {}; for i, k in ipairs(kids[e] or {}) do l[i] = k end; return l end
function EntityGetName() return "" end
function EntityKill(e) alive[e] = nil end
function EntityGetIsAlive(e) return alive[e] == true end
function EntityGetWithTag(t) local l = {}; for i = 1, (t == "projectile" and projectiles or 0) do l[i] = i end; return l end
globals = {}
function GlobalsGetValue(k, d) return globals[k] or d end
function GlobalsSetValue(k, v) globals[k] = v end
function GameGetFrameNum() return frame end
function GamePrint(s) print(s) end
comps["1:Inventory2Component"] = { mActualActiveItem = 0 }
exited = false
os.exit = function() exited = true end
''')
g = L.globals()
ctl = "1:ControlsComponent"
for f in range(1, 30000):
    g.frame = f
    lab.update(1)
    inv = g.comps["1:Inventory2Component"]
    if inv.mActualActiveItem == 0 and inv.mActiveItem:  # the fake engine equips a frame later
        inv.mActualActiveItem = inv.mActiveItem
    held = inv.mActualActiveItem
    c, shooter = g.comps[ctl], g.comps["1:PlatformShooterPlayerComponent"]
    # as in the real game (run 5): forced fire works; aim stays ours only with controls off
    if held and c and c.enabled == False and shooter and shooter.mForceFireOnNextUpdate:  # the fake wand: 4 damage per frame (/25 units)
        g.globals["wand_scanner_dmg"] = str(float(g.globals["wand_scanner_dmg"] or 0) + 4 / 25)
        omega = g.comps["%d:AbilityComponent" % held].mana_max == 757
        g.projectiles = 5000 if omega and f % 700 > 300 else 3
    else:
        g.projectiles = 0

rows = list(csv.reader(open("wand_scanner_data/calibration.csv")))
assert rows[0][:3] == ["build", "rep", "second"], rows[0]
bolt = [r for r in rows[1:] if r[0] == "Bolt staff" and r[1] != "0"]  # rep 0 = probe runs
assert len({r[1] for r in bolt}) == 10, "10 repeats"
first = [r for r in bolt if r[1] == "1"]
assert len(first) == 11 and float(first[1][3]) == 240, first  # 60 frames x 4 damage
assert sum(float(r[3]) for r in first) == 600 * 4 and float(first[0][4]) == 0, first  # damage seen a frame late lands in the tail bin
assert any(r[0] == "Omega loop" and r[2] == "WATCHDOG" for r in rows), "runaway aborted by watchdog"
cards = list(g.kids[g.comps["1:Inventory2Component"].mActiveItem].values())
assert len(cards) == 6, cards  # the last wand carries the Omega build
assert all(r[8] == "1" for r in rows[1:] if r[2] != "WATCHDOG"), "wand in hand in every logged second"
assert [g.comps["%d:ItemComponent" % c].inventory_slot for c in cards] == list(range(6))  # slot x, in order
assert g.exited, "closes the game when done"
print("lab ok")
