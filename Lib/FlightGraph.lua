local addonName, ns = ...
local Class = ns.Class

-- Lib/FlightGraph.lua
-- Pure route-cost calculation over an ORDERED path -- no WoW API, no flight specifics. A
-- caller supplies a `legFn(a, b) -> (value, penalty)` for the directed leg a->b (or nil if
-- there is no such leg); PathCost finds the chain DOWN THAT PATH that MINIMISES total
-- penalty and returns the accumulated value along it. The flight-timer module uses
-- penalty = data-imprecision and value = seconds, but nothing here knows that, so it
-- works for any "cheapest path along a fixed sequence, report its cost" problem.

local FlightGraph = Class.new("FlightGraph", ns.Lib)

-- PathCost: assemble an ORDERED list `items` (1..n) into the least-penalty chain that
-- reaches item n from item 1, where a hop may skip intermediates. legFn(a, b) returns
-- (value, penalty) for the leg, or nil if unknown. Returns the accumulated `value` of
-- that least-penalty chain, or nil if no chain completes. (DP: each item is reached
-- from any earlier item, keeping the minimum total penalty.)
function FlightGraph:PathCost(items, legFn)
    local n = items and #items or 0
    if n < 2 then return 0 end   -- nothing to assemble
    local pen, val = { [1] = 0 }, { [1] = 0 }
    for j = 2, n do
        for i = 1, j - 1 do
            if pen[i] ~= nil then
                local v, p = legFn(items[i], items[j])
                if p ~= nil then
                    local cand = pen[i] + p
                    if pen[j] == nil or cand < pen[j] then
                        pen[j] = cand
                        val[j] = val[i] + v
                    end
                end
            end
        end
    end
    return val[n]   -- nil if the chain can't be completed
end

ns.LibManager:Register(FlightGraph:New("FlightGraph"))
