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
function Service:GetLog()  return self:_p().log end

-- Publish this instance into the namespace so call sites reach it as ns.<Name>
-- (or ns.UI.<Name> for UI services). Called by the ServiceManager at load.
function Service:_Publish()
    local p = self:_p()
    if p.ui then ns.UI[p.name] = self else ns[p.name] = self end
end

-- Attach this service's Logger channel (logging is a core capability every
-- service inherits, like Module).
function Service:_AttachLogger()
    local p = self:_p()
    p.log = ns.Logger:Register(p.name, p.color or ns.Theme.hex.accent)
end

function Service:LogDebug(...)   self:_p().log:Debug(...)   end
function Service:LogInfo(...)    self:_p().log:Info(...)    end
function Service:LogSuccess(...) self:_p().log:Success(...) end
function Service:LogWarn(...)    self:_p().log:Warn(...)    end
function Service:LogError(...)   self:_p().log:Error(...)   end

-- Lifecycle hooks (no-ops by default):
--   OnInitialize() : set up, with every declared dependency already loaded.
--   OnShutdown()   : optional cleanup, run in reverse dependency order.
function Service:OnInitialize() end
function Service:OnShutdown() end

ns.Service = Service
