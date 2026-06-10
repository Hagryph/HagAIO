local addonName, ns = ...
local Class = ns.Class

-- Core/Module.lua
-- Abstract base class for every feature module. Subclasses are created with
-- `ns.Class.new("MyFeature", ns.Module)` and override the lifecycle hooks.
-- Enable state and the persistence handle are private; access is via methods.
--
-- The resource registry (self:On/Subscribe/Hook/Every/... auto-released on disable)
-- and the settings accessors live on ns.Component, the shared base; this class adds
-- enable/disable, dependency gating, saved-var binding and logging.

-- The declarative `databases` surface (self:DB(name) + private DAOs) is inherited from ns.Component
-- (via the ns.DatabaseOwner mixin applied there), shared with Submodule.
local Module = Class.new("Module", ns.Component)

-- Constructor. Subclasses that need their own constructor should override
-- Initialize and call Module.Initialize(self, name, opts) first.
--   opts = { title = string, description = string, defaultEnabled = bool,
--            alwaysOn = bool, color = "RRGGBB", deps = { "Service", ... },
--            tables = { <db table schemas> }, settings = { <schema entries> } }
-- PERSISTENCE: a module's `settings` (schema values) and enable state are stored PER
-- CHARACTER -- that's the config a profile captures. Its ACCOUNT-WIDE persistent data
-- (flight routes, learned timed quests) lives in the shared Database -- declared via the
-- `tables` opt and reached through self:DB() (see ns.DatabaseOwner), never a private namespace.
-- `alwaysOn` makes the module MANDATORY: it enables at start, can't be disabled, and the
-- settings UI shows no on/off toggle (used for always-active tooling like the Dev module).
-- `deps` names the SERVICES this module needs; the ModuleManager won't start the
-- module until every one of them is loaded.
-- `addonDeps` names EXTERNAL addons that must be loaded for this module to be
-- available at all (e.g. "AllTheThings"); unavailable modules are hidden.
-- `moduleDeps` names other HagAIO MODULES that must be ENABLED for this one to
-- run; a module whose module-deps aren't met is shown greyed-out and can't enable.
--
-- `events` / `messages` are DECLARATIVE subscriptions wired automatically on
-- Enable and torn down on Disable -- a module that only reacts to events needs no
-- OnEnable/OnDisable plumbing at all. Each maps a name to either a method name on
-- the module or a function; both are called as handler(self, eventOrMessage, ...):
--   events   = { PLAYER_XP_UPDATE = "_OnXP", PLAYER_LEVEL_UP = function(self, e) ... end }
--   messages = { HagAIO_SomeSignal = "_OnSignal" }
-- For dynamic/conditional subscriptions inside OnEnable, use the self:On /
-- self:Subscribe / self:Hook helpers instead -- they are released automatically on
-- Disable, so OnDisable never has to undo them by hand.
--
-- `commands` / `generalToggles` are likewise DECLARATIVE (see ns.Component): a module's
-- /hag sub-commands and General-page toggles are registered on Enable and removed on
-- Disable, so a disabled module contributes neither -- no manual Register/Unregister:
--   commands       = { xp = { handler = "_PrintSession", help = "session XP / hour" } }
--   generalToggles = { { label = "...", get = "IsShown", set = "SetShown" } }
--
-- Each settings schema entry drives one auto-generated control on the module's
-- settings page (and seeds its saved-var default):
--   { type = "header", text = "..." }
--   { type = "note",   text = "..." }
--   { type = "toggle", key = "...", label = "...", default = bool, desc = "..." }
--   { type = "select", key = "...", label = "...", default = "v",
--       options = { { value = "v", text = "..." }, ... } }
function Module:Initialize(name, opts)
    opts = opts or {}
    Module.super.Initialize(self, name, opts.color or ns.Theme.hex.accent)  -- ns.Loggable: name + colour
    local p = self:_p()
    p.title = opts.title or name
    p.description = opts.description or ""
    p.alwaysOn = opts.alwaysOn and true or false  -- mandatory module: always enabled, no on/off toggle
    p.defaultEnabled = p.alwaysOn or (opts.defaultEnabled ~= false)
    p.serviceDeps = opts.deps or {}               -- services that must be loaded first
    p.addonDeps = opts.addonDeps or {}            -- external addons required to be available
    p.moduleDeps = opts.moduleDeps or {}          -- other modules that must be enabled
    p.settings = opts.settings or {}
    ns.Contributions.ValidateSettings(p.settings, name)  -- fail fast on a malformed schema
    p.events = opts.events or {}                   -- declarative game-event subscriptions
    p.messages = opts.messages or {}              -- declarative custom-message subscriptions
    p.commands = opts.commands                     -- declarative /hag sub-commands (see ns.Component)
    p.generalToggles = opts.generalToggles         -- declarative General-page toggles (see ns.Component)
    p.settingsWatch = opts.settingsWatch          -- declarative setting-key -> handler (see ns.Component)
    p.publishAs = opts.publishAs                   -- optional: publish this instance at ns.<alias> (see _Publish)

    -- Tables contributed to the shared database (see ns.DatabaseOwner): the module's own `tables`
    -- (self:DB() + DAOs) PLUS the two settings tables auto-derived from its settings schema -- the
    -- per-character override layer and the per-profile layer of the cascade (see Lib/SettingsTables.lua).
    -- A module's settings are therefore ordinary database rows; its enable-state lives in the central
    -- module_enable tables. A module that contributes any table depends on the DatabaseManager.
    local nsKey = "module_" .. name
    local tables = {}
    for tn, spec in pairs(opts.tables or {}) do tables[tn] = spec end
    for tn, spec in pairs(ns.SettingsTables:DeriveTables(nsKey, p.settings)) do tables[tn] = spec end
    ns.SettingsTables:Register(nsKey, p.settings)
    self:_DeclareTables(tables)
    if next(tables) then p.serviceDeps = ns.AddDep(p.serviceDeps, "DatabaseManager") end

    p.enabled = false
    p.log = nil
end

-- Getters (private fields are never exposed directly). GetName comes from ns.Loggable.
function Module:GetTitle() return self:_p().title end
function Module:GetDescription() return self:_p().description end
function Module:GetColor() return self:_p().color end
function Module:GetSettings() return self:_p().settings end
function Module:GetServiceDeps() return self:_p().serviceDeps end
function Module:GetAddonDeps() return self:_p().addonDeps end
function Module:GetModuleDeps() return self:_p().moduleDeps end

-- Available = every required external addon is loaded (gates DISPLAY).
-- Deps-met = prerequisite modules enabled + required services loaded (gates GREY).
-- Both are resolved by the shared DependencyGraph the ModuleManager owns -- no
-- bespoke checks live here.
function Module:IsAvailable()
    return ns.ModuleManager:IsModuleAvailable(self:_p().name)
end

function Module:AreModuleDepsMet()
    return ns.ModuleManager:AreModuleDepsMet(self:_p().name)
end
function Module:IsEnabled() return self:_p().enabled end
function Module:IsDefaultEnabled() return self:_p().defaultEnabled end
-- Always-on (mandatory): enabled at start, can't be disabled, and shows no on/off toggle.
function Module:IsAlwaysOn() return self:_p().alwaysOn end
-- A module's ACCOUNT-WIDE persistent data lives in the shared Database (declarative `tables`
-- reached via self:DB(); see ns.DatabaseOwner). Settings are per-character (GetSetting).
-- GetLog + the Log* helpers are inherited from ns.Component (shared logging surface).

-- Settings are this character's override layer over the loaded profile + code defaults, resolved live
-- against the database (see ns.Component for the shared GetSetting/SetSetting + the HagAIO_SettingChanged
-- broadcast). A module's settings namespace is "module_<name>".
function Module:_SettingsNamespace() return "module_" .. self:_p().name end

-- Turn a declarative spec (a method name or a function) into a handler invoked as
-- handler(name, ...) -> spec(self, name, ...).
function Module:_BindHandler(spec)
    if type(spec) == "string" then
        return function(name, ...) return self[spec](self, name, ...) end
    end
    return function(name, ...) return spec(self, name, ...) end
end

-- Wire the declarative events/messages tables. Called by Enable; each entry is a
-- method name or a function. Bound handlers are built ONCE per module and reused
-- across enable/disable cycles (each captures only `self`, which never changes), so
-- re-enabling doesn't churn fresh closures. The subscriptions themselves are still
-- re-made each enable and auto-released on disable via self:On / self:Subscribe.
function Module:_WireDeclared()
    local p = self:_p()
    local bound = p.boundHandlers
    if not bound then
        bound = {}
        for _, spec in pairs(p.events)   do bound[spec] = bound[spec] or self:_BindHandler(spec) end
        for _, spec in pairs(p.messages) do bound[spec] = bound[spec] or self:_BindHandler(spec) end
        p.boundHandlers = bound
    end
    for event, spec   in pairs(p.events)   do self:On(event, bound[spec]) end
    for message, spec in pairs(p.messages) do self:Subscribe(message, bound[spec]) end
    self:_WireContributions()  -- declarative commands + general toggles (auto-removed on disable)
end

-- Internal: the fixed one-time init sequence the ModuleManager runs for this module
-- (on PLAYER_LOGIN, or immediately for a late registration). Logger first, then
-- OnInitialize -- so a subclass's OnInitialize can always rely on GetLog() and self:DB()
-- being ready (the shared database was built on ADDON_LOADED). Keeping the order here,
-- next to the pieces it sequences, means the manager just calls one method and no module
-- author has to know the order.
function Module:_Init()
    self:_Publish()      -- ns.<alias> first (opts.publishAs), so OnInitialize can rely on it
    self:_AttachLogger()
    self:_ContributeTables()    -- contribute owned tables to the shared database (built later)
    self:OnInitialize()
end

-- Optional public alias: publish this module instance at ns.<opts.publishAs> so other code
-- can reach it directly (e.g. ns.<Alias> -> the module). Mirrors
-- Service:_Publish; replaces hand-written `ns.X = self` in OnInitialize. The alias is
-- declared in the module's New opts and documented in the generated Namespace.lua slot block.
function Module:_Publish()
    local alias = self:_p().publishAs
    if alias then ns[alias] = self end
end

function Module:Enable()
    local p = self:_p()
    if p.enabled then return end
    if not self:IsAvailable() then return end                 -- required addon missing
    if not self:AreModuleDepsMet() then                        -- a prerequisite module is off
        ns.Logger:Core():Warn(("%s needs another module enabled first."):format(p.name))
        return
    end
    p.enabled = true
    -- Guard the subclass hook (like OnShutdown) so one module's error can't abort the
    -- ModuleManager's start loop; log it rather than swallowing silently.
    local ok, err = pcall(self.OnEnable, self)  -- base no-op unless the subclass overrides
    if not ok then ns.Logger:Core():Warn(("%s OnEnable error: %s"):format(p.name, tostring(err))) end
    self:_WireDeclared()  -- declarative events/messages (auto-released on disable)
    local db = self:DB()
    if db then ns.SettingsTables:SetModuleEnabled(db, p.name, true, p.defaultEnabled) end  -- enable override (diffed vs profile/default)
    if p.log then p.log:Success("enabled") end
    if ns.EventBus and ns.EventBus.Emit then ns.EventBus:Emit("HagAIO_ModuleState", p.name, true) end
end

function Module:Disable()
    local p = self:_p()
    if p.alwaysOn then return end   -- mandatory module: stays enabled regardless of any toggle
    if not p.enabled then return end
    p.enabled = false
    local ok, err = pcall(self.OnDisable, self)  -- base no-op unless the subclass overrides
    if not ok then ns.Logger:Core():Warn(("%s OnDisable error: %s"):format(p.name, tostring(err))) end
    self:_ReleaseAll()  -- undo every self:On / self:Subscribe / self:Hook + declared wiring
    local db = self:DB()
    if db then ns.SettingsTables:SetModuleEnabled(db, p.name, false, p.defaultEnabled) end  -- enable override (diffed vs profile/default)
    if p.log then p.log:Info("disabled") end
    ns.ModuleManager:DisableDependents(p.name)  -- cascade: modules that needed this one
    if ns.EventBus and ns.EventBus.Emit then ns.EventBus:Emit("HagAIO_ModuleState", p.name, false) end
end

function Module:Toggle()
    if self:IsEnabled() then self:Disable() else self:Enable() end
end

-- Lifecycle hooks for subclasses (no-ops by default):
--   OnInitialize() : run once after db bind, before any enable.
--   OnEnable()     : run each time the module is enabled.
--   OnDisable()    : run each time the module is disabled.
--   OnShutdown()   : run once on logout/reload (cleanup before the Lua state resets).
-- PLACEMENT RULE: put ALWAYS-ON setup that must work even while the module is disabled
-- (discovery, saved-var reads, recording engines) in OnInitialize; put behaviour that
-- should only run while ENABLED (event reactions, frames, hooks) in OnEnable -- and prefer
-- the declarative events/messages/commands/generalToggles tables, which are wired on enable
-- and torn down on disable for you.
-- All four are declared as base no-ops so Enable/Disable/the ModuleManager can call them
-- unconditionally -- no `if self.OnX then` guards at the call sites.
function Module:OnInitialize() end
function Module:OnEnable() end
function Module:OnDisable() end
function Module:OnShutdown() end

ns.Module = Module
