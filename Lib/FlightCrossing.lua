local addonName, ns = ...

-- Lib/FlightCrossing.lua
-- Pure flight-path crossing arithmetic for the FlightTimers submodule -- no WoW API, no
-- state. Extracted VERBATIM from Modules/Misc/FlightTimers.lua so the numbers that decide
-- which flight segments get recorded are unit-testable. The submodule keeps its self:_p()
-- state, the GetTime()/C_Map reads and the DB writes; only the pure computation lives here:
--   * PollCrossing    -- min-distance tracking + CROSS_MARGIN hysteresis + FLYOVER_RANGE skip;
--                        returns a decision the caller applies to its crossing state.
--   * PathIndexOf     -- index of a node name in the booked path (nil if absent).
--   * PathNamesBetween-- the names of the nodes strictly between two path indices (nil rules).
--   * RecordCross     -- the previous-stamp -> this-stamp segment derivation (incl. seg > 1).
--   * RecordFinalLeg  -- the last-flown-node -> landed segment derivation (incl. seg > 1).
--   * ShouldReplaceDirect -- the DIRECT-write better-time replacement policy.
-- CROSS_MARGIN / FLYOVER_RANGE (yards) live here as the crossing tunables (the submodule
-- still owns ARRIVE_YARDS, which is a landing/Vector2D concern, not a crossing one).

local FlightCrossing = {}

local sqrt, huge = math.sqrt, math.huge
local abs = math.abs

-- ---- tunables (flight-path crossing distances, yards) --------------------
FlightCrossing.CROSS_MARGIN  = 75   -- moved this many (linear) yards past the closest approach = passed it
FlightCrossing.FLYOVER_RANGE = 75   -- closest approach must be within this to count as flying OVER a node;
                                    -- farther than this and the node is skipped (never recorded)

-- Poll once per refresh while flying: track the closest approach to the NEXT path node;
-- once we have clearly moved away from it, decide whether to stamp it. Pure given the next
-- node, the player world position (px, py, pc) and the current clock, plus the caller's
-- running closest-approach state (crossMinDist, crossMinTime). Returns a decision table the
-- caller applies to its p.crossIdx / p.crossMinDist / p.crossMinTime and (on record) calls
-- _RecordCross with. action is one of:
--   "skip"    -- this node can't be timed (no world pos): advance, reset min dist.
--   "wait"    -- can't measure (no/off-continent player pos) OR still approaching: no change.
--   "track"   -- new closest approach: caller stores minDist/minTime (the returned values).
--   "advance" -- moved clearly past closest approach: advance; record iff `record` is true.
-- The arithmetic/branching is byte-identical to FlightTimers:_PollCrossing.
function FlightCrossing.PollCrossing(node, px, py, pc, now, crossMinDist, crossMinTime, crossMargin, flyoverRange)
    if not (node and node.world) then          -- can't time this one; skip past it
        return { action = "skip" }
    end
    if not px or pc ~= node.world.c then return { action = "wait" } end
    local dx, dy = px - node.world.x, py - node.world.y
    local dist = sqrt(dx * dx + dy * dy)   -- LINEAR yards (squared margin fires too early)
    if dist < (crossMinDist or huge) then
        return { action = "track", minDist = dist, minTime = now }
    elseif crossMinTime and dist > crossMinDist + crossMargin then
        -- We've clearly moved past this node's closest approach. Record it as a
        -- fly-over ONLY if we actually came within FLYOVER_RANGE; otherwise skip it
        -- (the next recorded node's segment then spans from the last node we DID
        -- fly over, e.g. A -> C when B was never within range).
        return { action = "advance", record = (crossMinDist <= flyoverRange) }
    end
    return { action = "wait" }
end

-- Index of a node in the booked path by name (nil if absent). Pure over `path`.
function FlightCrossing.PathIndexOf(path, name)
    if not path then return nil end
    for i = 1, #path do if path[i].name == name then return i end end
end

-- Ordered names of the booked nodes strictly BETWEEN path indices i and j (the stops a
-- span skipped over). nil when there are none, or if any name is missing (so a partial
-- span isn't recorded with a hole that would mis-key the subtraction). Pure over `path`.
function FlightCrossing.PathNamesBetween(path, i, j)
    if not (path and i and j and j > i + 1) then return nil end
    local via = {}
    for k = i + 1, j - 1 do
        local n = path[k] and path[k].name
        if not n then return nil end
        via[#via + 1] = n
    end
    return (#via > 0) and via or nil
end

-- Derive the segment to store when stamping node `idx`'s crossing time. Pure over the path,
-- the crossTimes map (with crossTimes[idx] already set to `when`), and prevIdx (the last node
-- actually flown over). Returns (a, b, seg, via) when the segment should be stored as a fly
-- (seg > 1), or nil when it shouldn't. Mirrors FlightTimers:_RecordCross's derivation exactly
-- (the caller still mutates p.crossTimes / p.lastCrossIdx and does the _StoreIfNew DB write).
function FlightCrossing.RecordCross(path, crossTimes, prevIdx, idx, when)
    local prevT = crossTimes[prevIdx]
    local a = path[prevIdx] and path[prevIdx].name
    local b = path[idx] and path[idx].name
    if prevT and a and b and a ~= b then
        local seg = when - prevT
        if seg > 1 then
            return a, b, seg, FlightCrossing.PathNamesBetween(path, prevIdx, idx)
        end
    end
    return nil
end

-- The final leg: last node we actually passed (`fromIdx`) -> where we landed. Timed from that
-- node's closest approach to the DISMOUNT (`when`). Pure over the path, crossTimes, fromIdx,
-- the landed node name and `when`. Returns (fromName, landed, seg, via) when it should be
-- stored (seg > 1), else nil. Mirrors FlightTimers:_RecordFinalLeg's derivation exactly.
function FlightCrossing.RecordFinalLeg(path, crossTimes, fromIdx, landed, when)
    local fromT = crossTimes[fromIdx]
    local fromName = path and path[fromIdx] and path[fromIdx].name
    if fromName and fromT and fromName ~= landed then
        local seg = when - fromT
        local via = FlightCrossing.PathNamesBetween(path, fromIdx, FlightCrossing.PathIndexOf(path, landed) or #path)
        if seg > 1 then
            return fromName, landed, seg, via
        end
    end
    return nil
end

-- The DIRECT-write better-time replacement policy: given the existing route row (or nil), the
-- new measured `seconds` and the DIRECT quality tier, decide what the write should do. Returns
-- "insert" (no row yet), "replace" (lower-quality row OR direct time changed by >= 5s) or
-- "skip" (an equal-or-better DIRECT within 5s). Mirrors FlightTimers:_FlightStore's branching
-- (the caller still does the _MasterId resolution and the actual Insert/Update + hops).
function FlightCrossing.ShouldReplaceDirect(row, seconds, directQuality)
    if not row then return "insert" end
    if row.quality < directQuality then
        return "replace"
    elseif abs(seconds - row.t) >= 5 then
        return "replace"
    end
    return "skip"
end

ns.LibManager:RegisterValue("FlightCrossing", FlightCrossing)
