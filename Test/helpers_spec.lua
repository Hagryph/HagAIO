-- Test/helpers_spec.lua — ns.Helpers.DeepCopy (Lib/Helpers.lua), the shared pure deep-copy.
local S = dofile("Test/support.lua")

local function loadHelpers()
    local ns = S.newNs()   -- Helpers registers via ns.LibManager:RegisterValue (stubbed by the rig)
    return ns.Helpers      -- the rig already loads Lib/Helpers.lua
end

describe("Helpers.DeepCopy", function()
    local H = loadHelpers()

    it("returns non-tables unchanged", function()
        assert.are.equal(5, H.DeepCopy(5))
        assert.are.equal("x", H.DeepCopy("x"))
        assert.is_true(H.DeepCopy(true))
        assert.is_nil(H.DeepCopy(nil))
    end)

    it("clones a flat table to a new identity with equal contents", function()
        local src = { 1, 2, 3, a = "b" }
        local copy = H.DeepCopy(src)
        assert.are_not.equal(src, copy)
        assert.are.equal(1, copy[1])
        assert.are.equal(3, copy[3])
        assert.are.equal("b", copy.a)
    end)

    it("clones nested tables (deep, not shared by reference)", function()
        local src = { rgb = { 0.5, 0.6, 0.7 }, nested = { inner = { v = 1 } } }
        local copy = H.DeepCopy(src)
        assert.are_not.equal(src.rgb, copy.rgb)
        assert.are_not.equal(src.nested.inner, copy.nested.inner)
        assert.are.equal(0.6, copy.rgb[2])
        assert.are.equal(1, copy.nested.inner.v)
    end)

    it("mutating the copy never touches the source (the seeding-defaults guarantee)", function()
        local src = { c = { 1, 1, 1 } }
        local copy = H.DeepCopy(src)
        copy.c[1] = 0
        copy.added = true
        assert.are.equal(1, src.c[1])   -- source untouched
        assert.is_nil(src.added)
    end)
end)

describe("Helpers.DeepEqual", function()
    local H = loadHelpers()

    it("compares nested tables structurally in both directions", function()
        assert.is_true(H.DeepEqual({ rgb = { 1, 0.5, 0 }, enabled = false },
                                   { enabled = false, rgb = { 1, 0.5, 0 } }))
        assert.is_false(H.DeepEqual({ a = 1 }, { a = 1, b = 2 }))
        assert.is_false(H.DeepEqual({ nested = { x = 1 } }, { nested = { x = 2 } }))
    end)
end)

describe("Helpers.Clamp01", function()
    local H = loadHelpers()

    it("clamps outside values and preserves the unit interval", function()
        assert.are.equal(0, H.Clamp01(-0.1))
        assert.are.equal(0, H.Clamp01(0))
        assert.are.equal(0.4, H.Clamp01(0.4))
        assert.are.equal(1, H.Clamp01(1))
        assert.are.equal(1, H.Clamp01(2))
    end)
end)
