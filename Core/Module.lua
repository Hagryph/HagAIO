local addonName, ns = ...
local Class = ns.Class

-- Core/Module.lua
-- Abstract base class for every feature module. Subclasses are created with
-- `ns.Class.new("MyFeature", ns.Module)` and override the lifecycle hooks.
-- Enable state and the persistence handle are private; access is via methods.

local Module = Class.new("Module")

-- Constructor. Subclasses that need their own constructor should override
-- Initialize and call Module.Initialize(self, name, opts) first.
--   opts = { title = string, defaultEnabled = bool, dbDefaults = table,
--            color = "RRGGBB" }
function Module:Initialize(name, opts)
    opts = opts or {}
    local p = self:_p()
    p.name = name
    p.title = opts.title or name
    p.defaultEnabled = opts.defaultEnabled ~= false
    p.dbDefaults = opts.dbDefaults or {}
    p.color = opts.color or ns.Theme.hex.accent  -- log/tag colour
    p.enabled = false
    p.db = nil
    p.log = nil
end

-- Getters (private fields are never exposed directly).
function Module:GetName() return self:_p().name end
function Module:GetTitle() return self:_p().title end
function Module:GetColor() return self:_p().color end
function Module:IsEnabled() return self:_p().enabled end
function Module:IsDefaultEnabled() return self:_p().defaultEnabled end
function Module:GetDB() return self:_p().db end
function Module:GetLog() return self:_p().log end

-- Internal: bind saved-variable namespace. Called by ModuleManager at startup.
function Module:_BindDB()
    local p = self:_p()
    p.db = ns.SavedVars.Get():Namespace("module_" .. p.name, p.dbDefaults)
end

-- Internal: register this module's logging channel. Called by ModuleManager.
function Module:_AttachLogger()
    local p = self:_p()
    p.log = ns.Logger.Get():Register(p.name, p.color)
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
    p.enabled = true
    if self.OnEnable then self:OnEnable() end
    ns.SavedVars.Get():SetModuleState(p.name, true)
    if p.log then p.log:Success("enabled") end
end

function Module:Disable()
    local p = self:_p()
    if not p.enabled then return end
    p.enabled = false
    if self.OnDisable then self:OnDisable() end
    ns.SavedVars.Get():SetModuleState(p.name, false)
    if p.log then p.log:Info("disabled") end
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
