local S = dofile("Test/support.lua")

-- A Component subclass wired to real EventBus / Scheduler / Hooks over stubbed
-- frames + clock, so the auto-released resource helpers can be exercised end-to-end.
local function rig()
    local clock = S.newClock()
    _G.GetTime = clock.GetTime
    _G.C_Timer = clock.C_Timer
    _G.hooksecurefunc = function(obj, method, post)
        local orig = obj[method]
        obj[method] = function(...) if orig then orig(...) end; post(...) end
    end
    local frames = S.stubFrames()
    local ns = S.newNs()
    S.load(ns, "Services/EventBus.lua");  ns._captured["EventBus"]:OnInitialize()
    S.load(ns, "Services/Scheduler.lua"); ns._captured["Scheduler"]:OnInitialize()
    S.load(ns, "Services/Hooks.lua");     ns._captured["Hooks"]:OnInitialize()
    local C = ns.Class.new("C", ns.Component)
    function C:_SettingsNamespace() return "test" end
    return C:New(), ns, frames, clock
end

describe("Component resources", function()
    it("On subscribes; _ReleaseAll unsubscribes", function()
        local c, _, frames = rig()
        local n = 0
        c:On("E", function() n = n + 1 end)
        frames[1]:Fire("E"); assert.are.equal(1, n)
        c:_ReleaseAll()
        frames[1]:Fire("E"); assert.are.equal(1, n)
    end)

    it("Subscribe handles custom messages and is released on teardown", function()
        local c, ns = rig()
        local n = 0
        c:Subscribe("MSG", function() n = n + 1 end)
        ns.EventBus:Emit("MSG"); assert.are.equal(1, n)
        c:_ReleaseAll()
        ns.EventBus:Emit("MSG"); assert.are.equal(1, n)
    end)

    it("Every / After timers are cancelled on teardown", function()
        local c, _, _, clock = rig()
        local n, once = 0, 0
        c:Every(1, function() n = n + 1 end)
        c:After(3, function() once = once + 1 end)
        clock.advance(2); assert.are.equal(2, n)
        c:_ReleaseAll()
        clock.advance(5)
        assert.are.equal(2, n)     -- ticker cancelled
        assert.are.equal(0, once)  -- one-shot cancelled before it fired
    end)

    it("Hook installs and is removed via UnhookAll on teardown", function()
        local c = rig()
        local obj = { go = function() end }
        local n = 0
        c:Hook(obj, "go", function() n = n + 1 end)
        obj.go(); assert.are.equal(1, n)
        c:_ReleaseAll()
        obj.go(); assert.are.equal(1, n)
    end)

    it("named scopes release independently of the default scope", function()
        local c, _, frames = rig()
        local a, b = 0, 0
        c:On("A", function() a = a + 1 end)           -- default scope
        c:On("B", function() b = b + 1 end, "spec")   -- named scope
        c:ReleaseScope("spec")
        frames[1]:Fire("A"); frames[1]:Fire("B")
        assert.are.equal(1, a)   -- default still active
        assert.are.equal(0, b)   -- spec released
    end)

    it("Throttled wrapper's pending trailing call is cancelled on teardown", function()
        local c, _, _, clock = rig()
        local n = 0
        local f = c:Throttled(1, function() n = n + 1 end)
        f()             -- leading call (immediate)
        assert.are.equal(1, n)
        f()             -- coalesced -> pending trailing
        c:_ReleaseAll() -- cancels the pending trailing call
        clock.advance(2)
        assert.are.equal(1, n)
    end)
end)
