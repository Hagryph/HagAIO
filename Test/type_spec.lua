-- Test/type_spec.lua — ns.Type, the value-type factory (Core/Type.lua).
local function typeNs()
    local ns = {}
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Type.lua"))("HagAIO", ns)
    return ns
end

describe("Type", function()
    it("constructs from positional fields with generated accessors", function()
        local P = typeNs().Type.new("Point", { "x", "y" })
        local p = P:New(3, 4)
        assert.are.equal(3, p:X())
        assert.are.equal(4, p:Y())
    end)

    it("fills nil args from defaults", function()
        local P = typeNs().Type.new("Point", { "x", "y" }, { x = 0, y = 0 })
        local p = P:New()
        assert.are.equal(0, p:X())
        assert.are.equal(0, p:Y())
        assert.are.equal(7, P:New(7):X())   -- second arg defaults
    end)

    it("compares by VALUE (__eq), and only within the same type", function()
        local ns = typeNs()
        local P = ns.Type.new("Point", { "x", "y" })
        local Q = ns.Type.new("Other", { "x", "y" })
        assert.is_true(P:New(1, 2) == P:New(1, 2))
        assert.is_false(P:New(1, 2) == P:New(1, 3))
        assert.is_false(P:New(1, 2) == Q:New(1, 2))  -- different type, never equal
    end)

    it("prints a readable tostring", function()
        local P = typeNs().Type.new("Point", { "x", "y" })
        assert.are.equal("Point(1, 2)", tostring(P:New(1, 2)))
    end)

    it("keeps fields private and supports added methods", function()
        local P = typeNs().Type.new("Point", { "x", "y" })
        function P:Sum() return self:X() + self:Y() end
        local p = P:New(3, 4)
        assert.are.equal(7, p:Sum())
        assert.is_nil(p.x)   -- fields live in :_p(), not as public instance fields
    end)
end)
