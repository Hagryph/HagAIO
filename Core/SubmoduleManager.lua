local addonName, ns = ...
local Class = ns.Class

-- Core/SubmoduleManager.lua
-- Registry that owns the lifecycle of every Submodule. It builds ONE DependencyGraph
-- spanning modules / services / addons / submodules and decides each submodule's
-- loaded state from graph:IsOnline -- so condition, parent, and all dependency kinds
-- are evaluated by the core. Reevaluate() loads/unloads in dependency order; it runs
-- when a submodule's events fire and whenever a module's enable state changes.
--
-- The generic registry plumbing lives in ns.Registry; this class adds event
-- subscription and the load/unload sweep.

local SubmoduleManager = Class.new("SubmoduleManager", ns.Registry)

local function clearArray(t) for i = #t, 1, -1 do t[i] = nil end end

function SubmoduleManager:Initialize()
    ns.Registry.Initialize(self, "submodule")
    local p = self:_p()
    p.eventTokens = {}   -- event -> EventBus token
    p.scratchUnload = {}  -- reused per sweep (see Reevaluate) instead of reallocating
    p.scratchLoad = {}
    p.evaluating = false
    p.dirty = false
end

-- A submodule registered after StartAll: subscribe its events, then re-evaluate.
function SubmoduleManager:_OnLateRegister(sub)
    self:_SubscribeEvents(sub)
    self:Reevaluate()
end

function SubmoduleManager:IsLoaded(name)
    local s = self:Get(name)
    return s and s:IsLoaded() or false
end

-- Loaded submodules whose parent is the given module (for the settings page to
-- surface their options only while loaded).
function SubmoduleManager:LoadedChildrenOf(moduleName)
    local out = {}
    for s in self:Iterate() do
        local par = s:GetParent()
        if par and par.module == moduleName and s:IsLoaded() then out[#out + 1] = s end
    end
    return out
end

-- Build the unified graph (built lazily + cached by ns.Registry).
function SubmoduleManager:_Graph()
    return self:_GetGraph(function(sm, g)
        local function ensure(id, subject)
            if not g:Has(id) then g:Add(id, subject) end
        end
        local function moduleSubject(name)
            return ns.ModuleManager:GetModule(name) or function() return false end
        end
        -- nodes for every parent/dependency a submodule references
        for s in sm:Iterate() do
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
        for s in sm:Iterate() do
            g:Add("sub:" .. s:GetName(), function() return s:_ConditionMet() end, { all = s:_Refs() })
        end
    end, { method = "IsEnabled" })  -- module subjects use :IsEnabled()
end

-- Load/unload submodules to match the graph. Unload children first (reverse
-- dependency order), then load parents/deps first (dependency order).
--
-- Re-entrancy guard: the load/unload callbacks run user code that could trigger
-- another Reevaluate (e.g. emitting an event we subscribe to). A nested call just
-- marks the pass dirty and returns; we re-sweep after -- so the pooled scratch tables
-- (reused instead of reallocated every call) are never mutated mid-iteration. The
-- guard also coalesces a burst of triggers into a single settling loop.
function SubmoduleManager:Reevaluate()
    local p = self:_p()
    if p.evaluating then p.dirty = true; return end
    p.evaluating = true
    repeat
        p.dirty = false
        self:_Sweep()
    until not p.dirty
    p.evaluating = false
end

function SubmoduleManager:_Sweep()
    local p = self:_p()
    local g = self:_Graph()
    local order = g:TopologicalOrder()  -- cached until a submodule registers
    local toUnload, toLoad = p.scratchUnload, p.scratchLoad
    clearArray(toUnload); clearArray(toLoad)

    -- DECIDE first, with online-state memoised for the whole sweep (every submodule
    -- of a given module shares that module's subtree -- walked once, not once each).
    -- We only READ here; loading/unloading happens after, so no subject changes
    -- mid-pass (a callback that flips state emits its own event -> a fresh pass).
    g:BeginPass()
    for i = #order, 1, -1 do
        local n = order[i]:match("^sub:(.+)$")
        if n then
            local s = self:Get(n)
            if s:IsLoaded() and not g:IsOnline("sub:" .. n) then toUnload[#toUnload + 1] = s end
        end
    end
    for _, id in ipairs(order) do
        local n = id:match("^sub:(.+)$")
        if n then
            local s = self:Get(n)
            if not s:IsLoaded() and g:IsOnline(id) then toLoad[#toLoad + 1] = s end
        end
    end
    g:EndPass()

    -- ACT: unload children-first, then load parents-first (order preserved above).
    -- _Load/_Unload self-guard against double application.
    for _, s in ipairs(toUnload) do s:_Unload() end
    for _, s in ipairs(toLoad)   do s:_Load() end
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
    if not self:_BeginStart() then return end
    local p = self:_p()
    for s in self:Iterate() do self:_SubscribeEvents(s) end
    p.msgToken = ns.EventBus:Subscribe("HagAIO_ModuleState", function() self:Reevaluate() end)
    self:Reevaluate()
end

ns.SubmoduleManager = SubmoduleManager:New()
