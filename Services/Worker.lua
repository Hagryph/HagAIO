local addonName, ns = ...
local Class = ns.Class

-- Services/Worker.lua
-- Frame-budgeted, EVENT-DRIVEN background WORKER. One place all DEFERRABLE work flows
-- through (catalog/map refreshes, snapshots, one-time setup -- anything tolerant of a few
-- frames' delay), so it can never stall a frame. Combat / real-time work (Monk markers,
-- Range/Cooldowns, the flight timer, UI drag) stays IMMEDIATE and does NOT use this.
--
-- NO IDLE WORK / NO POLLING: the Worker has no per-frame loop. A pump is scheduled (one
-- next-frame timer) only when there is queued work, runs jobs until it has spent BUDGET_MS
-- this frame, and re-schedules ONLY while the queue is non-empty -- so when there is nothing
-- to do, zero timers exist. Periodic work uses :Every (a real timer reminds the Worker to
-- queue the job); the Worker never spins waiting for the next interval.
--
-- A job is a function run inside a coroutine; it calls ns.Worker:Yield() at chunk boundaries
-- to spread a long job across frames. Its RETURN VALUE is the result. On completion the Worker
-- delivers over the EventBus: it Emits the job's `message` (default "HagAIO_WorkerDone") with
-- (id, result) -- iterator-with-return callers get their result, the rest get a done signal.
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

local BUDGET_MS = 10        -- hard cap on the time the Worker may spend per frame
local DONE_MSG = "HagAIO_WorkerDone"
local STATE_MSG = "HagAIO_OwnerState"   -- (owner, enabled) -- emitted by Component + Service

function Worker:OnInitialize()
    local p = self:_p()
    p.queue = {}             -- FIFO list of live jobs: { co, id, message, onDone, label }
    p.deadline = nil         -- this frame's time budget end (ms); set only while pumping
    p.scheduled = false      -- is a next-frame pump already queued?
    p.nextId = 1
end

local function freshId(p)
    local id = p.nextId
    p.nextId = id + 1
    return id
end

-- Inside a job: give the frame back if this frame's budget is spent. A no-op outside a pumped
-- job (deadline nil) or before the budget runs out, so jobs can call it liberally.
function Worker:Yield()
    local d = self:_p().deadline
    if d and debugprofilestop() > d then coroutine.yield() end
end

-- Schedule ONE next-frame pump if work is waiting and none is scheduled. The Worker is otherwise
-- inert -- no timer exists while the queue is empty (event-driven, no polling).
function Worker:_Wake()
    local p = self:_p()
    if p.scheduled or #p.queue == 0 then return end
    p.scheduled = true
    C_Timer.After(0, function() self:_Pump() end)
end

-- One frame's work: run jobs (FIFO) until the time budget is spent. A job that yields (budget)
-- stays at the front and continues next frame; one that returns is completed and removed. Re-arms
-- a pump only if the queue still has work -- so the chain stops the instant it's drained.
function Worker:_Pump()
    local p = self:_p()
    p.scheduled = false
    local q = p.queue
    if #q == 0 then return end
    p.deadline = debugprofilestop() + BUDGET_MS
    while #q > 0 and debugprofilestop() < p.deadline do
        local job = q[1]
        if job.owner and not self:_OwnerEnabled(job.owner) then   -- owner disabled since enqueue -> drop
            table.remove(q, 1)
            if job._after then job._after() end
        else
            local ok, result = coroutine.resume(job.co)
            if not ok then
                table.remove(q, 1)
                self:LogWarn(("job '%s' error: %s"):format(tostring(job.label), tostring(result)))
                if job._after then job._after() end       -- still release any coalescing guard
            elseif coroutine.status(job.co) == "dead" then
                table.remove(q, 1)
                self:_Complete(job, result)
            end
            -- else: the job yielded (budget spent) -- leave it at the front; the while ends the frame.
        end
    end
    p.deadline = nil
    self:_Wake()                                          -- more work? continue next frame; else stay inert
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
