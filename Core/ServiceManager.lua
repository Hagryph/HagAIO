local addonName, ns = ...
local Class = ns.Class

-- Core/ServiceManager.lua
-- Registry that owns the lifecycle of every Service. Services register themselves at
-- file load; StartAll() then orders them with the core DependencyGraph (a topological
-- sort of their declared dependencies) and runs each :_Init() (publish -> logger ->
-- OnInitialize) so a service is only initialised once every service it depends on is
-- already loaded. ShutdownAll() runs :OnShutdown() in reverse. One call boots the
-- whole service layer; .toc load order no longer matters.
--
-- The generic registry plumbing lives in ns.Registry; this class adds the
-- loaded-state tracking and dependency-ordered boot.

local ServiceManager = Class.new("ServiceManager", ns.Registry)

function ServiceManager:Initialize()
    ns.Registry.Initialize(self, "service")
    local p = self:_p()
    p.loaded = {}       -- name -> true once OnInitialize has run
    p.startOrder = nil  -- resolved dependency order (set by StartAll)
end

-- A service registered after StartAll starts immediately (its deps are already up).
function ServiceManager:_OnLateRegister(service)
    self:_Start(service)
end

function ServiceManager:IsLoaded(name) return self:_p().loaded[name] == true end

-- The dependency graph of registered services (each depends on ALL its declared
-- deps) so we can validate and order them. Subjects are constant -- services have no
-- online/offline predicate; only ordering + validity matter. Built + cached by
-- ns.Registry (validated on build).
function ServiceManager:_Graph()
    return self:_GetGraph(function(sm, g)
        for s in sm:Iterate() do
            local deps = s:GetDeps()
            g:Add(s:GetName(), function() return true end, (#deps > 0) and { all = deps } or nil)
        end
    end)
end

-- Initialise a single service (after its deps), publish it, attach logging. `ordered`
-- is true when called from StartAll's topological pass (deps already loaded in order),
-- so the depth-first pre-load is skipped; it only runs for a LATE registration, where
-- there's no surrounding ordered pass to guarantee deps are up.
function ServiceManager:_Start(service, ordered)
    local p = self:_p()
    local name = service:GetName()
    if p.loaded[name] then return end
    if not ordered then
        for _, dep in ipairs(service:GetDeps()) do
            local d = self:Get(dep)
            if d and not p.loaded[dep] then self:_Start(d) end
        end
    end
    service:_Init()  -- publish -> logger -> OnInitialize (sequence owned by Service:_Init)
    p.loaded[name] = true
end

-- Boot the whole service layer in dependency order. Single entry point.
function ServiceManager:StartAll()
    if not self:_BeginStart() then return end
    local p = self:_p()

    local g = self:_Graph()  -- validates: a cycle or dangling dep is fatal
    p.startOrder = g:TopologicalOrder()
    for _, name in ipairs(p.startOrder) do
        self:_Start(self:Get(name), true)  -- ordered: deps already loaded, skip the pre-load loop
    end
end

-- Run each service's optional OnShutdown in REVERSE dependency order (dependents
-- before the services they rely on). Guarded per service.
function ServiceManager:ShutdownAll()
    local p = self:_p()
    local order = p.startOrder or p.order
    for i = #order, 1, -1 do
        local s = self:Get(order[i])
        if s and s.OnShutdown then pcall(function() s:OnShutdown() end) end
    end
end

ns.ServiceManager = ServiceManager:New()
