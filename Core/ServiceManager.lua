local addonName, ns = ...
local Class = ns.Class

-- Core/ServiceManager.lua
-- Singleton registry that owns the lifecycle of every Service. Services register
-- themselves at file load; StartAll() then orders them with the core
-- DependencyGraph (a topological sort of their declared dependencies) and runs
-- each :OnInitialize() so a service is only initialised once every service it
-- depends on is already loaded. ShutdownAll() runs :OnShutdown() in reverse.
-- One call boots the whole service layer; .toc load order no longer matters.

local ServiceManager = Class.new("ServiceManager")

function ServiceManager:Initialize()
    local p = self:_p()
    p.services = {}     -- name -> Service instance
    p.order = {}        -- registration order
    p.loaded = {}       -- name -> true once OnInitialize has run
    p.startOrder = nil  -- resolved dependency order (set by StartAll)
    p.started = false
end

function ServiceManager:Register(service)
    local p = self:_p()
    local name = service:GetName()
    assert(not p.services[name], "duplicate service: " .. tostring(name))
    p.services[name] = service
    p.order[#p.order + 1] = name
    if p.started then self:_Start(service) end  -- registered late -> start at once
    return service
end

function ServiceManager:Get(name) return self:_p().services[name] end
function ServiceManager:IsLoaded(name) return self:_p().loaded[name] == true end

-- Build a DependencyGraph of the registered services (each depends on ALL its
-- declared deps) so we can validate and order them.
function ServiceManager:_Graph()
    local p = self:_p()
    local g = ns.DependencyGraph:New()
    for _, name in ipairs(p.order) do
        local deps = p.services[name]:GetDeps()
        local cond = (#deps > 0) and { all = deps } or nil
        g:Add(name, function() return true end, cond)
    end
    return g
end

-- Initialise a single service (after its deps), publish it, attach logging.
function ServiceManager:_Start(service)
    local p = self:_p()
    local name = service:GetName()
    if p.loaded[name] then return end
    for _, dep in ipairs(service:GetDeps()) do      -- depth-first safety net
        local d = p.services[dep]
        if d and not p.loaded[dep] then self:_Start(d) end
    end
    service:_Publish()
    service:_AttachLogger()
    service:OnInitialize()
    p.loaded[name] = true
end

-- Boot the whole service layer in dependency order. Single entry point.
function ServiceManager:StartAll()
    local p = self:_p()
    if p.started then return end
    p.started = true

    local g = self:_Graph()
    local ok, issues = g:Validate()
    if not ok then
        for _, msg in ipairs(issues) do ns.Logger:Core():Warn("service dependencies: " .. msg) end
    end

    p.startOrder = g:TopologicalOrder()
    for _, name in ipairs(p.startOrder) do
        self:_Start(p.services[name])
    end
end

-- Run each service's optional OnShutdown in REVERSE dependency order (dependents
-- before the services they rely on). Guarded per service.
function ServiceManager:ShutdownAll()
    local p = self:_p()
    local order = p.startOrder or p.order
    for i = #order, 1, -1 do
        local s = p.services[order[i]]
        if s and s.OnShutdown then pcall(function() s:OnShutdown() end) end
    end
end

ns.ServiceManager = ServiceManager:New()
