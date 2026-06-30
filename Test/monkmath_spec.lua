local S = dofile("Test/support.lua")

local function mm()
    local ns = S.newNs()
    S.load(ns, "Lib/MonkMath.lua")
    return ns._captured["MonkMath"]
end

describe("MonkMath.AoEThreshold", function()
    it("floor(tp*bias/sck)+1 -- the SCK-beats-Tiger-Palm breakpoint", function()
        -- 100*1.2/40 = 3.0 -> floor 3 +1 = 4
        assert.are.equal(4, mm().AoEThreshold(100, 40, 1.2))
    end)
    it("rounds the boundary down before +1 (120/60 = 2 -> 3)", function()
        assert.are.equal(3, mm().AoEThreshold(100, 60, 1.2))
    end)
    it("never returns below 1", function()
        assert.are.equal(1, mm().AoEThreshold(10, 100, 1.2))   -- floor(0.12)+1 = 1
    end)
    it("returns nil when a damage is missing or sck is non-positive", function()
        local m = mm()
        assert.is_nil(m.AoEThreshold(nil, 40, 1.2))
        assert.is_nil(m.AoEThreshold(100, nil, 1.2))
        assert.is_nil(m.AoEThreshold(100, 0, 1.2))
    end)
end)

describe("MonkMath.OrbFill", function()
    it("min/max make the StatusBar fraction the true heal fraction at every orb count", function()
        local m = mm()
        local baseHeal, orbHeal, orbMax, maxHP, width = 1000, 200, 5, 100000, 300
        local mn, mx, span = m.OrbFill(baseHeal, orbHeal, orbMax, maxHP, width)
        assert.are.equal(orbMax, mx)
        for count = 0, orbMax do
            local frac = (count - mn) / (mx - mn)                       -- StatusBar fill fraction
            local want = (baseHeal + count * orbHeal) / (baseHeal + orbMax * orbHeal)
            assert.near(want, frac)
        end
        -- span px = total heal as a fraction of maxHP, times the bar width
        assert.near((baseHeal + orbMax * orbHeal) / maxHP * width, span)
    end)
    it("guards a zero orbHeal against divide-by-zero", function()
        local mn = (mm()).OrbFill(1000, 0, 5, 100000, 300)
        assert.are.equal(-1000 / 1e-9, mn)   -- finite, not inf/nan
    end)
end)

describe("MonkMath.SumEnergyCosts", function()
    local ENERGY, OTHER = 3, 0
    it("sums only energy-typed costs across spells, ignoring other power types", function()
        local costsPerSpell = {
            { { type = ENERGY, cost = 50 }, { type = OTHER, cost = 999 } },   -- Tiger Palm
            { { type = ENERGY, cost = 40 } },                                  -- Keg Smash
        }
        assert.are.equal(90, (mm()).SumEnergyCosts(costsPerSpell, ENERGY))
    end)
    it("skips a secret cost value", function()
        local isSecret = function(v) return v == 77 end
        local costsPerSpell = { { { type = ENERGY, cost = 50 }, { type = ENERGY, cost = 77 } } }
        assert.are.equal(50, (mm()).SumEnergyCosts(costsPerSpell, ENERGY, isSecret))
    end)
    it("is nil/empty safe", function()
        assert.are.equal(0, (mm()).SumEnergyCosts(nil, ENERGY))
        assert.are.equal(0, (mm()).SumEnergyCosts({ nil, {} }, ENERGY))
    end)
end)

describe("MonkMath.CostPoint", function()
    it("scales the cost to pixels along the bar", function()
        assert.near(150, (mm()).CostPoint(50, 100, 300))   -- 50/100 * 300
        assert.near(0,   (mm()).CostPoint(0, 100, 300))
    end)
end)

describe("MonkMath.HealingTakenMultiplier", function()
    it("1 + pct/100 from the parsed percent", function()
        assert.are.equal(1.06, (mm()).HealingTakenMultiplier(6))
    end)
    it("defaults to +4% when the percent is nil (unreadable tooltip)", function()
        assert.are.equal(1.04, (mm()).HealingTakenMultiplier(nil))
    end)
    it("a parsed 0% is honoured (not treated as missing)", function()
        assert.are.equal(1, (mm()).HealingTakenMultiplier(0))
    end)
end)

describe("MonkMath.RoundHeal", function()
    it("floor(heal*mult + 0.5) -- rounds to nearest", function()
        -- 1000 * 1.04 = 1040 -> floor(1040.5) = 1040
        assert.are.equal(1040, (mm()).RoundHeal(1000, 1.04))
        -- 1001 * 1.04 = 1041.04 -> floor(1041.54) = 1041
        assert.are.equal(1041, (mm()).RoundHeal(1001, 1.04))
        -- rounds the .5 boundary UP: 1 * 1.5 = 1.5 -> floor(2.0) = 2
        assert.are.equal(2, (mm()).RoundHeal(1, 1.5))
    end)
    it("returns nil when the heal wasn't parsed (caller falls back)", function()
        assert.is_nil((mm()).RoundHeal(nil, 1.04))
    end)
end)

describe("MonkMath.RoundOrbHeal", function()
    it("floor(n*mult + 0.5) -- same rounding as RoundHeal", function()
        assert.are.equal(208, (mm()).RoundOrbHeal(200, 1.04))   -- 200*1.04=208 -> floor(208.5)
        assert.are.equal(3,   (mm()).RoundOrbHeal(2, 1.4))      -- 2*1.4=2.8 -> floor(3.3)=3
    end)
    it("returns 0 when the heal wasn't parsed (no sphere talent / unreadable)", function()
        assert.are.equal(0, (mm()).RoundOrbHeal(nil, 1.04))
    end)
end)

describe("MonkMath.AcceptHitDamage", function()
    it("returns a usable positive non-secret value", function()
        assert.are.equal(1234, (mm()).AcceptHitDamage(1234))
    end)
    it("rejects nil and non-positive values", function()
        local m = mm()
        assert.is_nil(m.AcceptHitDamage(nil))
        assert.is_nil(m.AcceptHitDamage(0))
        assert.is_nil(m.AcceptHitDamage(-5))
    end)
    it("REJECTS a secret value -- it must not enter the math", function()
        -- A secret value reads as a positive number here (so it passes the >0 gate),
        -- but issecretvalue flags it -> AcceptHitDamage must still reject it.
        local secret = 5000
        local isSecret = function(v) return v == secret end
        assert.is_nil((mm()).AcceptHitDamage(secret, isSecret))
    end)
    it("accepts a normal value when isSecret says it is not secret", function()
        local isSecret = function() return false end
        assert.are.equal(900, (mm()).AcceptHitDamage(900, isSecret))
    end)
    it("ignores a missing isSecret predicate (optional)", function()
        assert.are.equal(50, (mm()).AcceptHitDamage(50, nil))
    end)
end)
