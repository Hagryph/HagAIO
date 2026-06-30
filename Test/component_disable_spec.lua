local S = dofile("Test/support.lua")

-- EXTENSIVE disable simulation for ns.Component's auto-released resource registry -- the path EVERY
-- module/submodule takes when it disables (Module:Disable / Submodule:Disable -> _ReleaseAll) or swaps
-- a named scope (ReleaseScope, e.g. the Monk "spec" scope). Exercises the C1 teardown-registry rewrite
-- (doubly-linked list, O(1) self-removing self:After, LIFO) under: full disable, named-scope release,
-- re-enable re-wiring, mid-flight timer cancellation, the latch + re-arm idiom (CVars / Monk markers),
-- and stress (no accumulation, no stale fires). A Component subclass stands in for any real module;
-- "disable" is modelled as _ReleaseAll + _SetEnabled(false), "enable" as _SetEnabled(true) + re-wire.

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
    -- Give it a NAME like every real module: ReleaseScope's teardown-error log does
    -- ("%s..."):format(self:_DisplayName()), and string.format("%s", nil) throws under Lua 5.1 (CI),
    -- though LuaJIT (local) tolerates it -- a nameless component would only fail in CI.
    return C:New("DisableSim"), ns, frames, clock
end

-- Count the LIVE teardown nodes in a scope (the linked list) -- 0 means nothing piled up.
local function scopeLen(c, scope)
    local s = c:_p()._scopes
    local sc = s and s[scope or "_default"]
    if not sc then return 0 end
    local n, node = 0, sc.head
    while node do n = n + 1; node = node.next end
    return n
end

-- ============================================================================================
describe("Component disable: every resource helper is torn down", function()
    it("On / Subscribe / Hook / Every / After / Throttled / Debounced all stop after disable", function()
        local c, ns, frames, clock = rig()
        local hits = setmetatable({}, { __index = function() return 0 end })
        local function bump(k) return function() hits[k] = hits[k] + 1 end end

        local obj = { go = function() end }
        c:On("E", bump("on"))
        c:Subscribe("MSG", bump("msg"))
        c:Hook(obj, "go", bump("hook"))
        c:Every(1, bump("every"))
        c:After(100, bump("after"))                          -- pending FAR past the disable
        local thr = c:Throttled(100, bump("thr")); thr(); thr() -- leading fires now; trailing pending (far out)
        local deb = c:Debounced(100, bump("deb")); deb()     -- pending far out

        -- everything is wired + has fired its immediate part; the 100s defers have NOT fired yet
        frames[1]:Fire("E"); ns.EventBus:Emit("MSG"); obj.go(); clock.advance(1)  -- Every ticks once
        assert.are.equal(1, hits.on); assert.are.equal(1, hits.msg)
        assert.are.equal(1, hits.hook); assert.are.equal(1, hits.every); assert.are.equal(1, hits.thr)

        c:_ReleaseAll()   -- DISABLE: every scope drained, hooks dropped

        -- nothing fires after disable, including the still-pending After / Throttled-trailing / Debounced
        frames[1]:Fire("E"); ns.EventBus:Emit("MSG"); obj.go()
        clock.advance(500)
        assert.are.equal(1, hits.on,   "event sub survived disable")
        assert.are.equal(1, hits.msg,  "message sub survived disable")
        assert.are.equal(1, hits.hook, "hook survived disable")
        assert.are.equal(1, hits.every,"ticker survived disable")
        assert.are.equal(0, hits.after,"pending one-shot fired after disable")
        assert.are.equal(1, hits.thr,  "throttled trailing fired after disable")
        assert.are.equal(0, hits.deb,  "debounced fired after disable")
        assert.are.equal(0, scopeLen(c), "teardown registry not empty after _ReleaseAll")
    end)

    it("OnUnit (unit-filtered) is released on disable", function()
        local c, _, frames = rig()
        local n = 0
        c:OnUnit("UNIT_POWER_UPDATE", { "player" }, function() n = n + 1 end)
        local unitFrame = frames[#frames]          -- OnUnit creates its own RegisterUnitEvent frame
        unitFrame:Fire("UNIT_POWER_UPDATE", "player"); assert.are.equal(1, n)
        c:_ReleaseAll()
        unitFrame:Fire("UNIT_POWER_UPDATE", "player"); assert.are.equal(1, n)
    end)
end)

-- ============================================================================================
describe("Component disable: timers + the leak-free registry", function()
    it("a pending self:After is cancelled by disable and leaves no thunk", function()
        local c, _, _, clock = rig()
        local fired = 0
        c:After(5, function() fired = fired + 1 end)
        assert.are.equal(1, scopeLen(c))       -- the cancel-thunk is queued
        c:_ReleaseAll()
        clock.advance(10)
        assert.are.equal(0, fired)
        assert.are.equal(0, scopeLen(c))
    end)

    it("a fired self:After self-removes -- 1000 cycles never accumulate", function()
        local c, _, _, clock = rig()
        local n = 0
        for _ = 1, 1000 do
            c:After(0, function() n = n + 1 end)
            clock.advance(1)                    -- fire the one-shot; it unlinks its own thunk
        end
        assert.are.equal(1000, n)
        assert.are.equal(0, scopeLen(c), "spent self:After thunks piled up (leak)")
    end)

    it("a self-rescheduling self:After chain stays bounded (the Monk orb-poll shape)", function()
        local c, _, _, clock = rig()
        local ticks = 0
        local function poll()
            ticks = ticks + 1
            if ticks < 200 then c:After(1, poll) end   -- re-arm one tick out, like the orb poll
        end
        poll()
        for _ = 1, 200 do clock.advance(1) end
        assert.are.equal(200, ticks)
        assert.is_true(scopeLen(c) <= 1, "self-rescheduling chain accumulated thunks")
    end)

    it("disable mid-chain stops a self-rescheduling self:After", function()
        local c, _, _, clock = rig()
        local ticks = 0
        local function poll() ticks = ticks + 1; c:After(1, poll) end
        poll()
        clock.advance(1); clock.advance(1)     -- a couple of ticks
        local atDisable = ticks
        c:_ReleaseAll()
        clock.advance(5)
        assert.are.equal(atDisable, ticks, "chain kept running after disable")
        assert.are.equal(0, scopeLen(c))
    end)
end)

-- ============================================================================================
describe("Component disable: named scopes", function()
    it("releasing one named scope leaves the default + other scopes intact", function()
        local c, _, frames = rig()
        local d, a, b = 0, 0, 0
        c:On("D", function() d = d + 1 end)            -- default
        c:On("A", function() a = a + 1 end, "spec")    -- named "spec"
        c:On("B", function() b = b + 1 end, "other")   -- named "other"
        c:ReleaseScope("spec")
        frames[1]:Fire("D"); frames[1]:Fire("A"); frames[1]:Fire("B")
        assert.are.equal(1, d); assert.are.equal(0, a); assert.are.equal(1, b)
        assert.are.equal(0, scopeLen(c, "spec"))      -- spec drained
        assert.is_true(scopeLen(c) >= 1)              -- the default scope (the D sub) is still live
    end)

    it("a named scope can be re-acquired after release (spec swap)", function()
        local c, _, frames = rig()
        local n = 0
        c:On("EV", function() n = n + 1 end, "spec")
        c:ReleaseScope("spec")
        frames[1]:Fire("EV"); assert.are.equal(0, n)       -- released
        c:On("EV", function() n = n + 1 end, "spec")       -- re-wire on a fresh "spec"
        frames[1]:Fire("EV"); assert.are.equal(1, n)
        c:ReleaseScope("spec")
        frames[1]:Fire("EV"); assert.are.equal(1, n)       -- released again
    end)

    it("_ReleaseAll drains the default AND every named scope", function()
        local c, _, frames = rig()
        local n = 0
        local function sub(e, s) c:On(e, function() n = n + 1 end, s) end
        sub("A"); sub("B", "spec"); sub("C", "combat"); sub("D", "aoe")
        c:_ReleaseAll()
        frames[1]:Fire("A"); frames[1]:Fire("B"); frames[1]:Fire("C"); frames[1]:Fire("D")
        assert.are.equal(0, n)
    end)
end)

-- ============================================================================================
describe("Component disable: the latch + re-arm idiom (CVars / Monk markers)", function()
    -- The pattern: a boolean latch coalesces repeated schedules; the defer clears it when it fires. A
    -- disable that CANCELS the pending defer leaves the latch SET, so re-enable must clear it (CVars
    -- OnEnable, MonkBase:Unload) or the next schedule early-returns forever.
    local function withLatch()
        local c, _, _, clock = rig()
        function c.Schedule(self)
            local p = self:_p()
            if p.pending then return end
            p.pending = true
            self:After(0, function() p.pending = false; p.fired = (p.fired or 0) + 1 end, "spec")
        end
        return c, clock
    end

    it("a disable mid-pending leaves the latch stuck -- the trap the reset guards", function()
        local c, clock = withLatch()
        c:Schedule()
        assert.is_true(c:_p().pending)
        c:ReleaseScope("spec")               -- cancels the defer; its body (which clears the latch) never runs
        clock.advance(5)
        assert.is_nil(c:_p().fired)           -- never fired
        assert.is_true(c:_p().pending)        -- STUCK -- a naive re-arm would early-return forever
    end)

    it("clearing the latch on re-enable lets it re-arm and fire", function()
        local c, clock = withLatch()
        c:Schedule(); c:ReleaseScope("spec")
        c:_p().pending = false                -- the re-enable / unload latch reset (CVars OnEnable, MonkBase:Unload)
        c:Schedule()
        assert.is_true(c:_p().pending)
        clock.advance(1)
        assert.are.equal(1, c:_p().fired)     -- the re-armed defer fired
    end)
end)

-- ============================================================================================
describe("Component disable: registry edge cases", function()
    it("teardowns run LIFO, and a remover excises one from the middle without breaking order", function()
        local c = rig()
        local order = {}
        c:OnTeardown(function() order[#order + 1] = "a" end)
        local removeB = c:OnTeardown(function() order[#order + 1] = "b" end)
        c:OnTeardown(function() order[#order + 1] = "c" end)
        removeB()                                       -- drop the middle node
        c:_ReleaseAll()
        assert.are.equal("c,a", table.concat(order, ","))   -- LIFO, b excised
    end)

    it("a teardown that registers a NEW teardown during release is still drained", function()
        local c = rig()
        local ran = {}
        c:OnTeardown(function()
            ran[#ran + 1] = "first"
            c:OnTeardown(function() ran[#ran + 1] = "added-during-release" end)
        end)
        c:_ReleaseAll()
        assert.are.equal("first,added-during-release", table.concat(ran, ","))
        assert.are.equal(0, scopeLen(c))
    end)

    it("the remover is idempotent and safe after the scope was already released", function()
        local c = rig()
        local remove = c:OnTeardown(function() end)
        c:_ReleaseAll()                                 -- node marked removed during the drain
        assert.is_true(pcall(function() remove(); remove() end))  -- stale double-remove is a safe no-op
        assert.are.equal(0, scopeLen(c))
    end)

    it("_ReleaseAll is idempotent (double disable runs each teardown once)", function()
        local c = rig()
        local n = 0
        c:OnTeardown(function() n = n + 1 end)
        c:_ReleaseAll(); c:_ReleaseAll()
        assert.are.equal(1, n)
    end)

    it("a teardown that throws is caught, and the rest still run", function()
        local c, ns = rig()
        ns.Logger = { Core = function() return { Warn = function() end } end }  -- known-good sink: ReleaseScope logs the caught error
        local ran = {}
        c:OnTeardown(function() ran[#ran + 1] = "after-boom" end)
        c:OnTeardown(function() error("boom") end)
        c:OnTeardown(function() ran[#ran + 1] = "before-boom" end)
        assert.is_true(pcall(function() c:_ReleaseAll() end))
        assert.are.equal("before-boom,after-boom", table.concat(ran, ","))  -- LIFO, the boom between is swallowed
    end)
end)

-- ============================================================================================
describe("Component disable: enable/disable cycles never leak", function()
    it("100 wire/disable cycles return the registry to empty each time", function()
        local c, ns, frames, clock = rig()
        local fires = 0
        for i = 1, 100 do
            c:_SetEnabled(true)
            c:On("CYCLE", function() fires = fires + 1 end)
            c:Every(1, function() end)
            c:After(0, function() end)
            clock.advance(1)                            -- fire the After (self-removes) + a tick
            frames[1]:Fire("CYCLE")                     -- the live sub fires
            c:_ReleaseAll(); c:_SetEnabled(false)       -- disable
            assert.are.equal(0, scopeLen(c), "cycle " .. i .. " leaked teardown nodes")
            assert.is_false(c:IsEnabled())
        end
        assert.are.equal(100, fires)                    -- one live CYCLE fire per cycle, never a stale one
    end)
end)
