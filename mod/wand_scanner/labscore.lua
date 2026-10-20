-- Scores a build from damage measured in the lab, so runaway loops rank without a hard-coded INF rule.
-- Input: `bins` = damage dealt in each 1-second bin of the test window (one dummy with ~1e30 HP).
local M = {}

M.TIERS = { 1e3, 1e6, 1e9, 1e30 }
M.RUNAWAY_BINS = 3   -- shortcut: thresholds are guesses, refit on the R1.6 calibration data
M.RUNAWAY_FACTOR = 2

-- Returns { tier, time, censored, runaway, total, self_damage }:
-- tier = highest ladder tier the cumulative damage crossed (0 if none), time = second it crossed it,
-- censored = the top tier was never reached (the dummy "survived" the window, so time is a lower bound).
function M.score(bins, self_damage)
  local r = { tier = 0, time = #bins, total = 0, runaway = false, self_damage = self_damage or 0 }
  local rises = 0
  for i, d in ipairs(bins) do
    r.total = r.total + d
    for _, t in ipairs(M.TIERS) do
      if r.total >= t and t > r.tier then r.tier, r.time = t, i end
    end
    -- runaway = damage per second keeps multiplying, bin after bin (exponential or faster)
    if i > 1 and bins[i - 1] > 0 and d >= bins[i - 1] * M.RUNAWAY_FACTOR then rises = rises + 1 else rises = 0 end
    if rises >= M.RUNAWAY_BINS then r.runaway = true end
  end
  r.censored = r.tier < M.TIERS[#M.TIERS]
  return r
end

-- Sort order: highest tier; within the top tier the fastest kill, below it the most damage
-- (the dummy survived both, so total is the fairer measure); then least self-damage.
function M.better(a, b)
  if a.tier ~= b.tier then return a.tier > b.tier end
  if not a.censored and a.time ~= b.time then return a.time < b.time end
  if a.censored and a.total ~= b.total then return a.total > b.total end
  return a.self_damage < b.self_damage
end

LabScore = M -- global, same convention as WandSim
return M
