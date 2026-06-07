-- Test/mixin_spec.lua — ns.Mixin (Core/Mixin.lua) + Class.new opts.mixins.
local function ns_()
    local ns = {}
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Mixin.lua"))("HagAIO", ns)
    return ns
end

describe("Mixin", function()
    it("merges methods into a class via opts.mixins", function()
        local ns = ns_()
        local Greet = ns.Mixin.new("Greet", { Hello = function() return "hi" end })
        local Foo = ns.Class.new("Foo", nil, { mixins = { Greet } })
        assert.are.equal("hi", Foo:New():Hello())
    end)

    it("applies explicitly with applyTo and reports its name", function()
        local ns = ns_()
        local Greet = ns.Mixin.new("Greet", { Hello = function() return "hi" end })
        local Bar = ns.Class.new("Bar")
        ns.Mixin.applyTo(Bar, Greet)
        assert.are.equal("hi", Bar:New():Hello())
        assert.are.equal("Greet", ns.Mixin.nameOf(Greet))
    end)

    it("a method defined on the class overrides the mixin", function()
        local ns = ns_()
        local M = ns.Mixin.new("M", { Val = function() return "mixin" end })
        local C = ns.Class.new("C", nil, { mixins = { M } })
        function C:Val() return "own" end
        assert.are.equal("own", C:New():Val())
    end)
end)
