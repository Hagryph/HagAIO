local S = dofile("Test/support.lua")

-- hooksecurefunc stub: post-hook runs after the original (like WoW). `stats.hooks`
-- counts how many permanent dispatchers were installed.
local function setup()
    local stats = { hooks = 0 }
    _G.hooksecurefunc = function(obj, method, post)
        stats.hooks = stats.hooks + 1
        local orig = obj[method]
        obj[method] = function(...) if orig then orig(...) end; post(...) end
    end
    local ns = S.newNs()
    S.load(ns, "Services/Hooks.lua")
    local h = ns._captured["Hooks"]; h:OnInitialize()
    return h, stats
end

describe("Hooks", function()
    it("installs ONE dispatcher per target and runs all handlers", function()
        local h, stats = setup()
        local obj = { go = function() end }
        local n = 0
        h:Secure(obj, "go", function() n = n + 1 end)
        h:Secure(obj, "go", function() n = n + 1 end)
        assert.are.equal(1, stats.hooks)   -- dispatcher reused
        obj.go()
        assert.are.equal(2, n)             -- both handlers ran
    end)

    it("handle:Unhook() removes a single handler; others still fire", function()
        local h = setup()
        local obj = { go = function() end }
        local a, b = 0, 0
        local hA = h:Secure(obj, "go", function() a = a + 1 end)
        h:Secure(obj, "go", function() b = b + 1 end)
        hA:Unhook()
        obj.go()
        assert.are.equal(0, a)
        assert.are.equal(1, b)
    end)

    it("UnhookAll drops every hook an owner installed", function()
        local h = setup()
        local obj = { go = function() end }
        local owner, n = {}, 0
        h:Secure(obj, "go", function() n = n + 1 end, owner)
        h:Secure(obj, "go", function() n = n + 1 end, owner)
        h:UnhookAll(owner)
        obj.go()
        assert.are.equal(0, n)
    end)

    it("handles are distinct objects", function()
        local h = setup()
        local obj = { go = function() end }
        local hA = h:Secure(obj, "go", function() end)
        local hB = h:Secure(obj, "go", function() end)
        assert.are_not.equal(hA, hB)
    end)

    it("the global-function form hooks _G[name]", function()
        local h = setup()
        _G.MyGlobalFn = function() end
        local n = 0
        h:Secure("MyGlobalFn", function() n = n + 1 end)
        _G.MyGlobalFn()
        assert.are.equal(1, n)
        _G.MyGlobalFn = nil
    end)
end)
