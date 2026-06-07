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

describe("Component teardown", function()
    local function comp()
        local ns = withComponent()
        return ns.Class.new("C", ns.Component):New()
    end

    it("runs default-scope teardowns LIFO on _ReleaseAll", function()
        local c, order = comp(), {}
        c:OnTeardown(function() order[#order + 1] = 1 end)
        c:OnTeardown(function() order[#order + 1] = 2 end)
        c:_ReleaseAll()
        assert.are.equal(2, order[1])  -- last registered runs first
        assert.are.equal(1, order[2])
    end)

    it("ReleaseScope only tears down its own scope", function()
        local c, hits = comp(), {}
        c:OnTeardown(function() hits.default = true end)
        c:OnTeardown(function() hits.spec = true end, "spec")
        c:ReleaseScope("spec")
        assert.is_true(hits.spec)
        assert.is_nil(hits.default)    -- untouched
        c:_ReleaseAll()
        assert.is_true(hits.default)   -- now released
    end)

    it("a scope is run once and not again on a later release", function()
        local c, n = comp(), 0
        c:OnTeardown(function() n = n + 1 end, "spec")
        c:ReleaseScope("spec")
        c:ReleaseScope("spec")  -- already drained -> no-op
        c:_ReleaseAll()
        assert.are.equal(1, n)
    end)

    it("_ReleaseAll drains a scope a teardown thunk adds mid-teardown", function()
        local c, hits = comp(), {}
        c:OnTeardown(function()
            c:OnTeardown(function() hits.late = true end, "late")  -- added during teardown
        end)
        c:_ReleaseAll()
        assert.is_true(hits.late)  -- the next()-drain picks up the newly-added scope
    end)
end)
