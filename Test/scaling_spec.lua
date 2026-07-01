local S = dofile("Test/support.lua")

-- Returns the Scaling service and the ScalingSpec value-type constructor. A spec is built
-- positionally: spec(bonus, highPct, lowPct, direction); nils fall back to the defaults.
local function scaling()
    local ns = S.newNs()
    S.load(ns, "Services/Scaling.lua")
    local Spec = ns.ScalingSpec
    return ns._captured["Scaling"], function(...) return Spec:New(...) end
end

describe("Scaling", function()
    it("missing form: full bonus at 0% HP, none at 100%", function()
        local sc, spec = scaling()
        spec = spec(0.8)  -- defaults: highPct=100, lowPct=0, missing
        assert.are.equal(0, sc:Fraction(spec, 100))
        assert.are.equal(1, sc:Fraction(spec, 0))
        assert.near(1.0, sc:Multiplier(spec, 100), 1e-9)
        assert.near(1.8, sc:Multiplier(spec, 0), 1e-9)
    end)

    it("ramps linearly across the window", function()
        local sc, spec = scaling()
        spec = spec(1.0)  -- missing, 100->0
        assert.near(0.5, sc:Fraction(spec, 50), 1e-9)
    end)

    it("plateau: bonus caps at lowPct and stays flat below it", function()
        local sc, spec = scaling()
        spec = spec(1.0, 100, 35)
        assert.near(1, sc:Fraction(spec, 35), 1e-9)
        assert.are.equal(1, sc:Fraction(spec, 10))  -- clamped at the plateau
        assert.are.equal(0, sc:Fraction(spec, 100))
    end)

    it("current direction: more as health rises", function()
        local sc, spec = scaling()
        spec = spec(0.5, nil, nil, "current")
        assert.are.equal(1, sc:Fraction(spec, 100))
        assert.are.equal(0, sc:Fraction(spec, 0))
    end)

    it("degenerate window (hi == lo) is a hard step", function()
        local sc, spec = scaling()
        spec = spec(1, 50, 50)  -- missing
        assert.are.equal(1, sc:Fraction(spec, 50))   -- hp <= hi
        assert.are.equal(0, sc:Fraction(spec, 60))
    end)

    it("Value and Band", function()
        local sc, spec = scaling()
        spec = spec(0.5)
        assert.near(150, sc:Value(spec, 100, 0), 1e-9)
        local lo, hi = sc:Band(spec, 100)
        assert.are.equal(100, lo)
        assert.are.equal(150, hi)
        assert.are.equal(100, sc:ValueAtFull(spec, 100))
        assert.near(150, sc:ValueAtEmpty(spec, 100), 1e-9)
    end)

    it("degenerate window with direction=current is a hard step the other way", function()
        local sc, spec = scaling()
        spec = spec(1, 50, 50, "current")
        assert.are.equal(1, sc:Fraction(spec, 60))   -- hp >= hi
        assert.are.equal(0, sc:Fraction(spec, 40))
    end)

    it("nil bonus falls back to no scaling", function()
        local sc, spec = scaling()
        assert.are.equal(1, sc:Multiplier(spec(), 50))   -- (spec:Bonus() or 0)
        assert.are.equal(0, sc:Value(spec(), nil, 0))    -- (base or 0)
        local mlo, mhi = sc:MultiplierBand(spec())
        assert.are.equal(1, mlo); assert.are.equal(1, mhi)
    end)

    it("clamps health above 100 / below 0 (missing form)", function()
        local sc, spec = scaling()
        spec = spec(0.8)                              -- highPct=100, lowPct=0
        assert.are.equal(0, sc:Fraction(spec, 150))   -- t = (100-150)/100 = -0.5 -> 0
        assert.are.equal(1, sc:Fraction(spec, -20))   -- t = (100+20)/100 = 1.2  -> 1
    end)

    it("clamps health above 100 / below 0 (current direction)", function()
        local sc, spec = scaling()
        spec = spec(0.8, nil, nil, "current")
        assert.are.equal(1, sc:Fraction(spec, 150))   -- (150-0)/100 = 1.5 -> 1
        assert.are.equal(0, sc:Fraction(spec, -20))   -- (-20-0)/100 = -0.2 -> 0
    end)

    it("a negative bonus sorts Band / MultiplierBand correctly", function()
        local sc, spec = scaling()
        spec = spec(-0.5)   -- a reduction, peak below base
        local lo, hi = sc:Band(spec, 100)
        assert.near(50, lo, 1e-9)
        assert.near(100, hi, 1e-9)
        local mlo, mhi = sc:MultiplierBand(spec)
        assert.near(0.5, mlo, 1e-9)
        assert.near(1, mhi, 1e-9)
    end)
end)
