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
function EntityAddChild() end
function EntitySetComponentsWithTagEnabled() end
function GamePickUpInventoryItem() end
function EntityAddComponent2() end
function EntityGetAllChildren() return {} end
function EntityGetName() return "" end
function EntityKill(e) alive[e] = nil end
function EntityGetIsAlive(e) return alive[e] == true end
function EntityGetWithTag(t) local l = {}; for i = 1, (t == "projectile" and projectiles or 0) do l[i] = i end; return l end
globals = {}
function GlobalsGetValue(k, d) return globals[k] or d end
function GlobalsSetValue(k, v) globals[k] = v end
function GameGetFrameNum() return frame end
function GamePrint(s) print(s) end
exited = false
os.exit = function() exited = true end
''')
g = L.globals()
ctl = "1:ControlsComponent"
for f in range(1, 30000):
    g.frame = f
    lab.pre_update(1)
    lab.update(1)
    c, shooter = g.comps[ctl], g.comps["1:PlatformShooterPlayerComponent"]
    # pretend only forced fire with controls on works (unknown in the real game)
    if c and c.enabled and shooter and shooter.mForceFireOnNextUpdate:  # the fake wand: 4 damage per frame (/25 units)
        g.globals["wand_scanner_dmg"] = str(float(g.globals["wand_scanner_dmg"] or 0) + 4 / 25)
        omega = g.comps["1:Inventory2Component"].mActiveItem >= 130  # the Omega runs come last
        g.projectiles = 5000 if omega and f % 700 > 300 else 3
    else:
        g.projectiles = 0

rows = list(csv.reader(open("wand_scanner_data/calibration.csv")))
assert rows[0][:4] == ["build", "rep", "method", "second"], rows[0]
bolt = [r for r in rows[1:] if r[0] == "Bolt staff" and r[1] != "0"]  # rep 0 = probe runs
assert len({r[1] for r in bolt}) == 10, "10 repeats"
first = [r for r in bolt if r[1] == "1"]
assert all(float(r[4]) == 0 for r in rows[1:] if r[2] == "force_disabled"), "probe that doesn't fire logs nothing"
assert len(first) == 11 and float(first[1][4]) == 240, first  # 60 frames x 4 damage
assert sum(float(r[4]) for r in first) == 600 * 4 and float(first[0][5]) == 0, first  # damage seen a frame late lands in the tail bin
assert any(r[0] == "Omega loop" and r[3] == "WATCHDOG" for r in rows), "runaway aborted by watchdog"
assert all(r[2] == "force" for r in rows[1:] if r[0] == "Omega loop"), "queue uses the first method that fired"
assert g.exited, "closes the game when done"
print("lab ok")
