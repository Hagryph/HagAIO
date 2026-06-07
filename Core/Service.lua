local addonName, ns = ...
local Class = ns.Class

-- Core/Service.lua
-- Abstract base for every framework SERVICE -- the long-lived singletons the
-- addon is built from (event bus, saved vars, hooks, action bars, UI windows...).
-- Mirrors Core/Module.lua: a service declares a name and its service DEPENDENCIES,
-- then the ServiceManager instantiates each once and runs :OnInitialize() in
-- dependency order, so a service only initialises after every service it depends
-- on is already loaded. Cleanup runs in reverse via :OnShutdown().
--
-- Logging is built in (core functionality): every service gets a Logger channel
-- and the Log* convenience methods, exactly like a Module. Both come from ns.Loggable,
-- the shared logging mixin (Core/Loggable.lua), which Service inherits. A Service does
-- NOT inherit ns.Component: it has no on/off + settings surface, so Component's
-- resource registry / abstract _SettingsDB would be wrong here.
--
--   local Foo = ns.Class.new("Foo", ns.Service)
--   function Foo:OnInitialize() ... end       -- setup; every dep is guaranteed up
--   function Foo:OnShutdown()  ... end         -- optional cleanup (reverse order)
--   ns.ServiceManager:Register(Foo:New("Foo", { deps = { "EventBus" } }))

local Service = Class.new("Service", ns.Loggable)

-- opts = { deps = { "OtherService", ... }, ui = bool, color = "RRGGBB",
--          commands = { ... }, generalToggles = { ... } }
--   deps           : names of services that must be loaded before this one
--   ui             : publish the instance at ns.UI[name] instead of ns[name]
--   color          : Logger channel colour
--   commands       : declarative /hag sub-commands (see ns.Component) -- a service has
--                    no enable/disable, so they're registered once at init
--   generalToggles : declarative General-page toggles (see ns.Component), also init-time
function Service:Initialize(name, opts)
    opts = opts or {}
    Class.super(Service, "Initialize", self, name, opts.color)  -- ns.Loggable: name + colour
    local p = self:_p()
    p.deps           = opts.deps or {}
    p.ui             = opts.ui and true or false
    p.commands       = opts.commands
    p.generalToggles = opts.generalToggles
    p.log            = nil
end

-- GetName is inherited from ns.Loggable (shared identity).
function Service:GetDeps() return self:_p().deps end

-- Internal: the fixed one-time init sequence the ServiceManager runs for this
-- service. Publish (so ns.<Name> resolves) -> attach logger -> OnInitialize, so a
-- service's OnInitialize can rely on GetLog() and on every dependency already being
-- published. The manager calls one method; the order lives here, next to the pieces.
function Service:_Init()
    self:_Publish()
    self:_AttachLogger()
    self:_WireContributions()
    self:OnInitialize()
end

-- Register declarative commands / general toggles once at init (a service has no
-- enable/disable lifecycle, so there is no teardown -- unlike a Module). Uses the same
-- spec shapes + builders as ns.Component so both sides declare them identically. A
-- service that declares commands must depend on "SlashCommand"; one that declares
-- generalToggles must depend on "SettingsWindow", so the dependency ordering guarantees
-- those targets are initialised before this runs.
function Service:_WireContributions()
    local p = self:_p()
    for sub, spec in pairs(p.commands or {}) do
        local fn, help = ns.Component.BuildCommand(self, spec)
        ns.SlashCommand:Register(sub, fn, help)
    end
    for _, spec in ipairs(p.generalToggles or {}) do
        ns.UI.SettingsWindow:RegisterGeneralToggle(ns.Component.BuildGeneralToggle(self, spec))
    end
end

-- Publish this instance into the namespace so call sites reach it as ns.<Name>
-- (or ns.UI.<Name> for UI services). Called by Service:_Init at load.
function Service:_Publish()
    local p = self:_p()
    if p.ui then ns.UI[p.name] = self else ns[p.name] = self end
end

-- Lifecycle hooks (no-ops by default):
--   OnInitialize() : set up, with every declared dependency already loaded.
--   OnShutdown()   : optional cleanup, run in reverse dependency order.
function Service:OnInitialize() end
function Service:OnShutdown() end

ns.Service = Service
