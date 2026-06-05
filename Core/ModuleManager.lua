local addonName, ns = ...
local Class = ns.Class

-- Core/ModuleManager.lua
-- Singleton registry that owns the lifecycle of every feature Module: it binds
-- their saved vars, runs OnInitialize, and enables them per the persisted /
-- default state on PLAYER_LOGIN. Modules registered after startup are started
-- immediately so load order is irrelevant.

local ModuleManager = Class.new("ModuleManager")
local instance

function ModuleManager:Initialize()
    local p = self:_p()
    p.modules = {}   -- name -> Module
    p.order = {}     -- ordered list of names (insertion order)
    p.started = false
end

function ModuleManager:Register(module)
    local p = self:_p()
    local name = module:GetName()
    assert(not p.modules[name], "duplicate module: " .. tostring(name))
    p.modules[name] = module
    p.order[#p.order + 1] = name
    if p.started then
        self:_Start(module)
    end
    return module
end

-- Instance lookup (distinct from the static .Get() singleton accessor).
function ModuleManager:GetModule(name)
    return self:_p().modules[name]
end

-- Stateless iterator over modules in registration order.
function ModuleManager:Iterate()
    local p = self:_p()
    local i = 0
    return function()
        i = i + 1
        local name = p.order[i]
        if name then return p.modules[name] end
    end
end

function ModuleManager:Count()
    return #self:_p().order
end

function ModuleManager:_Start(module)
    module:_AttachLogger()
    module:_BindDB()
    module:OnInitialize()
    local saved = ns.SavedVars.Get():GetModuleState(module:GetName())
    local shouldEnable = saved
    if shouldEnable == nil then
        shouldEnable = module:IsDefaultEnabled()
    end
    if shouldEnable then
        module:Enable()
    end
end

-- Run once on PLAYER_LOGIN.
function ModuleManager:StartAll()
    local p = self:_p()
    if p.started then return end
    p.started = true
    for _, name in ipairs(p.order) do
        self:_Start(p.modules[name])
    end
end

function ModuleManager.Get()
    if not instance then instance = ModuleManager:New() end
    return instance
end

ns.ModuleManager = ModuleManager
