local S = dofile("Test/support.lua")

local function geom()
    local ns = S.newNs()
    S.load(ns, "Lib/Geometry.lua")
    return ns._captured["Geometry"]
end

describe("Geometry", function()
    it("Dist2 / Dist", function()
        local g = geom()
        assert.are.equal(25, g:Dist2(0, 0, 3, 4))
        assert.near(5, g:Dist(0, 0, 3, 4), 1e-9)
    end)

    it("Nearest picks the closest point and returns its distance", function()
        local g = geom()
        local pts = { { x = 10, y = 0, name = "far" }, { x = 1, y = 0, name = "near" } }
        local best, dist = g:Nearest(0, 0, pts)
        assert.are.equal("near", best.name)
        assert.near(1, dist, 1e-9)
    end)

    it("respects maxDist (inclusive) and returns nil when none qualify", function()
        local g = geom()
        local pts = { { x = 50, y = 0, name = "out" } }
        assert.is_nil(g:Nearest(0, 0, pts, 40))
        local best = g:Nearest(0, 0, { { x = 40, y = 0, name = "edge" } }, 40)
        assert.are.equal("edge", best.name)  -- exactly at the cap counts
    end)

    it("skips points missing x/y", function()
        local g = geom()
        local pts = { { name = "noxy" }, { x = 2, y = 0, name = "ok" } }
        local best = g:Nearest(0, 0, pts)
        assert.are.equal("ok", best.name)
    end)
end)
