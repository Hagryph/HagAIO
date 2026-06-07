local addonName, ns = ...
local Class = ns.Class

-- Services/Scheduler.lua
-- Thin, cancellable wrapper over C_Timer. Centralises the timer patterns modules
-- used to hand-roll (repeating tickers, one-shots, throttled / debounced bursts) so
-- there's ONE place to create timers and -- via the Module:Every/After/Throttled/
-- Debounced helpers -- automatic cancellation on disable. No per-module ticker
-- bookkeeping, and fewer stray live timers.
--
--   local h = ns.Scheduler:Every(1, fn)        h:Cancel()
--   local h = ns.Scheduler:After(0.5, fn)      h:Cancel()
--   local f = ns.Scheduler:Throttled(0.15, fn) -- run at most once / 0.15s (leading + trailing)
--   local f = ns.Scheduler:Debounced(0.2, fn)  -- run 0.2s after the LAST call
-- Throttled/Debounced return (wrappedFn, control); control:Cancel() drops a pending call.
-- INSIDE a module prefer self:Every / self:After / self:Throttled / self:Debounced --
-- those register teardown so the timer is cancelled automatically on disable.

local Scheduler = Class.new("Scheduler", ns.Service)

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

-- Repeating timer. `iterations` optional (nil = forever). Returns the C_Timer
-- ticker handle (has :Cancel() and :IsCancelled()).
function Scheduler:Every(interval, fn, iterations)
    assert(type(fn) == "function", "Scheduler:Every needs a function")
    return C_Timer.NewTicker(interval, fn, iterations)   -- fn ignores the ticker arg; no wrapper closure
end

-- One-shot timer. Returns a CANCELLABLE handle (unlike bare C_Timer.After).
function Scheduler:After(delay, fn)
    assert(type(fn) == "function", "Scheduler:After needs a function")
    return C_Timer.NewTimer(delay, fn)   -- fn ignores the timer arg; no wrapper closure
end

-- Rate-limit: the returned function runs fn immediately, then at most once per
-- `interval`; calls during the cooldown are coalesced into ONE trailing call with
-- the latest arguments (so the final state isn't lost). Returns (wrapped, control).
function Scheduler:Throttled(interval, fn)
    assert(type(fn) == "function", "Scheduler:Throttled needs a function")
    local timer, pending, lastArgs
    local function run(...)
        if timer then                      -- in cooldown: remember the latest args
            pending, lastArgs = true, pack(...)
            return
        end
        fn(...)
        timer = C_Timer.NewTimer(interval, function()
            timer = nil
            if pending then
                pending = false
                local a = lastArgs; lastArgs = nil
                run(unpack(a, 1, a.n))     -- trailing call: fires fn + reopens the window
            end
        end)
    end
    local control = { Cancel = function()
        if timer then timer:Cancel(); timer = nil end
        pending, lastArgs = false, nil
    end }
    return run, control
end

-- Collapse a burst: the returned function runs fn only ONCE, `delay` after the
-- last call (each call restarts the countdown). Returns (wrapped, control).
function Scheduler:Debounced(delay, fn)
    assert(type(fn) == "function", "Scheduler:Debounced needs a function")
    local timer
    local function run(...)
        local args = pack(...)
        if timer then timer:Cancel() end
        timer = C_Timer.NewTimer(delay, function()
            timer = nil
            fn(unpack(args, 1, args.n))
        end)
    end
    local control = { Cancel = function()
        if timer then timer:Cancel(); timer = nil end
    end }
    return run, control
end

ns.ServiceManager:Register(Scheduler:New("Scheduler"))
