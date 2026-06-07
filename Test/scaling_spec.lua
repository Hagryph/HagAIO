local S = dofile("Test/support.lua")

local function scaling()
    local ns = S.newNs()
    S.load(ns, "Services/Scaling.lua")
    return ns._captured["Scaling"]
end

describe("Scaling", function()
    it("missing form: full bonus at 0% HP, none at 100%", function()
        local sc = scaling()
        local spec = { bonus = 0.8 }  -- defaults: highPct=100, lowPct=0, missing
        assert.are.equal(0, sc:Fraction(spec, 100))
        assert.are.equal(1, sc:Fraction(spec, 0))
        assert.near(1.0, sc:Multiplier(spec, 100), 1e-9)
        assert.near(1.8, sc:Multiplier(spec, 0), 1e-9)
    end)

    it("ramps linearly across the window", function()
        local sc = scaling()
        local spec = { bonus = 1.0 }  -- missing, 100->0
        assert.near(0.5, sc:Fraction(spec, 50), 1e-9)
    end)

    it("plateau: bonus caps at lowPct and stays flat below it", function()
        local sc = scaling()
        local spec = { bonus = 1.0, highPct = 100, lowPct = 35 }
        assert.near(1, sc:Fraction(spec, 35), 1e-9)
        assert.are.equal(1, sc:Fraction(spec, 10))  -- clamped at the plateau
        assert.are.equal(0, sc:Fraction(spec, 100))
    end)

    it("current direction: more as health rises", function()
        local sc = scaling()
        local spec = { bonus = 0.5, direction = "current" }
        assert.are.equal(1, sc:Fraction(spec, 100))
        assert.are.equal(0, sc:Fraction(spec, 0))
    end)

    it("degenerate window (hi == lo) is a hard step", function()
        local sc = scaling()
        local spec = { bonus = 1, highPct = 50, lowPct = 50 }  -- missing
        assert.are.equal(1, sc:Fraction(spec, 50))   -- hp <= hi
        assert.are.equal(0, sc:Fraction(spec, 60))
    end)

    it("Value and Band", function()
        local sc = scaling()
        local spec = { bonus = 0.5 }
        assert.near(150, sc:Value(spec, 100, 0), 1e-9)
        local lo, hi = sc:Band(spec, 100)
        assert.are.equal(100, lo)
        assert.are.equal(150, hi)
        assert.are.equal(100, sc:ValueAtFull(spec, 100))
        assert.near(150, sc:ValueAtEmpty(spec, 100), 1e-9)
    end)

    it("a negative bonus sorts Band / MultiplierBand correctly", function()
        local sc = scaling()
        local spec = { bonus = -0.5 }   -- a reduction, peak below base
        local lo, hi = sc:Band(spec, 100)
        assert.near(50, lo, 1e-9)
        assert.near(100, hi, 1e-9)
        local mlo, mhi = sc:MultiplierBand(spec)
        assert.near(0.5, mlo, 1e-9)
        assert.near(1, mhi, 1e-9)
    end)
end)
