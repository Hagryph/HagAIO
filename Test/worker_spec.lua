local S = dofile("Test/support.lua")

-- Locks the frame-budgeted Worker (Services/Worker.lua): one-time Queue with result delivery over the
-- EventBus, cooperative Yield budgeting (a long job spread across frames), event Register coalescing,
-- and Cancel. The driver frame's OnUpdate IS the pump; we call worker:_Pump() directly and drive
-- debugprofilestop() by hand so "this frame's budget" is fully controllable.

-- A Worker wired to a real EventBus + stub frames, with a controllable profile clock. Returns
-- (worker, bus, ns, profile) where profile is { ms } -- set profile.ms to simulate elapsed frame time.
local function newWorker()
    local frames = S.stubFrames()
    local ns = S.newNs()
    S.load(ns, "Services/EventBus.lua")
    S.load(ns, "Services/Worker.lua")
    local bus = ns._captured["EventBus"]; bus:OnInitialize()
    local worker = ns._captured["Worker"]; worker:OnInitialize()
    local profile = { ms = 0 }
    _G.debugprofilestop = function() return profile.ms end
    return worker, bus, ns, profile
end

describe("Worker", function()
    it("runs a queued job and delivers its result over the EventBus", function()
        local worker, bus = newWorker()
        local got
        bus:Subscribe("HagAIO_Done", function(_, id, result) got = { id = id, result = result } end)
        local id = worker:Queue(function() return 42 end, { message = "HagAIO_Done" })
        worker:_Pump()
        assert.are.equal(id, got.id)
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
                profile.ms = profile.ms + 4    -- each step "costs" 4ms of this frame
                ns.Worker:Yield()              -- yields once the 10ms budget is exceeded
            end
        end)
        -- Frame 1: budget 10ms from profile.ms=0 -> steps cost 4,8,12 -> yields after the 3rd step.
        worker:_Pump()
        assert.is_false(done)
        assert.is_true(steps >= 1 and steps < 5)   -- did NOT finish in one frame
        -- Subsequent frames (budget resets each pump) finish the rest.
        profile.ms = 0; worker:_Pump()
        profile.ms = 0; worker:_Pump()
        assert.are.equal(5, steps)
        assert.is_true(done)
    end)

    it("Cancel drops a still-pending job", function()
        local worker, bus = newWorker()
        local ran = false
        bus:Subscribe("HagAIO_WorkerDone", function() ran = true end)
        local id = worker:Queue(function() ran = true end)
        worker:Cancel(id)
        worker:_Pump()
        assert.is_false(ran)
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
        assert.are.equal(2, runs)                      -- exactly two runs for the burst, not one or three
        handle.Unregister()
    end)
end)
