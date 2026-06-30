local S = dofile("Test/support.lua")

local function V()
    local ns = S.newNs()
    S.load(ns, "Lib/Vector2D.lua")
    return ns.Vector2D
end

describe("Vector2D", function()
    it("stores x/y and unpacks", function()
        local v = V():New(3, 4)
        assert.are.equal(3, v:X()); assert.are.equal(4, v:Y())
        local x, y = v:Unpack(); assert.are.equal(3, x); assert.are.equal(4, y)
    end)

    it("Dist2 / Dist between two vectors", function()
        local Vec = V()
        assert.are.equal(25, Vec:New(0, 0):Dist2(Vec:New(3, 4)))
        assert.near(5, Vec:New(0, 0):Dist(Vec:New(3, 4)), 1e-9)
    end)

    it("Length / LengthSq", function()
        local v = V():New(3, 4)
        assert.are.equal(25, v:LengthSq())
        assert.near(5, v:Length(), 1e-9)
    end)

    it("Add / Sub / Scale return new vectors", function()
        local Vec = V()
        local a, b = Vec:New(1, 2), Vec:New(3, 5)
        local sum = a:Add(b);  assert.are.equal(4, sum:X()); assert.are.equal(7, sum:Y())
        local dif = b:Sub(a);  assert.are.equal(2, dif:X()); assert.are.equal(3, dif:Y())
        local sc  = a:Scale(3); assert.are.equal(3, sc:X()); assert.are.equal(6, sc:Y())
        assert.are.equal(1, a:X())  -- original untouched (immutable)
    end)

    it("Nearest picks the closest, with index", function()
        local Vec = V()
        local list = { Vec:New(10, 0), Vec:New(1, 0), Vec:New(5, 0) }
        local best, dist, i = Vec:New(0, 0):Nearest(list)
        assert.are.equal(1, best:X()); assert.near(1, dist, 1e-9); assert.are.equal(2, i)
    end)

    it("Nearest respects an inclusive maxDist and returns nil when none qualify", function()
        local Vec = V()
        assert.is_nil(Vec:New(0, 0):Nearest({ Vec:New(50, 0) }, 40))
        local best = Vec:New(0, 0):Nearest({ Vec:New(40, 0) }, 40)  -- exactly at the cap
        assert.are.equal(40, best:X())
    end)

    it("Nearest first-wins on a distance tie", function()
        local Vec = V()
        local list = { Vec:New(3, 0), Vec:New(3, 0) }
        local _, _, i = Vec:New(0, 0):Nearest(list)
        assert.are.equal(1, i)  -- first of the equidistant pair
    end)

    it("Nearest returns nil for an empty list", function()
        local Vec = V()
        assert.is_nil(Vec:New(0, 0):Nearest({}))
    end)

    it("handles a coincident point (distance 0) and negative coords", function()
        local Vec = V()
        assert.are.equal(25, Vec:New(-3, -4):Dist2(Vec:New(0, 0)))   -- negative coords
        local best, d = Vec:New(-3, -4):Nearest({ Vec:New(-3, -4), Vec:New(0, 0) })
        assert.are.equal(-3, best:X()); assert.are.equal(0, d)        -- exact origin-coincident
    end)

    it("OnRing places points at the cardinal angles", function()
        local Vec = V()
        local x, y = Vec.OnRing(10, 0)                 -- +x axis
        assert.near(10, x, 1e-9); assert.near(0, y, 1e-9)
        x, y = Vec.OnRing(10, 90)                      -- +y axis
        assert.near(0, x, 1e-9); assert.near(10, y, 1e-9)
        x, y = Vec.OnRing(10, 180)                     -- -x axis
        assert.near(-10, x, 1e-9); assert.near(0, y, 1e-9)
        x, y = Vec.OnRing(10, 270)                     -- -y axis
        assert.near(0, x, 1e-9); assert.near(-10, y, 1e-9)
    end)

    it("AngleOf recovers the angle from a delta", function()
        local Vec = V()
        assert.near(0,   Vec.AngleOf(5, 0),   1e-9)
        assert.near(90,  Vec.AngleOf(0, 5),   1e-9)
        assert.near(180, Vec.AngleOf(-5, 0),  1e-9)
        assert.near(-90, Vec.AngleOf(0, -5),  1e-9)   -- atan2 returns -90, not 270
        assert.near(45,  Vec.AngleOf(3, 3),   1e-9)
    end)

    it("round-trips angle -> point -> angle", function()
        local Vec = V()
        for _, deg in ipairs({ -135, -90, 0, 30, 45, 135, 179 }) do
            local x, y = Vec.OnRing(7, deg)
            assert.near(deg, Vec.AngleOf(x, y), 1e-9)   -- radius drops out of the angle
        end
    end)

    it("round-trips the default minimap angle (225 -> -135)", function()
        local Vec = V()
        local x, y = Vec.OnRing(63, 225)                -- 225 deg, e.g. Minimap r=63
        assert.near(-135, Vec.AngleOf(x, y), 1e-9)      -- atan2 wraps 225 to -135
    end)
end)
