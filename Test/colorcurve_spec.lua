local S = dofile("Test/support.lua")

local function cc()
    local ns = S.newNs()
    S.load(ns, "Lib/ColorCurve.lua")
    return ns._captured["ColorCurve"]
end

describe("ColorCurve.HealthPoints", function()
    local LO  = { 0.90, 0.15, 0.15 }   -- low / red
    local MID = { 0.95, 0.82, 0.15 }   -- mid / yellow
    local HI  = { 0.20, 0.80, 0.20 }   -- full / green

    it("pins the four positions: 0%, 30%, 55%, 100%", function()
        local pts = (cc()).HealthPoints(LO, MID, HI)
        assert.are.equal(4, #pts)
        assert.are.equal(0.00, pts[1].pos)
        assert.are.equal(0.30, pts[2].pos)
        assert.are.equal(0.55, pts[3].pos)
        assert.are.equal(1.00, pts[4].pos)
    end)

    it("low colour holds flat across 0% and 30%", function()
        local pts = (cc()).HealthPoints(LO, MID, HI)
        for _, i in ipairs({ 1, 2 }) do
            assert.near(LO[1], pts[i][1]); assert.near(LO[2], pts[i][2]); assert.near(LO[3], pts[i][3])
        end
    end)

    it("mid colour sits at 55%", function()
        local p = (cc()).HealthPoints(LO, MID, HI)[3]
        assert.near(MID[1], p[1]); assert.near(MID[2], p[2]); assert.near(MID[3], p[3])
    end)

    it("full colour sits at 100%", function()
        local p = (cc()).HealthPoints(LO, MID, HI)[4]
        assert.near(HI[1], p[1]); assert.near(HI[2], p[2]); assert.near(HI[3], p[3])
    end)

    it("honours custom overrides verbatim (no clamping/reordering)", function()
        local lo, mid, hi = { 0.1, 0.2, 0.3 }, { 0.4, 0.5, 0.6 }, { 0.7, 0.8, 0.9 }
        local pts = (cc()).HealthPoints(lo, mid, hi)
        assert.near(0.1, pts[1][1]); assert.near(0.3, pts[2][3])
        assert.near(0.5, pts[3][2]); assert.near(0.9, pts[4][3])
    end)
end)
