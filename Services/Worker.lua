local addonName, ns = ...
local Class = ns.Class

-- Services/Worker.lua
-- Frame-budgeted background WORKER. One place that all DEFERRABLE work (catalog/map
-- refreshes, snapshots, one-time setup -- anything tolerant of a few frames' delay)
-- flows through, so it can never stall a frame. Combat / real-time work (Monk markers,
-- Range/Cooldowns, the flight timer, UI drag) must stay IMMEDIATE and NOT use this.
--
-- Each frame the Worker runs queued jobs until it has spent BUDGET_MS this frame, then
-- hands the frame back and resumes next frame -- so its work per render is capped. A job
-- is a function run inside a coroutine; it calls ns.Worker:Yield() (or the `yield` passed
-- to it) at chunk boundaries to cooperatively spread a long job across frames. The job's
-- RETURN VALUE is its result. On completion the Worker delivers via the EventBus: it Emits
-- the job's `message` (default "HagAIO_WorkerDone") with (id, result) -- so callers that
-- gave an iterator with a return get their result, and the rest just get a "done" signal.
--
--   ns.Worker:Queue(fn, { message=, onDone=, label=, id= })   -> id    (one-time work)
--   ns.Worker:Register(event, fn, opts)                       -> handle (run fn each fire)
--   ns.Worker:Yield()                                         -- inside a job: yield if over budget
--   ns.Worker:Cancel(id)                                      -- drop a still-pending job
-- INSIDE a Component prefer self:Queue / self:WorkOn -- they tear down on disable.

local Worker = Class.new("Worker", ns.Service)

local BUDGET_MS = 10        -- hard cap on the time the Worker may spend per frame
local DONE_MSG = "HagAIO_WorkerDone"

function Worker:OnInitialize()
    local p = self:_p()
    p.queue = {}             -- FIFO list of live jobs: { co, id, message, onDone, label }
    p.deadline = nil         -- this frame's time budget end (ms); set only while pumping
    p.nextId = 1
    -- A hidden driver frame: its OnUpdate IS the per-frame pump. Shown only while the queue
    -- has work, so there's zero per-frame cost when the Worker is idle.
    local f = CreateFrame("Frame")
    f:Hide()
    f:SetScript("OnUpdate", function() self:_Pump() end)
    p.frame = f
end

local function freshId(p)
    local id = p.nextId
    p.nextId = id + 1
    return id
end

-- Inside a job: give the frame back if this frame's budget is spent. A no-op outside a
-- pumped job (deadline nil) or before the budget runs out, so jobs can call it liberally.
function Worker:Yield()
    local d = self:_p().deadline
    if d and debugprofilestop() > d then coroutine.yield() end
end

function Worker:_Wake()
    local f = self:_p().frame
    if not f:IsShown() then f:Show() end
end

-- One frame's worth of work: run jobs (FIFO) until the time budget is spent, then stop. A
-- job that yields (budget) stays at the front and resumes next frame; one that returns is
-- completed (its result delivered) and removed.
function Worker:_Pump()
    local p = self:_p()
    local q = p.queue
    if #q == 0 then p.frame:Hide(); return end
    p.deadline = debugprofilestop() + BUDGET_MS
    while #q > 0 and debugprofilestop() < p.deadline do
        local job = q[1]
        local ok, result = coroutine.resume(job.co)
        if not ok then
            table.remove(q, 1)
            self:LogWarn(("job '%s' error: %s"):format(tostring(job.label), tostring(result)))
            if job._after then job._after() end          -- still release any coalescing guard
        elseif coroutine.status(job.co) == "dead" then
            table.remove(q, 1)
            self:_Complete(job, result)
        end
        -- else: the job yielded because the budget is spent -- leave it at the front; the
        -- while-condition will see the budget is gone and end this frame.
    end
    p.deadline = nil
    if #q == 0 then p.frame:Hide() end
end

-- Deliver a finished job's outcome over the EventBus (and an optional direct callback). The
-- result is whatever the job returned (nil = "just done"), passed as (id, result).
function Worker:_Complete(job, result)
    if job.onDone then
        local ok, err = pcall(job.onDone, result)
        if not ok then self:LogWarn(("job '%s' onDone error: %s"):format(tostring(job.label), tostring(err))) end
    end
    if ns.EventBus then ns.EventBus:Emit(job.message or DONE_MSG, job.id, result) end
    if job._after then job._after() end          -- internal: Register coalescing bookkeeping
end

-- Queue ONE-TIME deferred work. `fn(yield)` runs in a coroutine; call yield() (or
-- ns.Worker:Yield()) at chunk points so a long job spreads across frames. fn's return value
-- is the result delivered on completion. Returns the job id (use it to Cancel, or to match
-- the completion event). opts: message (EventBus msg to Emit on done), onDone (fn(result)),
-- label (for logs), id (override the generated id).
function Worker:Queue(fn, opts)
    assert(type(fn) == "function", "Worker:Queue needs a function")
    opts = opts or {}
    local p = self:_p()
    local id = opts.id or freshId(p)
    local yield = function() self:Yield() end
    local job = {
        co = coroutine.create(function() return fn(yield) end),
        id = id, message = opts.message, onDone = opts.onDone,
        label = opts.label or opts.message or ("job#" .. tostring(id)),
        _after = opts._after,
    }
    p.queue[#p.queue + 1] = job
    self:_Wake()
    return id
end

-- Drop a job that hasn't finished yet (best-effort; a running job finishes its current slice).
function Worker:Cancel(id)
    local q = self:_p().queue
    for i = #q, 1, -1 do
        if q[i].id == id then table.remove(q, i) end
    end
end

-- Run `fn` THROUGH the Worker every time `event` fires. `event` is a game event (default) or a
-- custom message (opts.message = true). Fires are COALESCED: while a run is pending/in-flight,
-- further fires don't pile up -- one more run is scheduled after it if any fire arrived. Returns
-- a handle with :Unregister(). opts also takes onDone / doneMessage / label, forwarded to Queue.
function Worker:Register(event, fn, opts)
    assert(type(fn) == "function", "Worker:Register needs a function")
    opts = opts or {}
    local state = { pending = false, again = false, queuedId = nil }
    local function fire()
        if state.pending then state.again = true; return end   -- coalesce: one in flight already
        state.pending = true
        state.queuedId = self:Queue(fn, {
            message = opts.doneMessage, onDone = opts.onDone, label = opts.label or event,
            _after = function()
                state.pending = false
                if state.again then state.again = false; fire() end   -- honour the latest fire
            end,
        })
    end
    local token
    if opts.message then token = ns.EventBus:Subscribe(event, fire)
    else token = ns.EventBus:On(event, fire) end
    return {
        Unregister = function()
            if opts.message then ns.EventBus:Unsubscribe(event, token) else ns.EventBus:Off(event, token) end
            if state.queuedId then self:Cancel(state.queuedId) end
        end,
    }
end

ns.ServiceManager:Register(Worker:New("Worker", { deps = { "EventBus" } }))
