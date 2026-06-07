local S = dofile("Test/support.lua")

local function withComponent()
    local ns = S.newNs()
    S.load(ns, "Core/Component.lua")
    return ns
end

describe("Component abstract _SettingsDB", function()
    it("errors when a subclass uses settings without overriding _SettingsDB", function()
        local ns = withComponent()
        local Bad = ns.Class.new("Bad", ns.Component)
        local inst = Bad:New()
        local ok, err = pcall(function() return inst:GetSetting("k") end)
        assert.is_false(ok)
        assert.is_true(tostring(err):find("_SettingsDB") ~= nil)  -- message names the method
    end)

    it("works once a subclass provides _SettingsDB", function()
        local ns = withComponent()
        local Good = ns.Class.new("Good", ns.Component)
        function Good:_SettingsDB() return self.store end
        local inst = Good:New()
        inst.store = { k = 5 }
        assert.are.equal(5, inst:GetSetting("k"))
    end)
end)
