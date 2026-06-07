local addonName, ns = ...
local Class = ns.Class

-- Lib/FlightResolver.lua
-- Pure read-side algebra for flight-time queries over a solved atomic-leg table (the
-- ns.FlightGraph Solve() result). No WoW API. Extracted from Misc.lua so its edge cases are
-- unit-testable. It owns the flight QUALITY enum and three pure operations the flight timer
-- leans on:
--   * StoredTime -- normalise a stored DB entry (number | { t = .. }) to seconds.
--   * EntryQ     -- the entry's quality tier, decoding the legacy entry shapes.
--   * LegTime    -- best time for one atomic leg, ranking the two directions by quality.
--   * SumLegs    -- sum a route's atomic legs, returning nil if ANY leg is unknown
--                   (the never-fabricate invariant: a route with a gap has no time).

local FlightResolver = Class.new("FlightResolver", ns.Lib)

-- DIRECT (a real landing) outranks FLY (a mid-flight closest-approach guess). Numeric so a
-- higher quality wins ties; persisted as a DB entry's `q`, so the values must stay 2/1.
FlightResolver.Quality = ns.Enum.new("FlightQuality", { DIRECT = 2, FLY = 1 })

-- Seconds recorded on a DB entry: a plain number (legacy) or a { t = seconds, ... } table.
function FlightResolver:StoredTime(e)
    if type(e) == "number" then return e end
    return e and e.t
end

-- Quality tier of a DB entry, decoding legacy shapes: nil -> nil; a plain number -> DIRECT
-- (an old direct record); an explicit `q` -> that; an old { est = true } saved estimate ->
-- FLY; otherwise DIRECT.
function FlightResolver:EntryQ(e)
    if e == nil then return nil end
    if type(e) ~= "table" then return self.Quality.DIRECT end   -- legacy number
    if e.q then return e.q end
    return e.est and self.Quality.FLY or self.Quality.DIRECT     -- legacy saved estimate -> fly
end

-- Best time for one ATOMIC leg a -> b from the solved leg table, in priority order:
--   1 direct same > 2 direct reverse > 3 fly same > 4 fly reverse > 5 derived same >
--   6 derived reverse.
-- A reverse leg substitutes the opposite direction; a derived leg came from subtraction.
-- Returns seconds, or nil if the leg is entirely unknown.
function FlightResolver:LegTime(legs, a, b)
    local Q = self.Quality
    local fwd = ns.FlightGraph:Get(legs, a, b)
    local rev = ns.FlightGraph:Get(legs, b, a)
    if fwd and not fwd.derived and fwd.q == Q.DIRECT then return fwd.t end   -- 1
    if rev and not rev.derived and rev.q == Q.DIRECT then return rev.t end   -- 2
    if fwd and not fwd.derived and fwd.q == Q.FLY    then return fwd.t end   -- 3
    if rev and not rev.derived and rev.q == Q.FLY    then return rev.t end   -- 4
    if fwd and fwd.derived then return fwd.t end                            -- 5
    if rev and rev.derived then return rev.t end                            -- 6
    return nil
end

-- Sum an ORDERED node list into a total by adding each consecutive atomic leg. Returns
-- seconds, or nil if any leg on the path is unknown (we never fabricate a missing leg).
function FlightResolver:SumLegs(legs, names)
    local total = 0
    for i = 1, #names - 1 do
        local t = self:LegTime(legs, names[i], names[i + 1])
        if not t then return nil end
        total = total + t
    end
    return total
end

ns.LibManager:Register(FlightResolver:New("FlightResolver"))
