-- Test/interface_spec.lua — ns.Interface (Core/Interface.lua) + Class.new opts.implements.
local function ns_()
    local ns = {}
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Interface.lua"))("HagAIO", ns)
    return ns
end

describe("Interface", function()
    it("assertClass passes when every method is present", function()
        local ns = ns_()
        local IDrawable = ns.Interface.new("IDrawable", { "Draw" })
        local Box = ns.Class.new("Box")
        function Box:Draw() end
        assert.is_true(ns.Interface.assertClass(Box, IDrawable))
    end)

    it("assertClass raises naming the missing method + interface", function()
        local ns = ns_()
        local IDrawable = ns.Interface.new("IDrawable", { "Draw", "Bounds" })
        local Box = ns.Class.new("Box")
        function Box:Draw() end
        local ok, err = pcall(ns.Interface.assertClass, Box, IDrawable)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("Bounds") ~= nil)
        assert.is_true(tostring(err):find("IDrawable") ~= nil)
    end)

    it("isImplementedBy is the non-throwing form", function()
        local ns = ns_()
        local I = ns.Interface.new("I", { "A", "B" })
        local Partial = ns.Class.new("Partial")
        function Partial:A() end
        assert.is_false(ns.Interface.isImplementedBy(Partial, I))
        function Partial:B() end
        assert.is_true(ns.Interface.isImplementedBy(Partial, I))
    end)

    it("opts.implements verifies at first :New() (after methods are defined)", function()
        local ns = ns_()
        local I = ns.Interface.new("I", { "Required" })
        local Good = ns.Class.new("Good", nil, { implements = { I } })
        function Good:Required() return 1 end
        assert.are.equal(1, Good:New():Required())   -- check passes

        local Bad = ns.Class.new("Bad", nil, { implements = { I } })
        assert.is_false((pcall(function() return Bad:New() end)))  -- missing Required
    end)

    it("a SUBCLASS inherits the contract and is verified at its own first :New()", function()
        local ns = ns_()
        local I = ns.Interface.new("I", { "Required" })
        local Base = ns.Class.new("Base", nil, { implements = { I } })
        function Base:Required() return 1 end
        local GoodSub = ns.Class.new("GoodSub", Base)            -- inherits Required
        assert.are.equal(1, GoodSub:New():Required())

        local Base2 = ns.Class.new("Base2", nil, { abstract = true, implements = { I } })
        local BadSub = ns.Class.new("BadSub", Base2)             -- never defines Required
        local ok, err = pcall(function() return BadSub:New() end)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("Required") ~= nil)    -- the abstract base's contract bites

        local GoodSub2 = ns.Class.new("GoodSub2", Base2)         -- sibling DOES implement it
        function GoodSub2:Required() return 2 end
        assert.are.equal(2, GoodSub2:New():Required())           -- BadSub's failure didn't poison it
    end)
end)
