local S = dofile("Test/support.lua")

local function build()
    local ns = S.newNs()
    local module
    ns.ModuleManager = {
        Register = function(_, value) module = value; return value end,
    }
    S.load(ns, "Lib/Color.lua")
    S.load(ns, "Lib/ColorCurve.lua")
    S.load(ns, "Core/Module.lua")
    S.load(ns, "Modules/Skins.lua")
    return ns, module
end

describe("Skin lifecycle", function()
    it("is abstract and guards Load/Unload transitions", function()
        local ns, owner = build()
        assert.has_error(function() ns.Skin:New(owner) end)

        local calls = {}
        local TestSkin = ns.Class.new("TestSkin", ns.Skin, {
            statics = { key = "test", label = "Test", settings = {} },
        })
        function TestSkin:OnLoad() calls[#calls + 1] = "load" end
        function TestSkin:OnUnload() calls[#calls + 1] = "unload" end

        local skin = TestSkin:New(owner)
        assert.is_true(skin:Load())
        assert.is_false(skin:Load())
        assert.is_true(skin:IsLoaded())
        assert.is_true(skin:Unload())
        assert.is_false(skin:Unload())
        assert.is_false(skin:IsLoaded())
        assert.are.equal("load", calls[1])
        assert.are.equal("unload", calls[2])
        assert.are.equal(2, #calls)
    end)

    it("rolls a failed load back through OnUnload", function()
        local ns, owner = build()
        local cleaned = false
        local BrokenSkin = ns.Class.new("BrokenSkin", ns.Skin, {
            statics = { key = "broken", label = "Broken", settings = {} },
        })
        function BrokenSkin:OnLoad() error("load failed") end
        function BrokenSkin:OnUnload() cleaned = true end

        local skin = BrokenSkin:New(owner)
        assert.has_error(function() skin:Load() end)
        assert.is_true(cleaned)
        assert.is_false(skin:IsLoaded())
    end)
end)
