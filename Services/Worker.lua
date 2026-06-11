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
--   ns.Worker:Yield() / :Cancel(id)
-- INSIDE a Component prefer self:Queue / self:WorkOn / self:WorkEvery (owner=self, auto-released).

local Worker = Class.new("Worker", ns.Service)

local BUDGET_MS = 10          -- hard cap on the time the Worker may spend in one pump
local TICK = 1 / 60          -- pump at a FIXED 60 Hz, never per-frame (so 240 FPS isn't hammered)
local DONE_MSG = "HagAIO_WorkerDone"
local STATE_MSG = "HagAIO_OwnerState"   -- (owner, enabled) -- emitted by Component + Service

function Worker:OnInitialize()
    local p = self:_p()
    p.queue = {}             -- live jobs (ITERATORS): { co, id, message, onDone, owner, label, _after }
    p.deadline = nil         -- this pump's time budget end (ms); set only while pumping
    p.rr = 1                 -- round-robin cursor: which job to step next (fairness across iterators)
    p.ticker = nil           -- the 60 Hz pump ticker, alive ONLY while there is queued work
    p.nextId = 1
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
end

-- One tick's work: STEP the queued iterators round-robin -- resume each one a single step at a time --
-- until the time budget is spent. Checking the budget BETWEEN every step (not just between jobs) caps
-- the overshoot to one unit and lets several iterators progress together instead of one hogging the
-- slice. A job that returns is completed (result delivered) and removed; a yield = one step done.
function Worker:_Pump()
    local p = self:_p()
    local q = p.queue
    if #q == 0 then self:_Stop(); return end
    p.deadline = debugprofilestop() + BUDGET_MS
    local i = p.rr
    while #q > 0 and debugprofilestop() < p.deadline do
        if i > #q then i = 1 end
        local job = q[i]
        if job.owner and not self:_OwnerEnabled(job.owner) then   -- owner disabled since enqueue -> drop
            table.remove(q, i)
            if job._after then job._after() end
            -- next job shifted into slot i; don't advance
        else
            local ok, result = coroutine.resume(job.co)           -- ONE step
            if not ok then
                table.remove(q, i)
                self:LogWarn(("job '%s' error: %s"):format(tostring(job.label), tostring(result)))
                if job._after then job._after() end               -- still release any coalescing guard
            elseif coroutine.status(job.co) == "dead" then
                table.remove(q, i)
                self:_Complete(job, result)
            else
                i = i + 1                                         -- still running: round-robin to the next iterator
            end
        end
    end
    p.rr = i
    p.deadline = nil
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
-- `step()` does ONE unit of work and returns truthy while more remains; the Worker calls it again on
-- its next budget slice (60 Hz, round-robin with other jobs). The whole point is that `step` contains
-- NO for/while of its own (the loop here, inside the Worker, is the only one) -- so heavy work can't
-- accumulate past the budget between checks. Prefer this over Queue for anything iterative.
function Worker:Run(step, opts)
    assert(type(step) == "function", "Worker:Run needs a step function")
    return self:Queue(function() while step() do self:Yield() end end, opts)
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
