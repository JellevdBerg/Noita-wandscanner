"""Checks wandsim.lua against hand-calculated numbers, with a stand-in for Noita's file API."""
import os, sys
from lupa.luajit21 import LuaRuntime

if len(sys.argv) < 2:
    sys.exit("usage: python %s <folder containing the extracted Noita data/ folder>" % sys.argv[0])
DATA = sys.argv[1]
L = LuaRuntime()
def read(path):
    full = os.path.join(DATA, path)
    return open(full, encoding="utf-8", errors="replace").read() if os.path.exists(full) else ""
L.globals().ModTextFileGetContent = read
L.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "wand_scanner", "wandsim.lua")).read())
W = L.globals().WandSim
t = lambda o: L.table_from(o, recursive=True)

bolt = {"cast_delay": 9, "speed_mult": 1, "capacity": 2, "shuffle": False, "mana_charge": 28,
        "spells_per_cast": 1, "recharge": 20, "spread": 0, "mana_max": 90,
        "spells": [{"id": "LIGHT_BULLET", "uses": -1}, {"id": "LIGHT_BULLET", "uses": -1}]}
now = W.dps(t(bolt), t(bolt["spells"]))
assert abs(now - 13.5) < 1e-9, now  # 2 x 3.6 dmg per 32 frames
bomb = {**bolt, "cast_delay": 3, "recharge": 4, "capacity": 1}
b = W.dps(t(bomb), t([{"id": "BOMB", "uses": 3}]))
assert abs(b - 3 * 125 / 10) < 1e-9, b  # 3 bombs, then dry: 375 dmg over the 10 s window

pool = bolt["spells"] + [{"id": "BOUNCY_ORB", "uses": -1}, {"id": "BOMB", "uses": 3}]
run = L.eval("function(f, ...) local co = coroutine.create(f); local args = {...}; "
             "local r; repeat local ok, v = coroutine.resume(co, unpack(args)); assert(ok, v); r = v "
             "until coroutine.status(co) == 'dead'; return r end")
best = run(W.optimize, t(bolt), t(pool), 300, 25, 3)
assert best[1].dps >= now, best[1].dps
print("now", now, "best", best[1].dps, [s.id for s in best[1].spells.values()])
print("lua ok")

assert W.is_physics_explosive("BOMB") and not W.is_physics_explosive("LIGHT_BULLET") \
    and not W.is_physics_explosive("BOUNCY_ORB")
print("explosive filter ok")
