local S = dofile("Test/support.lua")

local function fg()
    local ns = S.newNs()
    S.load(ns, "Services/FlightGraph.lua")
    return ns._captured["FlightGraph"]
end

-- A leg function from a table keyed "a>b" -> { value, penalty }.
local function legsFrom(map)
    return function(a, b)
        local e = map[a .. ">" .. b]
        if not e then return nil end
        return e[1], e[2]
    end
end

describe("FlightGraph:PathCost", function()
    it("sums a single known leg", function()
        local g = fg()
        assert.are.equal(10, g:PathCost({ "A", "B" }, legsFrom({ ["A>B"] = { 10, 0 } })))
    end)

    it("returns 0 for a degenerate (0/1-item) path", function()
        local g = fg()
        assert.are.equal(0, g:PathCost({ "A" }, legsFrom({})))
        assert.are.equal(0, g:PathCost({}, legsFrom({})))
    end)

    it("minimises PENALTY, not value (a low-penalty direct hop beats a cheaper chain)", function()
        local g = fg()
        local legs = legsFrom({ ["A>B"] = { 10, 1 }, ["B>C"] = { 20, 1 }, ["A>C"] = { 40, 1 } })
        assert.are.equal(40, g:PathCost({ "A", "B", "C" }, legs))  -- direct A>C: penalty 1 < 2
    end)

    it("falls back to the multi-hop chain when the direct hop is unknown", function()
        local g = fg()
        local legs = legsFrom({ ["A>B"] = { 10, 1 }, ["B>C"] = { 20, 1 } })
        assert.are.equal(30, g:PathCost({ "A", "B", "C" }, legs))
    end)

    it("returns nil when the chain can't be completed", function()
        local g = fg()
        assert.is_nil(g:PathCost({ "A", "B" }, legsFrom({})))
    end)
end)

describe("FlightGraph:GraphCost", function()
    it("returns nil for src == dst or a nil endpoint", function()
        local g = fg()
        assert.is_nil(g:GraphCost("A", "A", { A = true }, legsFrom({})))
        assert.is_nil(g:GraphCost(nil, "B", { B = true }, legsFrom({})))
    end)

    it("takes the least-penalty edge even if its value is higher", function()
        local g = fg()
        local legs = legsFrom({ ["A>B"] = { 10, 1 }, ["B>C"] = { 20, 1 }, ["A>C"] = { 100, 1 } })
        assert.are.equal(100, g:GraphCost("A", "C", { A = true, B = true, C = true }, legs))
    end)

    it("routes through an intermediate when there is no direct edge", function()
        local g = fg()
        local legs = legsFrom({ ["A>B"] = { 10, 1 }, ["B>C"] = { 20, 1 } })
        assert.are.equal(30, g:GraphCost("A", "C", { A = true, B = true, C = true }, legs))
    end)

    it("returns nil when dst is unreachable", function()
        local g = fg()
        assert.is_nil(g:GraphCost("A", "B", { A = true, B = true }, legsFrom({})))
    end)
end)
