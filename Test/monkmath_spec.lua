local S = dofile("Test/support.lua")

local function mm()
    local ns = S.newNs()
    S.load(ns, "Lib/MonkMath.lua")
    return ns._captured["MonkMath"]
end

describe("MonkMath:AoEThreshold", function()
    it("floor(tp*bias/sck)+1 -- the SCK-beats-Tiger-Palm breakpoint", function()
        -- 100*1.2/40 = 3.0 -> floor 3 +1 = 4
        assert.are.equal(4, mm():AoEThreshold(100, 40, 1.2))
    end)
    it("rounds the boundary down before +1 (120/60 = 2 -> 3)", function()
        assert.are.equal(3, mm():AoEThreshold(100, 60, 1.2))
    end)
    it("never returns below 1", function()
        assert.are.equal(1, mm():AoEThreshold(10, 100, 1.2))   -- floor(0.12)+1 = 1
    end)
    it("returns nil when a damage is missing or sck is non-positive", function()
        local m = mm()
        assert.is_nil(m:AoEThreshold(nil, 40, 1.2))
        assert.is_nil(m:AoEThreshold(100, nil, 1.2))
        assert.is_nil(m:AoEThreshold(100, 0, 1.2))
    end)
end)

describe("MonkMath:OrbFill", function()
    it("min/max make the StatusBar fraction the true heal fraction at every orb count", function()
        local m = mm()
        local baseHeal, orbHeal, orbMax, maxHP, width = 1000, 200, 5, 100000, 300
        local mn, mx, span = m:OrbFill(baseHeal, orbHeal, orbMax, maxHP, width)
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
        local mn = (mm()):OrbFill(1000, 0, 5, 100000, 300)
        assert.are.equal(-1000 / 1e-9, mn)   -- finite, not inf/nan
    end)
end)

describe("MonkMath:HealLineFill", function()
    -- The fed-current-health StatusBar fraction must equal the Strength-of-Spirit heal-to
    -- fraction h + (baseHeal/maxHP)*(1 + bonus*(1-h)) at every health level.
    local function heal(baseHeal, maxHP, h, bonus) -- heal-to fraction at health fraction h
        return h + (baseHeal / maxHP) * (1 + bonus * (1 - h))
    end
    it("bakes the missing-health ramp so the fill edge lands at the heal-to point", function()
        local m = mm()
        local baseHeal, maxHP, bonus = 1000, 10000, 1.0
        local mn, mx = m:HealLineFill(baseHeal, bonus, maxHP)
        for _, h in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
            local frac = (h * maxHP - mn) / (mx - mn)        -- StatusBar fill fraction at value=health
            assert.near(heal(baseHeal, maxHP, h, bonus), frac)
        end
    end)
    it("bonus=0 degenerates to a plain current-health + baseHeal line", function()
        local m = mm()
        local mn, mx = m:HealLineFill(1000, 0, 10000)
        assert.near(-1000, mn)                                -- min = -baseHeal
        assert.near(9000, mx)                                 -- max = maxHP - baseHeal
        assert.near(0.6, (5000 - mn) / (mx - mn))             -- h=0.5 -> 0.5 + 1000/10000
    end)
    it("treats a nil bonus as zero", function()
        local m = mm()
        local mn = m:HealLineFill(1000, nil, 10000)
        assert.near(-1000, mn)
    end)
end)

describe("MonkMath:SumEnergyCosts", function()
    local ENERGY, OTHER = 3, 0
    it("sums only energy-typed costs across spells, ignoring other power types", function()
        local costsPerSpell = {
            { { type = ENERGY, cost = 50 }, { type = OTHER, cost = 999 } },   -- Tiger Palm
            { { type = ENERGY, cost = 40 } },                                  -- Keg Smash
        }
        assert.are.equal(90, (mm()):SumEnergyCosts(costsPerSpell, ENERGY))
    end)
    it("skips a secret cost value", function()
        local isSecret = function(v) return v == 77 end
        local costsPerSpell = { { { type = ENERGY, cost = 50 }, { type = ENERGY, cost = 77 } } }
        assert.are.equal(50, (mm()):SumEnergyCosts(costsPerSpell, ENERGY, isSecret))
    end)
    it("is nil/empty safe", function()
        assert.are.equal(0, (mm()):SumEnergyCosts(nil, ENERGY))
        assert.are.equal(0, (mm()):SumEnergyCosts({ nil, {} }, ENERGY))
    end)
end)

describe("MonkMath:CostPoint", function()
    it("scales the cost to pixels along the bar", function()
        assert.near(150, (mm()):CostPoint(50, 100, 300))   -- 50/100 * 300
        assert.near(0,   (mm()):CostPoint(0, 100, 300))
    end)
end)
