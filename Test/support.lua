-- spec/support.lua
-- Headless test harness: load HagAIO Lua files with a fake `ns` namespace and
-- controllable WoW API stubs (GetTime, C_Timer), so the pure-logic services can be
-- unit-tested with busted outside the game. dofile() this from a spec.

local M = {}

-- A controllable clock + timer factory. advance(dt) fires every due one-shot /
-- ticker in chronological order (so throttled/debounced trailing calls, which
-- schedule fresh timers as they run, are picked up too).
function M.newClock()
    local clock = { now = 0, timers = {} }
    function clock.GetTime() return clock.now end

    local function add(t) clock.timers[#clock.timers + 1] = t; return t end
    clock.C_Timer = {
        After = function(delay, fn)
            add({ at = clock.now + delay, fn = fn })
        end,
        NewTimer = function(delay, fn)
            local t = { at = clock.now + delay, fn = fn, cancelled = false }
            function t:Cancel() self.cancelled = true end
            function t:IsCancelled() return self.cancelled end
            return add(t)
        end,
        NewTicker = function(interval, fn, iters)
            local t = { interval = interval, fn = fn, iters = iters, count = 0,
                        nextAt = clock.now + interval, cancelled = false }
            function t:Cancel() self.cancelled = true end
            function t:IsCancelled() return self.cancelled end
            return add(t)
        end,
    }

    function clock.advance(dt)
        local target = clock.now + dt
        while true do
            local soon, soonAt
            for _, t in ipairs(clock.timers) do
                if not t.cancelled then
                    local fireAt = t.interval and t.nextAt or ((not t.fired) and t.at) or nil
                    if fireAt and fireAt <= target and (not soonAt or fireAt < soonAt) then
                        soon, soonAt = t, fireAt
                    end
                end
            end
            if not soon then break end
            clock.now = soonAt
            if soon.interval then
                soon.count = soon.count + 1
                soon.nextAt = soon.nextAt + soon.interval
                if soon.iters and soon.count >= soon.iters then soon.cancelled = true end
                soon.fn()
            else
                soon.fired = true
                soon.fn()
            end
        end
        clock.now = target
    end

    return clock
end

-- A fresh namespace with the real Class + Service loaded and the managers / logger
-- stubbed. Registered service instances are captured in ns._captured by name.
function M.newNs()
    local ns = { UI = {} }
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    ns.Theme = { hex = setmetatable({}, { __index = function() return "ffffff" end }) }
    local noop = function() end
    local channel = { Debug = noop, Info = noop, Success = noop, Warn = noop, Error = noop }
    ns.Logger = { Core = function() return channel end, Register = function() return channel end }
    assert(loadfile("Core/Service.lua"))("HagAIO", ns)
    ns._captured = {}
    ns.ServiceManager = {
        -- mirror the real manager: capture AND publish to ns.<Name> / ns.UI.<Name>
        Register = function(_, svc)
            ns._captured[svc:GetName()] = svc
            if svc._Publish then svc:_Publish() end
            return svc
        end,
        IsLoaded = function() return true end,
    }
    return ns
end

-- Load a HagAIO file into `ns` (chainable).
function M.load(ns, path)
    assert(loadfile(path))("HagAIO", ns)
    return ns
end

return M
