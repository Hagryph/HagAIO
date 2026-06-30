local S = dofile("Test/support.lua")

local function fg()
    local ns = S.newNs()
    S.load(ns, "Lib/FlightGraph.lua")
    return ns._captured["FlightGraph"]
end

-- Build records: each is { seq = {...}, t = , q = }. Helper for brevity.
local function rec(seq, t, q) return { seq = seq, t = t, q = q or 2 } end

describe("FlightGraph.Solve", function()
    it("seeds atomic legs from 2-node records", function()
        local g = fg()
        local legs = g.Solve({ rec({ "A", "B" }, 10, 2) })
        assert.are.equal(10, g.Get(legs, "A", "B").t)
        assert.is_false(g.Get(legs, "A", "B").derived)
        assert.is_nil(g.Get(legs, "B", "A"))   -- direction is distinct
    end)

    it("keeps the best-quality measurement per leg", function()
        local g = fg()
        local legs = g.Solve({ rec({ "A", "B" }, 12, 1), rec({ "A", "B" }, 10, 2) })
        assert.are.equal(10, g.Get(legs, "A", "B").t)   -- direct (q2) beats fly (q1)
        assert.are.equal(2, g.Get(legs, "A", "B").q)
    end)

    it("derives a missing leg from a span by subtraction (A->B = A->C - B->C)", function()
        local g = fg()
        -- span A->C over { B } = 160; leg B->C = 60  =>  leg A->B = 100
        local legs = g.Solve({ rec({ "A", "B", "C" }, 160, 2), rec({ "B", "C" }, 60, 2) })
        local ab = g.Get(legs, "A", "B")
        assert.are.equal(100, ab.t)
        assert.is_true(ab.derived)
    end)

    it("chains subtraction to a fixpoint", function()
        local g = fg()
        -- span A->D over {B,C} = 100; B->C = 30; C->D = 40  => A->B = 30 (after both known)
        local legs = g.Solve({ rec({ "A", "B", "C", "D" }, 100, 2), rec({ "B", "C" }, 30, 2), rec({ "C", "D" }, 40, 2) })
        assert.are.equal(30, g.Get(legs, "A", "B").t)
    end)

    it("cannot derive when two legs are unknown", function()
        local g = fg()
        local legs = g.Solve({ rec({ "A", "B", "C" }, 160, 2) })  -- neither A->B nor B->C known
        assert.is_nil(g.Get(legs, "A", "B"))
        assert.is_nil(g.Get(legs, "B", "C"))
    end)

    it("rejects an inconsistent (non-positive) derived leg", function()
        local g = fg()
        -- span A->C = 50 but B->C = 60  =>  A->B would be -10: dropped
        local legs = g.Solve({ rec({ "A", "B", "C" }, 50, 2), rec({ "B", "C" }, 60, 2) })
        assert.is_nil(g.Get(legs, "A", "B"))
    end)

    it("Get is nil-safe and returns nil for unknown legs", function()
        local g = fg()
        assert.is_nil(g.Get(nil, "A", "B"))
        assert.is_nil(g.Get(g.Solve({}), "A", "B"))
    end)
end)
