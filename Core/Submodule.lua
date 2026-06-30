local addonName, ns = ...
local Class = ns.Class

-- Core/Submodule.lua
-- A SUBMODULE is a piece of a Module (or of another submodule -- nesting is
-- unlimited) that loads only when a CONDITION holds. It declares:
--   parent      : the module/submodule it lives under (a required dependency)
--   serviceDeps : services that must be loaded   (NOT the parent)
--   moduleDeps  : modules that must be enabled    (NOT the parent)
--   submoduleDeps: other submodules that must be loaded
--   addonDeps   : external addons that must be installed (e.g. AllTheThings)
--   condition   : a plain Lua function -> bool (nil = always true)
--   events      : game events that re-evaluate the condition (nil = never)
--   onLoad/onUnload(host, self) : run when it becomes / stops being loaded
--
-- The SubmoduleManager resolves "is this loaded?" purely through the core
-- DependencyGraph: a submodule node is ONLINE when its condition() is true AND
-- its parent + every declared dependency are themselves online. No bespoke
-- dependency checks live here.
--
--   ns.SubmoduleManager:Register(ns.Submodule:New("Foo", {
--       parent = { module = "Bar" },
--       addonDeps = { "SomeAddon" },
--       onLoad = function(host) ... end, onUnload = function(host) ... end,
--   }))

-- Inherits ns.Component for the auto-released resource registry (self:On/Every/... with named
-- scopes) and the shared settings accessors + broadcast. Settings are this character's override
-- layer over the loaded profile + code defaults, resolved live against the database (see
-- Lib/SettingsTables.lua), keyed by the "submodule_<name>" namespace.
local Submodule = Class.new("Submodule", ns.Component)

function Submodule:Initialize(name, opts)
    opts = opts or {}
    Submodule.super.Initialize(self, name)  -- ns.Loggable: name (submodules have no log colour)
    local p = self:_p()
    p.parent = opts.parent              -- { module = name } or { submodule = name }
    p.serviceDeps   = opts.serviceDeps   or {}
    p.moduleDeps    = opts.moduleDeps    or {}
    p.submoduleDeps = opts.submoduleDeps or {}
    p.addonDeps     = opts.addonDeps     or {}
    p.condition = opts.condition         -- function(host) -> bool, or nil
    p.events    = opts.events            -- list of game events, or nil
    p.onLoad    = opts.onLoad
    p.onUnload  = opts.onUnload
    p.host      = opts.host              -- context passed to onLoad/onUnload
    p.title     = opts.title             -- shown as the section label on the parent's page
    p.settings  = opts.settings or {}    -- option schema (rendered while loaded)
    ns.Contributions.ValidateSettings(p.settings, name)  -- fail fast on a malformed schema
    p.onSettingChanged = opts.onSettingChanged
    p.settingsWatch = opts.settingsWatch -- declarative setting-key -> handler (see ns.Component)
    p.dbSchema  = opts.dbSchema          -- structural nested tables to seed in the namespace
    p.enabled = false                    -- "loaded" IS this Component's enabled state (ns.Component)

    -- A submodule's settings are ordinary database rows like a module's; the derive/register/declare/
    -- AddDep dance lives on ns.Component (shared with Module). A submodule contributes no extra tables.
    p.serviceDeps = self:_DeclareSettingsBackedTables()
end

-- GetName is inherited from ns.Loggable (shared identity).
function Submodule:GetTitle() local p = self:_p(); return p.title or p.name end
function Submodule:GetSettings() return self:_p().settings end

-- Settings hooks for ns.Component: a submodule's settings are this character's override layer over
-- the loaded profile + code defaults, resolved live against the database (same as a module's). Its
-- namespace is "submodule_<name>"; the broadcast id is "sub:<name>", and a change forwards to the
-- opts onSettingChanged.
function Submodule:_SettingsNamespace() return "submodule_" .. self:_p().name end
function Submodule:_SettingsOwnerId() return "sub:" .. self:_p().name end
function Submodule:OnSettingChanged(key, value)
    Submodule.super.OnSettingChanged(self, key, value)  -- inherited declarative settingsWatch
    local p = self:_p()
    if p.onSettingChanged then p.onSettingChanged(p.host, key, value) end
end

function Submodule:GetParent() return self:_p().parent end
function Submodule:GetEvents() return self:_p().events end
function Submodule:GetServiceDeps() return self:_p().serviceDeps end
function Submodule:GetModuleDeps() return self:_p().moduleDeps end
function Submodule:GetSubmoduleDeps() return self:_p().submoduleDeps end
function Submodule:GetAddonDeps() return self:_p().addonDeps end
function Submodule:GetHost() return self:_p().host end
-- "Loaded" IS this Component's enabled state: IsEnabled() (the Worker's owner-gating query) lives on
-- ns.Component and reads p.enabled, so inherited self:Queue/WorkOn/WorkEvery genuinely pause while
-- unloaded instead of being treated as always-on. IsLoaded is the submodule-domain name for it.
function Submodule:IsLoaded() return self:IsEnabled() end

-- This submodule's own activation predicate (its Lua condition). Structural deps
-- (parent + declared deps) are evaluated by the graph, not here.
function Submodule:_ConditionMet()
    local c = self:_p().condition
    if c == nil then return true end
    return c(self:_p().host) and true or false
end

-- The graph node ids this submodule depends on (parent first).
function Submodule:_Refs()
    local p = self:_p()
    local refs = {}
    if p.parent then
        if p.parent.module then refs[#refs + 1] = "module:" .. p.parent.module
        elseif p.parent.submodule then refs[#refs + 1] = "sub:" .. p.parent.submodule end
    end
    for _, s in ipairs(p.serviceDeps)   do refs[#refs + 1] = "service:" .. s end
    for _, m in ipairs(p.moduleDeps)    do refs[#refs + 1] = "module:"  .. m end
    for _, s in ipairs(p.submoduleDeps) do refs[#refs + 1] = "sub:"     .. s end
    for _, a in ipairs(p.addonDeps)     do refs[#refs + 1] = "addon:"   .. a end
    return refs
end

-- Lifecycle. A submodule LOADS when its condition holds -- that IS ns.Component's enable/disable for
-- it, so Enable/Disable here are the concrete overrides of the abstract Component lifecycle. The
-- declarative `onLoad`/`onUnload` opts ARE the single extension point (run with (host, self));
-- _SetEnabled owns the loaded-state latch + the HagAIO_OwnerState broadcast, and Disable auto-releases
-- anything wired (self:On/Every/...) while loaded. Submodules customise via the callbacks, not by
-- subclassing.
function Submodule:Enable()
    if not self:_SetEnabled(true) then return end   -- already loaded -> no-op (also broadcasts owner-state)
    local p = self:_p()
    if p.onLoad then p.onLoad(p.host, self) end
end

function Submodule:Disable()
    if not self:_SetEnabled(false) then return end   -- already unloaded -> no-op (also broadcasts owner-state)
    local p = self:_p()
    if p.onUnload then p.onUnload(p.host, self) end
    self:_ReleaseAll()  -- undo any self:On / self:Every / ... registered while loaded
end

-- The SubmoduleManager speaks load/unload; they ARE enable/disable for a submodule.
function Submodule:_Load()   self:Enable()  end
function Submodule:_Unload() self:Disable() end

ns.Submodule = Submodule
