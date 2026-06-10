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
-- resource registry / abstract _SettingsNamespace would be wrong here.
--
--   local Foo = ns.Class.new("Foo", ns.Service)
--   function Foo:OnInitialize() ... end       -- setup; every dep is guaranteed up
--   function Foo:OnShutdown()  ... end         -- optional cleanup (reverse order)
--   ns.ServiceManager:Register(Foo:New("Foo", { deps = { "EventBus" } }))

-- ns.DatabaseOwner adds the declarative `databases` surface (self:DB(name) + private DAOs).
local Service = Class.new("Service", ns.Loggable, { mixins = { ns.DatabaseOwner } })

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
    Service.super.Initialize(self, name, opts.color)  -- ns.Loggable: name + colour
    local p = self:_p()
    p.deps           = opts.deps or {}
    p.ui             = opts.ui and true or false
    p.commands       = opts.commands
    p.generalToggles = opts.generalToggles
    p.log            = nil
    -- Tables contributed to the shared database (see ns.DatabaseOwner). A service that contributes
    -- tables depends on the DatabaseManager so it's initialised first; the shared database is built
    -- later (Init.lua, on PLAYER_LOGIN), once every owner has contributed and saved vars exist.
    self:_DeclareTables(opts.tables)
    if opts.tables and next(opts.tables) then p.deps = ns.AddDep(p.deps, "DatabaseManager") end
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
    self:_ContributeTables()    -- contribute owned tables to the shared database (built later)
    self:OnInitialize()
end

-- Register declarative commands / general toggles once at init (a service has no
-- enable/disable lifecycle, so there is no teardown -- unlike a Module). Uses the same
-- spec shapes + builders (ns.Contributions) as a Module so both declare them identically. A
-- service that declares commands must depend on "SlashCommand"; one that declares
-- generalToggles must depend on "SettingsWindow", so the dependency ordering guarantees
-- those targets are initialised before this runs.
function Service:_WireContributions()
    local p = self:_p()
    for sub, spec in pairs(p.commands or {}) do
        local fn, help = ns.Contributions.BuildCommand(self, spec)
        ns.SlashCommand:Register(sub, fn, help)
    end
    for _, spec in ipairs(p.generalToggles or {}) do
        ns.UI.SettingsWindow:RegisterGeneralToggle(ns.Contributions.BuildGeneralToggle(self, spec))
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
