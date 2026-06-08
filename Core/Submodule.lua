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

-- Inherits ns.Component for the auto-released resource registry (self:On/Every/...
-- with named scopes) and the shared settings accessors + broadcast; mixes in ns.Persisted
-- for the cached lazy saved-var store (_BindStore/_Store).
local Submodule = Class.new("Submodule", ns.Component, { mixins = { ns.Persisted } })

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
    -- Own saved-var namespace (the cached _Store from ns.Persisted), seeded with the schema
    -- + dbSchema defaults; resolved lazily once SavedVariables load, before any page is shown.
    -- PER CHARACTER: a submodule's settings are config (captured by profiles), like a module's.
    self:_BindStore("submodule_" .. name, function()
        local pp = self:_p()
        return ns.Component.SeedDefaults(pp.settings, pp.dbSchema)
    end, true)
    p.loaded = false
end

-- GetName is inherited from ns.Loggable (shared identity).
function Submodule:GetTitle() local p = self:_p(); return p.title or p.name end
function Submodule:GetSettings() return self:_p().settings end

-- Settings hooks for ns.Component: values live in this submodule's namespace, the
-- broadcast id is "sub:<name>", and a change forwards to the opts onSettingChanged.
function Submodule:_SettingsDB() return self:_Store() end
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
function Submodule:IsLoaded() return self:_p().loaded end

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

-- Lifecycle. The declarative `onLoad`/`onUnload` opts ARE the single extension point --
-- run with (host, self) when this submodule becomes / stops being loaded. _Load/_Unload own
-- the loaded-state latch and the auto-release of anything wired (self:On/Every/...) while
-- loaded; submodules customise via the callbacks, not by subclassing.
function Submodule:_Load()
    local p = self:_p()
    if p.loaded then return end
    p.loaded = true
    if p.onLoad then p.onLoad(p.host, self) end
end

function Submodule:_Unload()
    local p = self:_p()
    if not p.loaded then return end
    p.loaded = false
    if p.onUnload then p.onUnload(p.host, self) end
    self:_ReleaseAll()  -- undo any self:On / self:Every / ... registered while loaded
end

ns.Submodule = Submodule
