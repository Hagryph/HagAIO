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
    assert(loadfile("Core/Type.lua"))("HagAIO", ns)       -- value-type factory (e.g. Vector2D)
    assert(loadfile("Core/Enum.lua"))("HagAIO", ns)       -- frozen-enum factory
    assert(loadfile("Core/Mixin.lua"))("HagAIO", ns)          -- trait/mixin factory
    assert(loadfile("Core/Interface.lua"))("HagAIO", ns)      -- interface (contract) factory
    assert(loadfile("Core/Delegate.lua"))("HagAIO", ns)       -- multicast delegate / signal
    assert(loadfile("Core/Contributions.lua"))("HagAIO", ns)  -- declarative-contribution builders
    ns.Theme = { hex = setmetatable({}, { __index = function() return "ffffff" end }) }
    local noop = function() end
    local channel = { Debug = noop, Info = noop, Success = noop, Warn = noop, Error = noop }
    ns.Logger = { Core = function() return channel end, Register = function() return channel end }
    ns.Log = { Print = noop, Warn = noop, Error = noop }  -- static print helpers (Namespace.lua)
    -- Loggable before Component before Service (mirrors the .toc): Component and Service
    -- both inherit ns.Loggable for the shared logging surface. Lib is the pure-helper base.
    assert(loadfile("Core/Loggable.lua"))("HagAIO", ns)
    assert(loadfile("Core/DatabaseOwner.lua"))("HagAIO", ns)  -- DB-ownership mixin (Module/Service use it)
    assert(loadfile("Core/Lib.lua"))("HagAIO", ns)
    assert(loadfile("Lib/Helpers.lua"))("HagAIO", ns)   -- pure helpers (DeepCopy) used across the framework
    assert(loadfile("Core/Component.lua"))("HagAIO", ns)
    assert(loadfile("Core/Service.lua"))("HagAIO", ns)
    ns._captured = {}
    -- Both managers mirror the real ones: capture by name AND publish to ns.<Name>.
    local function captureRegister(_, item)
        ns._captured[item:GetName()] = item
        if item._Publish then item:_Publish() end
        return item
    end
    ns.ServiceManager = { Register = captureRegister, IsLoaded = function() return true end }
    ns.LibManager = { Register = captureRegister }
    -- SettingsTables is a framework dependency now: Module/Submodule derive their settings tables from
    -- it at construction. Load it here (after LibManager exists) so every rig has ns.SettingsTables.
    assert(loadfile("Lib/SettingsTables.lua"))("HagAIO", ns)
    return ns
end

-- Minimal global CreateFrame stub. Frames support SetScript/GetScript,
-- RegisterEvent/UnregisterEvent (tracked in .registered), and :Fire(event, ...) to
-- invoke their OnEvent handler. RegisterEvent throws for an event named "BOGUS_EVENT"
-- so the unknown-event pcall path can be exercised. Returns the list of created frames
-- (frames[1] is the first one made -- e.g. the EventBus driver).
function M.stubFrames()
    local frames = {}
    _G.CreateFrame = function()
        local f = { scripts = {}, registered = {}, shown = true }
        function f:SetScript(name, fn) self.scripts[name] = fn end
        function f:GetScript(name) return self.scripts[name] end
        function f:Show() self.shown = true end
        function f:Hide() self.shown = false end
        function f:IsShown() return self.shown end
        function f:RegisterEvent(e)
            if e == "BOGUS_EVENT" then error("unknown event") end
            self.registered[e] = true
        end
        function f:RegisterUnitEvent(e, ...)
            if e == "BOGUS_EVENT" then error("unknown event") end
            self.registered[e] = true
            self.units = { ... }
        end
        function f:UnregisterEvent(e) self.registered[e] = nil end
        function f:UnregisterAllEvents() self.registered = {} end
        function f:Fire(event, ...) if self.scripts.OnEvent then self.scripts.OnEvent(self, event, ...) end end
        frames[#frames + 1] = f
        return f
    end
    return frames
end

-- A fresh EventBus instance wired to a stubbed driver frame. Returns (bus, frames).
function M.newBus()
    local frames = M.stubFrames()
    local ns = M.newNs()
    M.load(ns, "Services/EventBus.lua")
    local bus = ns._captured["EventBus"]
    bus:OnInitialize()
    return bus, frames, ns
end

-- Load a HagAIO file into `ns` (chainable).
function M.load(ns, path)
    assert(loadfile(path))("HagAIO", ns)
    return ns
end

return M
