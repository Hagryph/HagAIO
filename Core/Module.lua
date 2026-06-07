local addonName, ns = ...
local Class = ns.Class

-- Core/Module.lua
-- Abstract base class for every feature module. Subclasses are created with
-- `ns.Class.new("MyFeature", ns.Module)` and override the lifecycle hooks.
-- Enable state and the persistence handle are private; access is via methods.

local Module = Class.new("Module")

-- Constructor. Subclasses that need their own constructor should override
-- Initialize and call Module.Initialize(self, name, opts) first.
--   opts = { title = string, description = string, defaultEnabled = bool,
--            color = "RRGGBB", dbDefaults = table, deps = { "Service", ... },
--            settings = { <schema entries> } }
-- `deps` names the SERVICES this module needs; the ModuleManager won't start the
-- module until every one of them is loaded.
-- `addonDeps` names EXTERNAL addons that must be loaded for this module to be
-- available at all (e.g. "AllTheThings"); unavailable modules are hidden.
-- `moduleDeps` names other HagAIO MODULES that must be ENABLED for this one to
-- run; a module whose module-deps aren't met is shown greyed-out and can't enable.
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
    local p = self:_p()
    p.name = name
    p.title = opts.title or name
    p.description = opts.description or ""
    p.defaultEnabled = opts.defaultEnabled ~= false
    p.perChar = opts.perChar and true or false  -- store db + enable state per character
    p.color = opts.color or ns.Theme.hex.accent  -- log/tag colour
    p.serviceDeps = opts.deps or {}               -- services that must be loaded first
    p.addonDeps = opts.addonDeps or {}            -- external addons required to be available
    p.moduleDeps = opts.moduleDeps or {}          -- other modules that must be enabled
    p.settings = opts.settings or {}

    -- Seed saved-var defaults from the settings schema, then layer any explicit
    -- dbDefaults on top.
    local defaults = {}
    for _, s in ipairs(p.settings) do
        if s.key ~= nil and s.default ~= nil then defaults[s.key] = s.default end
    end
    if opts.dbDefaults then
        for k, v in pairs(opts.dbDefaults) do defaults[k] = v end
    end
    p.dbDefaults = defaults

    p.enabled = false
    p.db = nil
    p.log = nil
end

-- Getters (private fields are never exposed directly).
function Module:GetName() return self:_p().name end
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
function Module:IsPerChar() return self:_p().perChar end
function Module:GetDB() return self:_p().db end
function Module:GetLog() return self:_p().log end

-- Settings accessors (bound to the module's saved-var namespace).
function Module:GetSetting(key)
    local db = self:_p().db
    return db and db[key]
end
function Module:SetSetting(key, value)
    local p = self:_p()
    if p.db then p.db[key] = value end
    self:OnSettingChanged(key, value)
end
-- Hook: react to a setting change (no-op by default).
function Module:OnSettingChanged(key, value) end

-- Internal: bind saved-variable namespace. Called by ModuleManager at startup.
function Module:_BindDB()
    local p = self:_p()
    p.db = ns.SavedVars:Namespace("module_" .. p.name, p.dbDefaults, p.perChar)
end

-- Internal: register this module's logging channel. Called by ModuleManager.
function Module:_AttachLogger()
    local p = self:_p()
    p.log = ns.Logger:Register(p.name, p.color)
end

-- Convenience report methods (route through the shared Logger so each report
-- is auto-recorded in the activity log and echoed to chat).
function Module:LogDebug(...)   self:_p().log:Debug(...)   end
function Module:LogInfo(...)    self:_p().log:Info(...)    end
function Module:LogSuccess(...) self:_p().log:Success(...) end
function Module:LogWarn(...)    self:_p().log:Warn(...)    end
function Module:LogError(...)   self:_p().log:Error(...)   end

function Module:Enable()
    local p = self:_p()
    if p.enabled then return end
    if not self:IsAvailable() then return end                 -- required addon missing
    if not self:AreModuleDepsMet() then                        -- a prerequisite module is off
        ns.Logger:Core():Warn(("%s needs another module enabled first."):format(p.name))
        return
    end
    p.enabled = true
    if self.OnEnable then self:OnEnable() end
    ns.SavedVars:SetModuleState(p.name, true, p.perChar)
    if p.log then p.log:Success("enabled") end
    if ns.EventBus and ns.EventBus.Emit then ns.EventBus:Emit("HagAIO_ModuleState", p.name, true) end
end

function Module:Disable()
    local p = self:_p()
    if not p.enabled then return end
    p.enabled = false
    if self.OnDisable then self:OnDisable() end
    ns.SavedVars:SetModuleState(p.name, false, p.perChar)
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
function Module:OnInitialize() end

ns.Module = Module
