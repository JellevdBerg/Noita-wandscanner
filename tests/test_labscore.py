"""Checks labscore.lua (lab ranking that replaces the INF rule) on synthetic damage curves."""
import os
from lupa.luajit21 import LuaRuntime

L = LuaRuntime()
L.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "wand_scanner", "labscore.lua")).read())
S = L.globals().LabScore
t = lambda o: L.table_from(o)

plain = S.score(t([500] * 10))                      # 500 dps for 10 s
loop = S.score(t([10.0 ** (3 * i) for i in range(1, 11)]))  # x1000 per second, like Omega/Tentacle/StP
burst = S.score(t([2e6] + [0] * 9), 50)             # one big hit, then dry, hurts the player

assert plain.tier == 1e3 and plain.time == 2 and plain.censored and not plain.runaway, dict(plain)
assert loop.tier == 1e30 and loop.time == 10 and not loop.censored and loop.runaway, dict(loop)
assert burst.tier == 1e6 and not burst.runaway and burst.self_damage == 50, dict(burst)

assert S.better(loop, burst) and S.better(burst, plain) and not S.better(plain, loop)
faster = S.score(t([10.0 ** (4 * i) for i in range(1, 11)]))
assert S.better(faster, loop)                       # same top tier, reached sooner
safe = S.score(t([2e6] + [0] * 9))
assert S.better(safe, burst)                        # same damage, no self-damage
print("labscore ok")
