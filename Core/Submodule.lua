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
--   ns.SubmoduleManager:Register(ns.Submodule:New("ATT", {
--       parent = { module = "Collection" },
--       addonDeps = { "AllTheThings" },
--       onLoad = function(host) ... end, onUnload = function(host) ... end,
--   }))

local Submodule = Class.new("Submodule")

function Submodule:Initialize(name, opts)
    opts = opts or {}
    local p = self:_p()
    p.name = name
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
    p.onSettingChanged = opts.onSettingChanged
    p.db = nil
    p.loaded = false
end

function Submodule:GetName() return self:_p().name end
function Submodule:GetTitle() return self:_p().title or self:_p().name end
function Submodule:GetSettings() return self:_p().settings end

-- Own saved-var namespace, seeded with the schema defaults (lazy: available once
-- SavedVariables are loaded, which is well before any settings page is shown).
function Submodule:_DB()
    local p = self:_p()
    if not p.db and ns.SavedVars and ns.SavedVars:IsLoaded() then
        local defaults = {}
        for _, s in ipairs(p.settings) do
            if s.key ~= nil and s.default ~= nil then defaults[s.key] = s.default end
        end
        p.db = ns.SavedVars:Namespace("submodule_" .. p.name, defaults)
    end
    return p.db
end

function Submodule:GetSetting(key)
    local db = self:_DB()
    return db and db[key]
end

function Submodule:SetSetting(key, value)
    local db = self:_DB()
    if db then db[key] = value end
    if self:_p().onSettingChanged then self:_p().onSettingChanged(self:_p().host, key, value) end
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
end

ns.Submodule = Submodule
