-- Test/support.lua
-- Headless test harness: load HagAIO Lua files with a fake `ns` namespace and
-- controllable WoW API stubs (GetTime, C_Timer), so the pure-logic services can be
-- unit-tested with busted outside the game. dofile() this from a spec.

local M = {}

-- Parse tools/load-order.json -- the shared load-order manifest (one source of truth with
-- tools/autogen/Common.ps1, tools/depcheck.mjs and tools/gen_schema.lua). The file is
-- strictly arrays/objects of plain strings with no colons/brackets inside the strings, so
-- a syntactic translation to a Lua literal is safe -- no JSON library needed headless.
function M.loadOrder()
    local f = assert(io.open("tools/load-order.json", "rb"),
        "tools/load-order.json not found (run the specs from the repo root)")
    local s = f:read("*a"); f:close()
    s = s:gsub("%[", "{"):gsub("%]", "}"):gsub('("[^"\n]-")%s*:', "[%1]=")
    return assert((loadstring or load)("return " .. s))()
end

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

-- Framework files this rig SKIPS from the manifest's pinned head: either stubbed below
-- (Theme, Logger, the managers + their Registry/DependencyGraph machinery) or not needed
-- headless (Namespace/Color/Widgets). Module/Submodule load on demand from the specs.
local RIG_SKIP = {
    ["Core/Namespace.lua"] = true,        -- WoW-API bound (dev identity)
    ["Core/DB/Types.lua"] = true,         -- DB specs load the engine explicitly (their DB_FILES list)
    ["Lib/Color.lua"] = true,             -- specs that need it load it themselves
    ["UI/Theme.lua"] = true,              -- stubbed below
    ["Core/DependencyGraph.lua"] = true,  -- manager machinery; managers are stubbed
    ["Core/Logger.lua"] = true,           -- stubbed below
    ["Core/Registry.lua"] = true,         -- manager base; managers are stubbed
    ["Core/ServiceManager.lua"] = true,   -- stubbed below
    ["Core/Module.lua"] = true,           -- specs load it when they exercise modules
    ["Core/ModuleManager.lua"] = true,    -- stubbed by the specs that need it
    ["Core/Submodule.lua"] = true,        -- specs load it when they exercise submodules
    ["Core/SubmoduleManager.lua"] = true, -- specs load it when they exercise submodules
    ["Core/LibManager.lua"] = true,       -- stubbed below
    ["UI/Widgets/Widgets.lua"] = true,    -- UI layer; widget specs build their own rig
}

-- A fresh namespace with the real Class + Service loaded and the managers / logger
-- stubbed. The framework files come from the shared load-order manifest (in manifest
-- order, minus RIG_SKIP), so a new Core base class reaches the rig automatically.
-- Registered service instances are captured in ns._captured by name.
function M.newNs()
    local ns = { UI = {} }
    ns.Theme = { hex = setmetatable({}, { __index = function() return "ffffff" end }) }
    local noop = function() end
    local channel = { Debug = noop, Info = noop, Success = noop, Warn = noop, Error = noop }
    ns.Logger = { Core = function() return channel end, Register = function() return channel end }
    ns.Log = { Print = noop, Warn = noop, Error = noop }  -- static print helpers (Namespace.lua)
    ns.Meta = { name = "HagAIO", version = "0.0.0", ICON = "Interface\\AddOns\\HagAIO\\Media\\icon" }  -- frozen addon metadata (Namespace.lua)
    -- The pinned head in manifest order: OOP primitives, then Loggable before Component
    -- before Service (Component and Service both inherit ns.Loggable), then the Lib base.
    for _, f in ipairs(M.loadOrder().pinnedHead) do
        if not RIG_SKIP[f] then assert(loadfile(f))("HagAIO", ns) end
    end
    ns._captured = {}
    -- Both managers mirror the real ones: capture by name AND publish to ns.<Name>.
    local function captureRegister(_, item)
        ns._captured[item:GetName()] = item
        if item._Publish then item:_Publish() end
        return item
    end
    ns.ServiceManager = { Register = captureRegister, IsLoaded = function() return true end }
    ns.LibManager = {
        Register = captureRegister,
        -- Value libs (plain static tables / value types) publish through the same anchor.
        RegisterValue = function(_, name, value)
            ns._captured[name] = value
            ns[name] = value
            return value
        end,
    }
    -- Not in the pinned head but part of every rig: the opt-in data-version mixin, the
    -- shared pure helpers, and SettingsTables (Module/Submodule derive their settings
    -- tables from it at construction; needs ns.Lib + the LibManager stub above).
    assert(loadfile("Core/VersioningOwner.lua"))("HagAIO", ns)
    assert(loadfile("Lib/Helpers.lua"))("HagAIO", ns)
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
