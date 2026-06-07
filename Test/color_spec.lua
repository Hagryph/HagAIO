-- Test/color_spec.lua — ns.Color (Core/Color.lua), the RGBA value type.
local function colorNs()
    local ns = {}
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Type.lua"))("HagAIO", ns)
    assert(loadfile("Core/Color.lua"))("HagAIO", ns)
    return ns
end

describe("Color", function()
    it("unpacks r,g,b,a (alpha defaults to 1)", function()
        local c = colorNs().Color:New(0.2, 0.4, 0.6)
        local r, g, b, a = c:Unpack()
        assert.near(0.2, r); assert.near(0.4, g); assert.near(0.6, b); assert.are.equal(1, a)
    end)

    it("auto-accessors + value equality from ns.Type", function()
        local ns = colorNs()
        local c = ns.Color:New(0.2, 0.4, 0.6, 0.5)
        assert.near(0.2, c:R()); assert.near(0.5, c:A())
        assert.is_true(ns.Color:New(1, 0, 0) == ns.Color:New(1, 0, 0))
        assert.is_false(ns.Color:New(1, 0, 0) == ns.Color:New(0, 1, 0))
    end)

    it("WithAlpha returns a new colour, leaving the original untouched", function()
        local c = colorNs().Color:New(0.2, 0.4, 0.6, 1)
        local dim = c:WithAlpha(0.3)
        assert.near(0.3, dim:A())
        assert.are.equal(1, c:A())          -- immutable
        assert.near(0.2, dim:R())           -- rgb carried over
    end)

    it("Hex round-trips with FromHex", function()
        local ns = colorNs()
        assert.are.equal("4ab3e6", ns.Color:New(0.29, 0.702, 0.902):Hex())
        local c = ns.Color.FromHex("4ab3e6")
        assert.are.equal("4ab3e6", c:Hex())
        assert.is_nil(ns.Color.FromHex("nope"))
    end)
end)
