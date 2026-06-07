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
-- and the Log* convenience methods, exactly like a Module.
--
--   local Foo = ns.Class.new("Foo", ns.Service)
--   function Foo:OnInitialize() ... end       -- setup; every dep is guaranteed up
--   function Foo:OnShutdown()  ... end         -- optional cleanup (reverse order)
--   ns.ServiceManager:Register(Foo:New("Foo", { deps = { "EventBus" } }))

local Service = Class.new("Service")

-- Logging is shared with ns.Component (single source of truth): a service owns a
-- Logger channel and the Log* helpers exactly like a Module. We BORROW Component's
-- logging methods rather than subclass it -- a Service has no on/off + settings
-- surface, so inheriting Component's resource registry / abstract _SettingsDB would be
-- wrong. (Core/Component.lua loads before this file; see the .toc.)
for _, m in ipairs({ "GetLog", "_AttachLogger",
                     "LogDebug", "LogInfo", "LogSuccess", "LogWarn", "LogError",
                     "LogEchoInfo", "LogEchoSuccess", "LogAnnounce" }) do
    Service[m] = ns.Component[m]
end

-- opts = { deps = { "OtherService", ... }, ui = bool, color = "RRGGBB" }
--   deps  : names of services that must be loaded before this one
--   ui    : publish the instance at ns.UI[name] instead of ns[name]
--   color : Logger channel colour
function Service:Initialize(name, opts)
    opts = opts or {}
    local p = self:_p()
    p.name  = name
    p.deps  = opts.deps or {}
    p.ui    = opts.ui and true or false
    p.color = opts.color
    p.log   = nil
end

function Service:GetName() return self:_p().name end
function Service:GetDeps() return self:_p().deps end

-- Internal: the fixed one-time init sequence the ServiceManager runs for this
-- service. Publish (so ns.<Name> resolves) -> attach logger -> OnInitialize, so a
-- service's OnInitialize can rely on GetLog() and on every dependency already being
-- published. The manager calls one method; the order lives here, next to the pieces.
function Service:_Init()
    self:_Publish()
    self:_AttachLogger()
    self:OnInitialize()
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
