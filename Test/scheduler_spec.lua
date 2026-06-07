local S = dofile("Test/support.lua")

local function newSched()
    local clock = S.newClock()
    _G.GetTime = clock.GetTime
    _G.C_Timer = clock.C_Timer
    local ns = S.newNs()
    S.load(ns, "Services/Scheduler.lua")
    local s = ns._captured["Scheduler"]
    s:OnInitialize()
    return s, clock
end

describe("Scheduler", function()
    it("Every fires repeatedly until cancelled", function()
        local s, clock = newSched()
        local n = 0
        local h = s:Every(1, function() n = n + 1 end)
        clock.advance(3.5)
        assert.are.equal(3, n)
        h:Cancel()
        clock.advance(5)
        assert.are.equal(3, n)
    end)

    it("After fires once and is cancellable", function()
        local s, clock = newSched()
        local fired = false
        local h = s:After(2, function() fired = true end)
        clock.advance(1)
        assert.is_false(fired)
        clock.advance(2)
        assert.is_true(fired)
    end)

    it("After can be cancelled before it fires", function()
        local s, clock = newSched()
        local fired = false
        local h = s:After(2, function() fired = true end)
        h:Cancel()
        clock.advance(5)
        assert.is_false(fired)
    end)

    it("Debounced runs once, delay after the LAST call", function()
        local s, clock = newSched()
        local n, last = 0, nil
        local f = s:Debounced(1, function(v) n = n + 1; last = v end)
        f("a"); clock.advance(0.5)
        f("b"); clock.advance(0.5)   -- restarts the countdown
        assert.are.equal(0, n)
        clock.advance(1)             -- 1s after "b"
        assert.are.equal(1, n)
        assert.are.equal("b", last)
    end)

    it("Throttled runs a leading call + one coalesced trailing call", function()
        local s, clock = newSched()
        local n, last = 0, nil
        local f = s:Throttled(1, function(v) n = n + 1; last = v end)
        f("a")                       -- leading: immediate
        assert.are.equal(1, n)
        assert.are.equal("a", last)
        f("b"); f("c")               -- within the cooldown -> coalesced
        assert.are.equal(1, n)
        clock.advance(1)             -- cooldown ends -> trailing call with latest "c"
        assert.are.equal(2, n)
        assert.are.equal("c", last)
    end)

    it("Every stops after the iteration count", function()
        local s, clock = newSched()
        local n = 0
        s:Every(1, function() n = n + 1 end, 2)
        clock.advance(10)
        assert.are.equal(2, n)
    end)

    it("cancelling an already-fired After is a harmless no-op", function()
        local s, clock = newSched()
        local n = 0
        local h = s:After(1, function() n = n + 1 end)
        clock.advance(1)
        assert.are.equal(1, n)
        assert.is_true(pcall(function() h:Cancel() end))
        clock.advance(5)
        assert.are.equal(1, n)
    end)

    it("runs overlapping tickers independently", function()
        local s, clock = newSched()
        local a, b = 0, 0
        s:Every(1, function() a = a + 1 end)
        s:Every(2, function() b = b + 1 end)
        clock.advance(4)
        assert.are.equal(4, a)
        assert.are.equal(2, b)
    end)
end)
