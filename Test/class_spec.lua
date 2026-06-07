local S = dofile("Test/support.lua")

local function classNs()
    local ns = {}
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    return ns
end

describe("class.super", function()
    it("calls the parent class's version of a method (dot + explicit self)", function()
        local ns = classNs()
        local Base = ns.Class.new("Base")
        function Base:Greet() return "base" end
        local Sub = ns.Class.new("Sub", Base)
        function Sub:Greet() return Sub.super.Greet(self) .. "+sub" end
        assert.are.equal("base+sub", Sub:New():Greet())
    end)

    it("passes arguments through and returns the result", function()
        local ns = classNs()
        local Base = ns.Class.new("Base")
        function Base:Add(a, b) return a + b end
        local Sub = ns.Class.new("Sub", Base)
        function Sub:Add(a, b) return Sub.super.Add(self, a, b) * 10 end
        assert.are.equal(70, Sub:New():Add(3, 4))
    end)

    it("resolves through an inserted intermediate (no hard-coded ancestor)", function()
        local ns = classNs()
        local Base = ns.Class.new("Base")
        function Base:Tag() return "B" end
        local Mid = ns.Class.new("Mid", Base)      -- intermediate, no Tag of its own
        local Leaf = ns.Class.new("Leaf", Mid)
        function Leaf:Tag() return Leaf.super.Tag(self) .. "L" end
        -- Leaf.super is Mid; Mid inherits Base:Tag -> still found, not bypassed.
        assert.are.equal("BL", Leaf:New():Tag())
    end)
end)

describe("Loggable identity via the constructor chain", function()
    it("Module/Submodule/Service all get GetName from the shared base", function()
        local ns = S.newNs()                       -- loads Loggable -> Component -> Service
        local Svc = ns.Class.new("Svc", ns.Service):New("MySvc")
        assert.are.equal("MySvc", Svc:GetName())   -- inherited from ns.Loggable
        local Mod = ns.Class.new("Mod", ns.Component)
        function Mod:_SettingsDB() return {} end
        assert.are.equal("MyMod", Mod:New("MyMod"):GetName())
    end)
end)
