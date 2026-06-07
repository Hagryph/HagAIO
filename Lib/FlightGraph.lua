local addonName, ns = ...
local Class = ns.Class

-- Lib/FlightGraph.lua
-- Pure solver for ATOMIC FLIGHT-LEG times -- no WoW API. The flight recorder stores each
-- flown segment as an ordered node sequence (a -> ...vias... -> b) with a total time and a
-- quality: a single direct hop is a 2-node sequence (one atomic leg); a span that skipped
-- intermediate stops is longer. Solve() turns that set of (sequence, total) records into
-- the time of each individual atomic leg (an adjacent pair): atomic records seed leg times
-- directly, and any span with exactly one still-unknown leg yields that leg by SUBTRACTION
-- (total minus the known legs), repeated to a fixpoint. This is route-independent -- an
-- atomic leg X->Y is the same physical hop on every trip -- so summing a route's atomic
-- legs never mixes two different ways of reaching the same node.

local FlightGraph = Class.new("FlightGraph", ns.Lib)

local SEP = "\31"  -- unit-separator: never appears in a flight-point name
local function legKey(a, b) return a .. SEP .. b end

-- Solve atomic-leg times from segment records. Each record is
--   { seq = { n1, ..., nk }, t = seconds, q = quality }   (higher q = better measurement)
-- Returns a map legKey(a,b) -> { t = seconds, q = quality, derived = bool } for every
-- atomic leg known directly (derived=false) or recovered by subtraction (derived=true).
function FlightGraph:Solve(records)
    local legs = {}
    -- Seed: a 2-node record IS an atomic leg; keep the best-quality measurement per leg.
    for _, r in ipairs(records or {}) do
        if r.seq and #r.seq == 2 and r.t then
            local k = legKey(r.seq[1], r.seq[2])
            local cur = legs[k]
            if not cur or (r.q or 0) > cur.q then legs[k] = { t = r.t, q = r.q or 0, derived = false } end
        end
    end
    -- Fixpoint: a span with exactly one unknown atomic leg gives that leg by subtraction
    -- (total minus the sum of its known legs). New legs may unlock further spans, so repeat.
    local changed = true
    while changed do
        changed = false
        for _, r in ipairs(records or {}) do
            if r.seq and #r.seq > 2 and r.t then
                local sum, missing, missKey = 0, 0, nil
                for i = 1, #r.seq - 1 do
                    local leg = legs[legKey(r.seq[i], r.seq[i + 1])]
                    if leg then sum = sum + leg.t
                    else missing = missing + 1; missKey = legKey(r.seq[i], r.seq[i + 1]) end
                end
                if missing == 1 then
                    local t = r.t - sum
                    if t > 0 then  -- a non-positive leg means inconsistent data; skip it
                        legs[missKey] = { t = t, q = r.q or 0, derived = true }
                        changed = true
                    end
                end
            end
        end
    end
    return legs
end

-- Look up a solved atomic leg a -> b (nil if unknown). `legs` is a Solve() result.
function FlightGraph:Get(legs, a, b)
    return legs and legs[legKey(a, b)]
end

ns.LibManager:Register(FlightGraph:New("FlightGraph"))
