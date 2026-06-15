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

    it("verifies a contract declared GENERATIONS up, satisfied anywhere down the chain", function()
        local ns = ns_()
        local I = ns.Interface.new("I", { "Required" })
        -- A(abstract, implements I) -> B -> C -> D ; Required is defined on C (a middle generation).
        local A = ns.Class.new("A", nil, { abstract = true, implements = { I } })
        local B = ns.Class.new("B", A)
        local C = ns.Class.new("C", B)
        function C:Required() return 42 end
        local D = ns.Class.new("D", C)
        assert.are.equal(42, D:New():Required())   -- the grandparent's contract is found + satisfied
        assert.are.equal(42, C:New():Required())   -- and at the concrete class that defines it

        -- A sibling deep chain that never defines Required fails at its own first :New(), naming it.
        local B2 = ns.Class.new("B2", A)
        local C2 = ns.Class.new("C2", B2)          -- nothing defines Required anywhere on this branch
        local ok, err = pcall(function() return C2:New() end)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("Required") ~= nil)
        assert.is_true(tostring(err):find("'C2'") ~= nil)   -- reported against the concrete class
    end)

    it("accumulates SEPARATE interfaces declared at different levels of the hierarchy", function()
        local ns = ns_()
        local IA = ns.Interface.new("IA", { "A" })
        local IB = ns.Interface.new("IB", { "B" })
        local Base = ns.Class.new("Base", nil, { abstract = true, implements = { IA } })
        local Mid  = ns.Class.new("Mid", Base, { implements = { IB } })   -- adds a 2nd contract midway
        local Leaf = ns.Class.new("Leaf", Mid)

        -- Missing B (only A defined) -> the mid-level contract bites.
        function Leaf:A() return "a" end
        local ok, err = pcall(function() return Leaf:New() end)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("'B'") ~= nil)

        -- Define B too -> BOTH inherited contracts (IA from Base, IB from Mid) are satisfied.
        function Leaf:B() return "b" end
        local inst = Leaf:New()
        assert.are.equal("a", inst:A())
        assert.are.equal("b", inst:B())
    end)

    it("verifies each concrete class ONCE: the per-class latch isn't re-checked after the first :New()", function()
        local ns = ns_()
        local I = ns.Interface.new("I", { "Required" })
        local Base = ns.Class.new("Base", nil, { abstract = true, implements = { I } })
        local Sub = ns.Class.new("Sub", Base)
        function Sub:Required() return true end
        assert(Sub:New())                           -- first :New() verifies + latches
        Sub.Required = nil                          -- break the contract AFTER the latch is set
        assert.is_true(pcall(function() return Sub:New() end))   -- second :New() does NOT re-verify
    end)
end)
