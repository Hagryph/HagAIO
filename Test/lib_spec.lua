local S = dofile("Test/support.lua")

-- The Lib tier (Core/Lib.lua + Core/LibManager.lua): a pure-logic helper published at
-- ns.<Name>, with no Logger/lifecycle/graph. Load the real Registry + Lib + LibManager, plus
-- Mixin + Contributions (Lib mixes in ns.Publishable for the shared _Publish).
local function realLibNs()
    local ns = { UI = {} }
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Mixin.lua"))("HagAIO", ns)
    assert(loadfile("Core/Contributions.lua"))("HagAIO", ns)   -- defines ns.Publishable
    assert(loadfile("Core/Registry.lua"))("HagAIO", ns)
    assert(loadfile("Core/Lib.lua"))("HagAIO", ns)
    assert(loadfile("Core/LibManager.lua"))("HagAIO", ns)
    return ns
end

describe("Lib tier", function()
    it("LibManager:Register publishes the lib at ns.<Name>, ready immediately", function()
        local ns = realLibNs()
        local Geo = ns.Class.new("Geo", ns.Lib)
        function Geo:Five() return 5 end
        local returned = ns.LibManager:Register(Geo:New("Geo"))
        assert(ns.Geo ~= nil)               -- published
        assert.are.equal(5, ns.Geo:Five())
        assert.are.equal(ns.Geo, returned)  -- Register returns the instance
    end)

    it("a lib has no logging surface (it is not a Service/Component)", function()
        local ns = realLibNs()
        local L = ns.Class.new("L", ns.Lib):New("L")
        assert.is_nil(L.GetLog)         -- libs don't inherit ns.Loggable
        assert.is_nil(L._AttachLogger)
        assert.are.equal("L", L:GetName())
    end)

    it("rejects a duplicate lib name", function()
        local ns = realLibNs()
        ns.LibManager:Register(ns.Class.new("A", ns.Lib):New("Dup"))
        local ok = pcall(function()
            ns.LibManager:Register(ns.Class.new("B", ns.Lib):New("Dup"))
        end)
        assert.is_false(ok)
    end)
end)
