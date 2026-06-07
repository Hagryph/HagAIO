local addonName, ns = ...
local Class = ns.Class

-- Core/SubmoduleManager.lua
-- Owns the lifecycle of every Submodule. It builds ONE DependencyGraph spanning
-- modules / services / addons / submodules and decides each submodule's loaded
-- state from graph:IsOnline -- so condition, parent, and all dependency kinds are
-- evaluated by the core. Reevaluate() loads/unloads in dependency order; it runs
-- when a submodule's events fire and whenever a module's enable state changes.

local SubmoduleManager = Class.new("SubmoduleManager")

function SubmoduleManager:Initialize()
    local p = self:_p()
    p.subs = {}          -- name -> Submodule
    p.order = {}         -- registration order
    p.graph = nil        -- cached dependency graph
    p.eventTokens = {}   -- event -> EventBus token
    p.started = false
end

function SubmoduleManager:Register(sub)
    local p = self:_p()
    local name = sub:GetName()
    assert(not p.subs[name], "duplicate submodule: " .. tostring(name))
    p.subs[name] = sub
    p.order[#p.order + 1] = name
    p.graph = nil
    if p.started then self:_SubscribeEvents(sub); self:Reevaluate() end
    return sub
end

function SubmoduleManager:Get(name) return self:_p().subs[name] end
function SubmoduleManager:IsLoaded(name)
    local s = self:_p().subs[name]
    return s and s:IsLoaded() or false
end

-- Loaded submodules whose parent is the given module (for the settings page to
-- surface their options only while loaded).
function SubmoduleManager:LoadedChildrenOf(moduleName)
    local p = self:_p()
    local out = {}
    for _, name in ipairs(p.order) do
        local s = p.subs[name]
        local par = s:GetParent()
        if par and par.module == moduleName and s:IsLoaded() then out[#out + 1] = s end
    end
    return out
end

-- Build the unified graph (cached; rebuilt when a submodule registers).
function SubmoduleManager:_Graph()
    local p = self:_p()
    if p.graph then return p.graph end
    local g = ns.DependencyGraph:New({ method = "IsEnabled" })  -- module subjects use :IsEnabled()

    local function ensure(id, subject)
        if not g:Has(id) then g:Add(id, subject) end
    end
    local function moduleSubject(name)
        return ns.ModuleManager:GetModule(name) or function() return false end
    end
    -- nodes for every parent/dependency a submodule references
    for _, name in ipairs(p.order) do
        local s = p.subs[name]
        local par = s:GetParent()
        if par and par.module then ensure("module:" .. par.module, moduleSubject(par.module)) end
        for _, m in ipairs(s:GetModuleDeps()) do ensure("module:" .. m, moduleSubject(m)) end
        for _, sv in ipairs(s:GetServiceDeps()) do
            ensure("service:" .. sv, function() return ns.ServiceManager and ns.ServiceManager:IsLoaded(sv) end)
        end
        for _, a in ipairs(s:GetAddonDeps()) do
            ensure("addon:" .. a, function() return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(a) and true or false end)
        end
    end
    -- submodule nodes: subject = the Lua condition; condition = parent + deps refs
    for _, name in ipairs(p.order) do
        local s = p.subs[name]
        g:Add("sub:" .. name, function() return s:_ConditionMet() end, { all = s:_Refs() })
    end

    local ok, issues = g:Validate()
    if not ok then
        for _, msg in ipairs(issues) do ns.Logger:Core():Warn("submodule dependencies: " .. msg) end
    end
    p.graph = g
    return g
end

-- Load/unload submodules to match the graph. Unload children first (reverse
-- dependency order), then load parents/deps first (dependency order).
function SubmoduleManager:Reevaluate()
    local p = self:_p()
    local g = self:_Graph()
    local order = g:TopologicalOrder()

    for i = #order, 1, -1 do
        local n = order[i]:match("^sub:(.+)$")
        if n then
            local s = p.subs[n]
            if s:IsLoaded() and not g:IsOnline("sub:" .. n) then s:_Unload() end
        end
    end
    for _, id in ipairs(order) do
        local n = id:match("^sub:(.+)$")
        if n then
            local s = p.subs[n]
            if not s:IsLoaded() and g:IsOnline(id) then s:_Load() end
        end
    end
end

function SubmoduleManager:_SubscribeEvents(sub)
    local p = self:_p()
    for _, ev in ipairs(sub:GetEvents() or {}) do
        if not p.eventTokens[ev] then
            p.eventTokens[ev] = ns.EventBus:On(ev, function() self:Reevaluate() end)
        end
    end
end

-- Start after modules are running (PLAYER_LOGIN). Subscribes each submodule's
-- events, reacts to module enable/disable, and does the first evaluation.
function SubmoduleManager:StartAll()
    local p = self:_p()
    if p.started then return end
    p.started = true
    for _, name in ipairs(p.order) do self:_SubscribeEvents(p.subs[name]) end
    ns.EventBus:Subscribe("HagAIO_ModuleState", function() self:Reevaluate() end)
    self:Reevaluate()
end

ns.SubmoduleManager = SubmoduleManager:New()
