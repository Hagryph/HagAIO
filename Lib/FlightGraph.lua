local addonName, ns = ...
local Class = ns.Class

-- Lib/FlightGraph.lua
-- Pure route-cost calculations over a generic weighted graph -- no WoW API, no flight
-- specifics. A caller supplies a `legFn(a, b) -> (value, penalty)` for the directed
-- leg a->b (or nil if there is no such leg); these solvers find the chain that
-- MINIMISES total penalty and return the accumulated value along it. The flight-timer
-- module uses penalty = data-imprecision and value = seconds, but nothing here knows
-- that, so the same solvers work for any "cheapest path, report its cost" problem.

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

-- GraphCost: Dijkstra from `src` to `dst` over the node set `nodes` (a set, node ->
-- truthy), minimising accumulated penalty from legFn(a, b) -> (value, penalty) and
-- summing value along the chosen path. Returns the accumulated value at dst, or nil if
-- dst is unreachable (or src == dst / either is nil).
function FlightGraph:GraphCost(src, dst, nodes, legFn)
    if src == nil or dst == nil or src == dst then return nil end
    local pen, val, done = { [src] = 0 }, { [src] = 0 }, {}
    while true do
        local cur, curPen = nil, math.huge
        for nm, pn in pairs(pen) do
            if not done[nm] and pn < curPen then cur, curPen = nm, pn end
        end
        if not cur then return nil end
        if cur == dst then return val[dst] end
        done[cur] = true
        for nm in pairs(nodes) do
            if not done[nm] and nm ~= cur then
                local v, p = legFn(cur, nm)
                if p ~= nil then
                    local cand = curPen + p
                    if pen[nm] == nil or cand < pen[nm] then
                        pen[nm] = cand
                        val[nm] = val[cur] + v
                    end
                end
            end
        end
    end
end

ns.LibManager:Register(FlightGraph:New("FlightGraph"))
