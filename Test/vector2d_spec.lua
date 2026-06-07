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
end)
