local addonName, ns = ...
local Class = ns.Class

-- Services/Worker.lua
-- Frame-budgeted, EVENT-DRIVEN background WORKER. One place all DEFERRABLE work flows
-- through (catalog/map refreshes, snapshots, one-time setup -- anything tolerant of a few
-- frames' delay), so it can never stall a frame. Combat / real-time work (Monk markers,
-- Range/Cooldowns, the flight timer, UI drag) stays IMMEDIATE and does NOT use this.
--
-- 60 Hz, NEVER PER-FRAME: the pump runs on a FIXED 60 Hz ticker (1/60s), created only when there
-- is queued work and CANCELLED the instant the queue drains -- so a 240 FPS client isn't hammered
-- every frame, and there are zero timers while idle (no polling). Periodic work uses :Every (a real
-- timer reminds the Worker to queue the job); the Worker never spins waiting for the next interval.
--
-- ITERATORS: a job is a function run inside a coroutine -- an iterator. It calls ns.Worker:Yield()
-- after each UNIT of work to hand control back; the Worker steps the queued iterators ROUND-ROBIN,
-- one step at a time, checking the time budget BETWEEN every step. So no job accumulates past the
-- budget before the next check, and several iterators make progress together. A job's RETURN VALUE
-- is its result; on completion the Worker Emits the job's `message` (default "HagAIO_WorkerDone")
-- with (id, result) -- iterator-with-return callers get their result, the rest get a done signal.
--
-- OWNER BINDING: pass opts.owner = a Module/Service to bind work to it. The work only runs
-- while the owner is ENABLED, and the Worker auto-listens to the owner's enable/disable
-- (HagAIO_OwnerState, emitted by Component + Service): disabling cancels pending work and
-- pauses interval timers; enabling resumes them. A Service owner is always enabled.
--
--   ns.Worker:Queue(fn, { owner=, message=, onDone=, label= })       -> id      one-time work
--   ns.Worker:Register(event, fn, { owner=, message=, ... })         -> handle  run on each event
--   ns.Worker:Every(interval, fn, { owner=, ... })                   -> handle  timer-reminded
--   ns.Worker:Yield() / :MaybeYield() / :Cancel(id)
-- INSIDE a Component prefer self:Queue / self:WorkOn / self:WorkEvery (owner=self, auto-released).

local Worker = Class.new("Worker", ns.Service)

local BUDGET_MS = 2           -- hard cap on the time the Worker may spend in one pump (a small slice
                              -- of a 60 FPS frame's ~16.7ms, so a drain is never felt as a hitch)
local TICK = 1 / 60          -- pump at a FIXED 60 Hz, never per-frame (so 240 FPS isn't hammered)
-- Pump profiler (per-interval pump times + worst-step attribution, reported on each drain). Costs a
-- few clock reads and a table per pump, so it runs ONLY while debugging is on (the Logger debug
-- flag -- auto-on for dev characters, toggled from the Dev module). Off = zero profiling work.
local function debugOn() return ns.Logger and ns.Logger.GetDebug and ns.Logger:GetDebug() or false end
local DONE_MSG = "HagAIO_WorkerDone"
local STATE_MSG = "HagAIO_OwnerState"   -- (owner, enabled) -- emitted by Component + Service

function Worker:OnInitialize()
    local p = self:_p()
    p.queue = {}             -- live jobs (ITERATORS): { co, id, message, onDone, owner, label, _after }
    p.deadline = nil         -- this pump's time budget end (ms); set only while pumping
    p.currentCo = nil        -- the job coroutine being stepped right now (MaybeYield's identity check)
    p.rr = 1                 -- round-robin cursor: which job to step next (fairness across iterators)
    p.ticker = nil           -- the 60 Hz pump ticker, alive ONLY while there is queued work
    p.nextId = 1
    p.pumpMs = {}            -- DEBUG: per interval pump { ms, worst, label } since the queue last drained
end

local function freshId(p)
    local id = p.nextId
    p.nextId = id + 1
    return id
end

-- Inside a job: hand control back to the Worker -- ONE step done. The Worker resumes the job again on
-- its next budget slice, so the WORKER (not the job) decides when the budget is spent. Call it after
-- each unit of work; a no-op outside a job coroutine (so callers can call it unconditionally).
function Worker:Yield()
    if coroutine.running() then coroutine.yield() end
end

-- Inside a job: yield ONLY when this pump's budget is already spent. The cheap chunk point for
-- SHARED code (the DB executor, module row loops) that may or may not be running through the
-- Worker: outside a pump -- on the main thread, in a stepper, or in a coroutine that isn't the job
-- being stepped -- it is a no-op, and while budget remains it costs one clock read instead of a
-- full coroutine switch per unit (so tight loops can call it every iteration).
function Worker:MaybeYield()
    local p = self:_p()
    local co = coroutine.running()
    if not co or co ~= p.currentCo then return end
    if debugprofilestop() >= p.deadline then coroutine.yield() end
end

-- The pump time (ms) this Worker spent in the frame stamped `frameT` (a GetTime value), 0 for any
-- other frame. Lets a frame-time watchdog (Dev's hitch watch) split a slow frame into "the Worker's
-- share" vs "everything else".
function Worker:FramePumpMs(frameT)
    local p = self:_p()
    return (p.framePumpT == frameT and p.framePumpMs) or 0
end

-- Inside a job: name the PHASE now running. Pure debug attribution -- when a step overshoots the
-- budget, the drain report shows "label @ mark", pointing at the exact phase instead of the whole
-- job. Persists across the job's yields; a no-op outside the job coroutine being stepped.
function Worker:Mark(phase)
    local p = self:_p()
    local co = coroutine.running()
    if co and co == p.currentCo then p.mark = phase end
end

-- Start the 60 Hz pump ticker if there's work and it isn't already running. The Worker is otherwise
-- INERT: no timer exists while the queue is empty (no polling), and the pump can never run faster than
-- 60 Hz regardless of the client's frame rate.
function Worker:_Wake()
    local p = self:_p()
    if p.ticker or #p.queue == 0 then return end
    p.ticker = ns.Scheduler:Every(TICK, function() self:_Pump() end)
end

function Worker:_Stop()
    local p = self:_p()
    if p.ticker then p.ticker:Cancel(); p.ticker = nil end
    self:_DebugReport()   -- no-op when nothing was profiled (debug off)
end

-- DEBUG: log how long each interval pump took since the queue last drained, then reset. One entry =
-- one _Pump call (one 60 Hz interval tick), timed end to end across all the steps it ran. A pump over
-- the budget means a single step inside it overshot -- that job ISN'T chunking (too much work between
-- Yield/MaybeYield points), so each slow pump also NAMES the job whose step was the worst offender.
function Worker:_DebugReport()
    local p = self:_p()
    local pumps = p.pumpMs
    if not pumps or #pumps == 0 then return end
    local total = 0
    for _, e in ipairs(pumps) do total = total + e.ms end
    table.sort(pumps, function(a, b) return a.ms > b.ms end)
    self:LogWarn(("Worker drained: %d interval pumps, %.1f ms total, %.2f ms avg. 10 slowest pumps:")
        :format(#pumps, total, total / #pumps))
    for i = 1, math.min(10, #pumps) do
        local e = pumps[i]
        self:LogWarn(("  %2d. %8.2f ms (worst step %.2f ms: '%s')")
            :format(i, e.ms, e.worst or 0, tostring(e.label)))
    end
    p.pumpMs = {}
end

-- One tick's work: advance the queued jobs round-robin -- ONE step each -- until the TIME budget is
-- spent. Checking the budget BETWEEN every step (not just between jobs) caps the overshoot to one unit
-- and lets several jobs progress together. A job is either a STEPPER (job.step -- called directly,
-- returns truthy while more remains) or a COROUTINE (job.co -- resumed, a yield = one step). A finished
-- job delivers its result and is removed.
function Worker:_Pump()
    local p = self:_p()
    local q = p.queue
    if #q == 0 then self:_Stop(); return end
    local pumpStart = debugprofilestop()
    p.deadline = pumpStart + BUDGET_MS
    local i = p.rr
    local dbg = debugOn()                             -- profile this pump? (latched once per pump)
    local t0, worst, worstLabel = pumpStart, 0, nil   -- debug: time each step, remember the fattest
    while #q > 0 and t0 < p.deadline do
        if i > #q then i = 1 end
        local job = q[i]
        if job.owner and not self:_OwnerEnabled(job.owner) then   -- owner disabled since enqueue -> drop
            table.remove(q, i)
            if job._after then job._after() end
            -- next job shifted into slot i; don't advance
        else
            local ok, done, result      -- ok = no error; done = job finished this step
            if job.step then
                ok, result = pcall(job.step)                      -- stepper: result here is "more?" not the value
                done = ok and not result; result = nil
            else
                p.currentCo = job.co                              -- MaybeYield/Mark only fire for THIS coroutine
                p.mark = job.mark                                 -- restore the job's phase marker
                ok, result = coroutine.resume(job.co)             -- coroutine: one yield = one step
                job.mark = p.mark                                 -- keep the marker across yields
                p.currentCo, p.mark = nil, nil
                done = ok and coroutine.status(job.co) == "dead"
            end
            if not ok then
                table.remove(q, i)
                self:LogWarn(("job '%s' error: %s"):format(tostring(job.label), tostring(result)))
                if job._after then job._after() end               -- still release any coalescing guard
            elseif done then
                table.remove(q, i)
                self:_Complete(job, result)
            else
                i = i + 1                                         -- still running: round-robin to the next job
            end
        end
        local t1 = debugprofilestop()                             -- doubles as the budget re-check time
        if dbg and t1 - t0 > worst then
            worst = t1 - t0
            worstLabel = job.mark and (tostring(job.label) .. " @ " .. tostring(job.mark)) or job.label
        end
        t0 = t1
    end
    p.rr = i
    p.deadline = nil
    local frameT = GetTime and GetTime() or 0                     -- constant within a frame
    p.framePumpMs = (p.framePumpT == frameT and p.framePumpMs or 0) + (t0 - pumpStart)
    p.framePumpT = frameT
    if dbg then p.pumpMs[#p.pumpMs + 1] = { ms = t0 - pumpStart, worst = worst, label = worstLabel } end
    if #q == 0 then self:_Stop() end                              -- drained -> kill the ticker (no idle work)
end

-- Deliver a finished job's outcome over the EventBus (and an optional direct callback). The result
-- is whatever the job returned (nil = "just done"), passed as (id, result).
function Worker:_Complete(job, result)
    if job.onDone then
        local ok, err = pcall(job.onDone, result)
        if not ok then self:LogWarn(("job '%s' onDone error: %s"):format(tostring(job.label), tostring(err))) end
    end
    if ns.EventBus then ns.EventBus:Emit(job.message or DONE_MSG, job.id, result) end
    if job._after then job._after() end                  -- internal: Register/Every coalescing bookkeeping
end

-- True if the owner is currently active (a Service has no IsEnabled -> always on; a Module reports
-- its enable state). nil owner = unbound = always active.
function Worker:_OwnerEnabled(owner)
    if not owner or owner.IsEnabled == nil then return true end
    return owner:IsEnabled() and true or false
end

-- Queue ONE-TIME deferred work. `fn(yield)` runs in a coroutine; call yield() (or ns.Worker:Yield())
-- at chunk points so a long job spreads across frames. fn's return value is delivered on completion.
-- opts: owner (skip + don't queue if disabled), message (EventBus msg on done), onDone (fn(result)),
-- label, id. Returns the job id (nil if an owner was given and is disabled).
function Worker:Queue(fn, opts)
    assert(type(fn) == "function", "Worker:Queue needs a function")
    opts = opts or {}
    if not self:_OwnerEnabled(opts.owner) then return nil end   -- owner disabled -> drop the work
    local p = self:_p()
    local id = opts.id or freshId(p)
    local yield = function() self:Yield() end
    p.queue[#p.queue + 1] = {
        co = coroutine.create(function() return fn(yield) end),
        id = id, message = opts.message, onDone = opts.onDone, owner = opts.owner,
        label = opts.label or opts.message or ("job#" .. tostring(id)),
        _after = opts._after,
    }
    self:_Wake()
    return id
end

-- Run a loop-free STEPPER through the Worker -- the ATT-runner shape, where the WORKER owns the loop.
-- `step()` does ONE unit of work and returns truthy while more remains. The Worker calls it DIRECTLY
-- (no per-unit coroutine) as many times as fit the TIME budget each pump, then again next pump -- so
-- the number of units per frame is driven by time, not a fixed count. `step` must contain NO for/while
-- of its own (the lint enforces it); the only loop is the Worker's budget loop. Prefer this for
-- anything iterative. opts: owner / message / onDone / label (same as Queue).
function Worker:Run(step, opts)
    assert(type(step) == "function", "Worker:Run needs a step function")
    opts = opts or {}
    if not self:_OwnerEnabled(opts.owner) then return nil end
    local p = self:_p()
    local id = opts.id or freshId(p)
    p.queue[#p.queue + 1] = {
        step = step, id = id, message = opts.message, onDone = opts.onDone, owner = opts.owner,
        label = opts.label or opts.message or ("step#" .. tostring(id)), _after = opts._after,
    }
    self:_Wake()
    return id
end

-- Drop a job that hasn't finished yet (best-effort; a job mid-slice finishes its slice).
function Worker:Cancel(id)
    if id == nil then return end
    local q = self:_p().queue
    for i = #q, 1, -1 do
        if q[i].id == id then table.remove(q, i) end
    end
end

-- Build a coalesced, owner-gated RUNNER for fn. `fire()` queues fn through the Worker -- but only
-- while the owner is active, and only once at a time (a fire during a run schedules one more after
-- it, so the latest fire is honoured and bursts never pile up). Returns (fire, state).
function Worker:_Runner(fn, opts)
    local owner = opts.owner
    local st = { active = self:_OwnerEnabled(owner), pending = false, again = false, queuedId = nil }
    local function fire()
        if not st.active then return end                  -- owner disabled -> don't run
        if st.pending then st.again = true; return end    -- one in flight -> coalesce
        st.pending = true
        st.queuedId = self:Queue(fn, {
            owner = owner, message = opts.doneMessage, onDone = opts.onDone, label = opts.label,
            _after = function()
                st.pending = false
                if st.again then st.again = false; fire() end
            end,
        })
    end
    st.fire = fire
    return fire, st
end

-- Subscribe a runner's state to its owner's enable/disable (HagAIO_OwnerState). On disable: mark
-- inactive, drop any pending job, and call st.onActive(false) (interval pause); on enable: reverse.
-- No-op (nil) for an unbound runner. Returns the subscription token for teardown.
function Worker:_BindOwner(st, owner)
    if not owner then return nil end
    return ns.EventBus:Subscribe(STATE_MSG, function(_, o, enabled)
        if o ~= owner then return end
        st.active = enabled and true or false
        if not st.active and st.queuedId then self:Cancel(st.queuedId) end
        if st.onActive then st.onActive(st.active) end
    end)
end

-- Run `fn` THROUGH the Worker every time `event` fires (a game event, or a custom message with
-- opts.message=true). Coalesced + owner-gated (see _Runner / _BindOwner). Returns { Unregister }.
function Worker:Register(event, fn, opts)
    assert(type(fn) == "function", "Worker:Register needs a function")
    opts = opts or {}
    opts.label = opts.label or event
    local fire, st = self:_Runner(fn, opts)
    local evToken = opts.message and ns.EventBus:Subscribe(event, fire) or ns.EventBus:On(event, fire)
    local stateToken = self:_BindOwner(st, opts.owner)
    return { Unregister = function()
        if opts.message then ns.EventBus:Unsubscribe(event, evToken) else ns.EventBus:Off(event, evToken) end
        if stateToken then ns.EventBus:Unsubscribe(STATE_MSG, stateToken) end
        self:Cancel(st.queuedId)
    end }
end

-- Run `fn` THROUGH the Worker every `interval` seconds, via a TIMER that reminds the Worker to queue
-- it (no polling). Owner-gated: the timer is paused while the owner is disabled and resumed on enable.
-- Returns { Unregister }.
function Worker:Every(interval, fn, opts)
    assert(type(fn) == "function", "Worker:Every needs a function")
    opts = opts or {}
    opts.label = opts.label or ("every " .. tostring(interval) .. "s")
    local fire, st = self:_Runner(fn, opts)
    local function start() if not st.timer then st.timer = ns.Scheduler:Every(interval, fire) end end
    local function stop() if st.timer then st.timer:Cancel(); st.timer = nil end end
    st.onActive = function(active) if active then start() else stop() end end
    if st.active then start() end
    local stateToken = self:_BindOwner(st, opts.owner)
    return { Unregister = function()
        stop()
        if stateToken then ns.EventBus:Unsubscribe(STATE_MSG, stateToken) end
        self:Cancel(st.queuedId)
    end }
end

ns.ServiceManager:Register(Worker:New("Worker", { deps = { "EventBus", "Scheduler" } }))
