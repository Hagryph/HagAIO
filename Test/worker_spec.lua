local S = dofile("Test/support.lua")

-- Locks the frame-budgeted, event-driven Worker (Services/Worker.lua): one-time Queue with result
-- delivery over the EventBus, cooperative Yield budgeting, Register coalescing, Cancel, OWNER binding
-- (work runs only while the owner is enabled, gated by HagAIO_OwnerState), and the timer-reminded
-- :Every. We drive the budget by hand (debugprofilestop) and the timers via the harness clock.

local function newWorker()
    S.stubFrames()                       -- CreateFrame for the EventBus driver
    local ns = S.newNs()
    local clock = S.newClock()
    _G.C_Timer = clock.C_Timer           -- Worker pump reschedule + Scheduler tickers
    _G.GetTime = clock.GetTime
    S.load(ns, "Services/EventBus.lua")
    S.load(ns, "Services/Scheduler.lua")
    S.load(ns, "Services/Worker.lua")
    local bus = ns._captured["EventBus"]; bus:OnInitialize()
    local worker = ns._captured["Worker"]; worker:OnInitialize()
    local profile = { ms = 0 }
    _G.debugprofilestop = function() return profile.ms end
    return worker, bus, ns, profile, clock
end

local function fakeOwner()
    local o = { enabled = true }
    function o:IsEnabled() return self.enabled end
    function o:GetName() return "FakeOwner" end
    return o
end

describe("Worker", function()
    it("runs a queued job and delivers its result over the EventBus (keyed by its handle)", function()
        local worker, bus = newWorker()
        local got
        bus:Subscribe("HagAIO_Done", function(_, h, result) got = { h = h, result = result } end)
        local handle = worker:Queue(function() return 42 end, { message = "HagAIO_Done" })
        worker:_Pump()
        assert.are.equal(handle, got.h)    -- the handle from Queue IS the job's identity on the bus
        assert.are.equal(42, got.result)
    end)

    it("emits the default done message when a job has no custom message / no result", function()
        local worker, bus = newWorker()
        local fired = false
        bus:Subscribe("HagAIO_WorkerDone", function() fired = true end)
        worker:Queue(function() end)
        worker:_Pump()
        assert.is_true(fired)
    end)

    it("calls an onDone callback with the result", function()
        local worker = newWorker()
        local seen
        worker:Queue(function() return "ok" end, { onDone = function(r) seen = r end })
        worker:_Pump()
        assert.are.equal("ok", seen)
    end)

    it("spreads a long job across frames via Yield once the budget is spent", function()
        local worker, bus, ns, profile = newWorker()
        local steps, done = 0, false
        bus:Subscribe("HagAIO_WorkerDone", function() done = true end)
        worker:Queue(function()
            for _ = 1, 5 do
                steps = steps + 1
                profile.ms = profile.ms + 1    -- each step "costs" 1ms of this frame
                ns.Worker:Yield()              -- yields once the 2ms budget is exceeded
            end
        end)
        worker:_Pump()                         -- frame 1: 1,2 -> budget spent after the 2nd step
        assert.is_false(done)
        assert.is_true(steps >= 1 and steps < 5)
        profile.ms = 0; worker:_Pump()
        profile.ms = 0; worker:_Pump()
        assert.are.equal(5, steps)
        assert.is_true(done)
    end)

    it("Run drives a loop-free stepper until it returns falsy", function()
        local worker = newWorker()
        local n = 0
        worker:Run(function() n = n + 1; return n < 3 end)   -- one unit per call; truthy = more
        worker:_Pump()                                       -- budget unspent -> runs all steps
        assert.are.equal(3, n)
    end)

    it("steps multiple iterators round-robin so they progress together", function()
        local worker, _, ns = newWorker()
        local order = {}
        worker:Queue(function() for i = 1, 2 do order[#order + 1] = "A" .. i; ns.Worker:Yield() end end)
        worker:Queue(function() for i = 1, 2 do order[#order + 1] = "B" .. i; ns.Worker:Yield() end end)
        worker:_Pump()                                  -- budget unspent (no time advanced) -> drains both
        assert.are.equal("A1,B1,A2,B2", table.concat(order, ","))   -- interleaved, not A1,A2 then B1,B2
    end)

    it("handle:Cancel() drops a still-pending job (and only that job)", function()
        local worker = newWorker()
        local ran, otherRan = false, false
        local handle = worker:Queue(function() ran = true end)
        worker:Queue(function() otherRan = true end)
        handle:Cancel()
        handle:Cancel()                    -- second cancel is a safe no-op
        worker:_Pump()
        assert.is_false(ran)
        assert.is_true(otherRan)           -- identity-based: the other job is untouched
    end)

    it("Register coalesces rapid fires into one run, honouring the last fire", function()
        local worker, bus = newWorker()
        local runs = 0
        local handle = worker:Register("FAKE_EVENT", function() runs = runs + 1 end)
        local driver = bus:_p().frame                  -- the EventBus driver frame (stub :Fire dispatches)
        driver:Fire("FAKE_EVENT")                      -- fire 1 -> queues a job (pending)
        driver:Fire("FAKE_EVENT")                      -- fire 2 -> coalesced (again=true), no 2nd queue
        worker:_Pump()                                 -- runs job 1; _after sees `again` -> re-queues once
        worker:_Pump()                                 -- runs the coalesced re-run (if not already this frame)
        assert.are.equal(2, runs)
        handle.Unregister()
    end)

    -- ---- owner binding ----------------------------------------------------------------------------
    it("Queue with a disabled owner drops the work", function()
        local worker = newWorker()
        local owner = fakeOwner(); owner.enabled = false
        local ran = false
        local handle = worker:Queue(function() ran = true end, { owner = owner })
        worker:_Pump()
        assert.is_nil(handle)
        assert.is_false(ran)
    end)

    it("owner-bound Register only runs while the owner is enabled", function()
        local worker, bus, ns = newWorker()
        local owner = fakeOwner()
        local runs = 0
        worker:Register("FAKE_EVENT", function() runs = runs + 1 end, { owner = owner })
        local driver = bus:_p().frame
        driver:Fire("FAKE_EVENT"); worker:_Pump()
        assert.are.equal(1, runs)                       -- enabled -> ran
        owner.enabled = false
        ns.EventBus:Emit("HagAIO_OwnerState", owner, false)
        driver:Fire("FAKE_EVENT"); worker:_Pump()
        assert.are.equal(1, runs)                       -- disabled -> did NOT run
        owner.enabled = true
        ns.EventBus:Emit("HagAIO_OwnerState", owner, true)
        driver:Fire("FAKE_EVENT"); worker:_Pump()
        assert.are.equal(2, runs)                       -- re-enabled -> ran again
    end)

    it("a job cancelled PENDING by owner-disable doesn't deadlock the runner after re-enable", function()
        local worker, bus, ns = newWorker()
        local owner = fakeOwner()
        local runs = 0
        worker:Register("FAKE_EVENT", function() runs = runs + 1 end, { owner = owner })
        local driver = bus:_p().frame
        driver:Fire("FAKE_EVENT")                       -- queued (pending), NOT yet pumped
        owner.enabled = false
        ns.EventBus:Emit("HagAIO_OwnerState", owner, false)   -- cancels the pending job
        worker:_Pump()
        assert.are.equal(0, runs)
        owner.enabled = true
        ns.EventBus:Emit("HagAIO_OwnerState", owner, true)
        driver:Fire("FAKE_EVENT"); worker:_Pump()
        assert.are.equal(1, runs)                       -- the coalescing guard was released, so it fires
    end)

    it("Every reminds via a timer and pauses while the owner is disabled (no polling)", function()
        local worker, _, ns, _, clock = newWorker()
        local owner = fakeOwner()
        local runs = 0
        worker:Every(1, function() runs = runs + 1 end, { owner = owner })
        clock.advance(1); worker:_Pump()                -- ticker fires -> queued -> ran
        assert.are.equal(1, runs)
        owner.enabled = false
        ns.EventBus:Emit("HagAIO_OwnerState", owner, false)
        clock.advance(3); worker:_Pump()                -- timer paused -> nothing queued
        assert.are.equal(1, runs)
        owner.enabled = true
        ns.EventBus:Emit("HagAIO_OwnerState", owner, true)
        clock.advance(1); worker:_Pump()                -- timer restarted
        assert.are.equal(2, runs)
    end)
end)
